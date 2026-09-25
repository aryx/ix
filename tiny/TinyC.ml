(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny C compiler for arm64, in one file, through an intermediate
 * language of its own. mini-cc (compiler/) is 5c's and 7c's twin,
 * byte for byte: their front end, their trees, their code generator,
 * and a record per machine. This is what is left when the code need
 * only be correct:
 *
 *     tiny-c -o prog.s prog.c && tiny-assembler -o prog prog.s libc/*.s
 *
 * one C file in, its arm64 assembly out, in Plan 9's syntax, for
 * TinyAssembler, with 7c's calling convention, so that the program
 * calls goken's libc (7c's code) and libc calls it back (main).
 *
 * What makes it small, and still a C compiler:
 *
 * - {b A stack machine in between} (IR, below): expressions become
 *   pushes and operations on a stack, statements labels and jumps;
 *   [-ir] prints it. The question the compiler's plan left open, what
 *   an intermediate language buys against writing the machine's
 *   instructions directly, has this answer here: the front end knows
 *   no register and no instruction, the back end no C (its 120 lines
 *   are the whole machine), and each can be read, and tested, alone.
 *   What it costs is the code's quality: no Sethi-Ullman order, no
 *   addressing modes, a load or a store per variable reference.
 * - {b The stack is in registers.} The back end keeps the machine's
 *   stack in R1..R15 (depth d in Rd), so a push is a MOV and an
 *   operation one instruction on two registers, as in Wirth's
 *   compilers; only a call saves what is live below its arguments, to
 *   the frame. An expression deeper than 15 is refused.
 * - {b Types at parse time, trees as variants.} Each expression is
 *   built typed, with its conversions made explicit (a Conv node, a
 *   pointer's arithmetic scaled); statements are a tree too ([stmt]),
 *   which [lower] turns into the stack machine's code, so parsing,
 *   lowering and the machine are three walks, each of its own type.
 *   The operators are variants, split so that every match is
 *   exhaustive; [&&], [||] and [!] are made of [?:], [while] of
 *   [for].
 * - {b Values in 64 bits.} Registers hold a value extended from its
 *   type, and an operation on an int is followed by its extension
 *   (SXTW, MOVWU): the machine's 64-bit instructions do for every
 *   width.
 * - {b 7c's frames and arguments}: the first argument in R0, the
 *   others in 8-byte slots at 8(R31) up (the callee's n(FP)), the
 *   result in R0, locals below SP, and the frame 7l's (TinyAssembler's
 *   TEXT): so libc's functions, variadic ones included (print), are
 *   called as 7c calls them.
 *
 * The language: char short int long (4 bytes, as Plan 9's) and long
 * long, unsigned and signed; pointers, arrays, structs (members, . and
 * ->; not passed by value); void; globals with initializers (numbers,
 * strings, arrays of them); static, extern, typedef; functions and
 * prototypes, calls to variadic ones; every operator, with op=, ++,
 * --, ?:, casts, sizeof and the comma; if, while, do, for, switch,
 * break, continue, return, blocks; #include "file", #define of a name.
 * Left out, by what each would cost here: floats, unions, enums,
 * bitfields, function pointers, structures by value, goto, the
 * preprocessor's macros with arguments and its #if.
 *
 * References: Niklaus Wirth, Compiler Construction (1996), for the
 * registers as a stack of the expression's values, and the one-pass
 * recursive descent; Ken Thompson, "Plan 9 C Compilers" (1990), for
 * the calling convention this code shares with 7c's; Kernighan and
 * Ritchie, The C Programming Language (1988), appendix A, the grammar
 * followed. *)

let error fmt = Printf.ksprintf failwith fmt

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type ty =
  | Void
  | Int of int * bool                 (* bytes, signed *)
  | Ptr of ty
  | Arr of ty * int
  | Struct of sdef
  | Func of ty * ty list * bool       (* result, parameters, variadic *)

and sdef = { mutable fields : (string * ty * int) list; mutable ssize : int; mutable salign : int }

let int_t = Int (4, true) and long_t = Int (8, true) and char_t = Int (1, true)
let rec size = function Void -> 1 | Int (n, _) -> n | Ptr _ | Func _ -> 8 | Arr (t, n) -> n * size t | Struct s -> s.ssize
let rec align = function Int (n, _) -> n | Arr (t, _) -> align t | Struct s -> s.salign | _ -> 8
let round n a = (n + a - 1) / a * a
let is_int = function Int _ -> true | _ -> false
let is_ptr = function Ptr _ -> true | _ -> false
let unsigned = function Int (_, s) -> not s | Ptr _ -> true | _ -> false

(* a structure is itself: struct node { struct node *next; } *)
let rec same a b =
  match a, b with
  | Struct s, Struct t -> s == t
  | Ptr a, Ptr b -> same a b
  | Arr (a, n), Arr (b, m) -> n = m && same a b
  | Func (r, p, v), Func (s, q, w) -> v = w && same r s && List.length p = List.length q && List.for_all2 same p q
  | a, b -> a = b

(*****************************************************************************)
(* Tokens and the preprocessor *)
(*****************************************************************************)

type token = Id of string | Num of int64 * bool (* LL *) | Str of string | P of string | EOF

let puncts = [ "<<="; ">>="; "..."; "->"; "++"; "--"; "<<"; ">>"; "<="; ">="; "=="; "!="; "&&"; "||"; "+="; "-="; "*=";
               "/="; "%="; "&="; "|="; "^=" ]

(* a file's tokens, its #includes' in their place, #defines expanded *)
let rec tokens (macros : (string, token list) Hashtbl.t) (read : string -> string) file : token list =
  let s = read file in
  let n = String.length s in
  let out = ref [] in
  let emit t = match t with Id x when Hashtbl.mem macros x -> out := List.rev_append (Hashtbl.find macros x) !out | t -> out := t :: !out in
  let escape i =
    (* the escapes: n t r, octal, and any other character as itself *)
    match s.[i] with
    | 'n' -> 10, i + 1 | 't' -> 9, i + 1 | 'r' -> 13, i + 1
    | '0' .. '7' -> let rec oct j v = if j < n && j < i + 3 && s.[j] >= '0' && s.[j] <= '7' then oct (j + 1) ((v * 8) + Char.code s.[j] - 48) else v, j in oct i 0
    | c -> Char.code c, i + 1
  in
  let rec span j p = if j < n && p s.[j] then span (j + 1) p else j in
  let rec go i bol =
    if i >= n then ()
    else
      match s.[i] with
      | '\n' -> go (i + 1) true
      | ' ' | '\t' | '\r' -> go (i + 1) bol
      | '#' when bol ->
          let e = try String.index_from s i '\n' with Not_found -> n in
          let line = String.sub s (i + 1) (e - i - 1) in
          (match List.filter (( <> ) "") (String.split_on_char ' ' (String.map (function '\t' -> ' ' | c -> c) line)) with
           | "include" :: f :: _ when f.[0] = '"' ->
               let f = String.sub f 1 (String.length f - 2) in
               let f = if Filename.is_relative f then Filename.concat (Filename.dirname file) f else f in
               out := List.rev_append (tokens macros read f) !out
           | "define" :: name :: _ ->
               (* the rest of the line, lexed *)
               let rest = String.sub line (String.index line 'd' + 6) (String.length line - String.index line 'd' - 6) in
               let rest = String.trim rest in
               let rest = String.sub rest (String.length name) (String.length rest - String.length name) in
               Hashtbl.replace macros name (tokens macros (fun _ -> rest) file)
           | _ -> ());
          go e true
      | '/' when i + 1 < n && s.[i + 1] = '/' -> go (try String.index_from s i '\n' with Not_found -> n) true
      | '/' when i + 1 < n && s.[i + 1] = '*' ->
          let rec close j = if j + 1 >= n then n else if s.[j] = '*' && s.[j + 1] = '/' then j + 2 else close (j + 1) in
          go (close (i + 2)) bol
      | 'a' .. 'z' | 'A' .. 'Z' | '_' ->
          let j = span i (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false) in
          emit (Id (String.sub s i (j - i)));
          go j false
      | '0' .. '9' ->
          let k = span i (function '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' | 'x' | 'X' -> true | _ -> false) in
          let lit = String.sub s i (k - i) in
          let lit = if String.length lit > 1 && lit.[0] = '0' && lit.[1] <> 'x' && lit.[1] <> 'X' then "0o" ^ String.sub lit 1 (String.length lit - 1) else lit in
          let j = span k (function 'u' | 'U' | 'l' | 'L' -> true | _ -> false) in
          let suffix = String.lowercase_ascii (String.sub s k (j - k)) in
          emit (Num (Int64.of_string lit, String.length suffix >= 2 && String.contains (String.sub suffix 1 (String.length suffix - 1)) 'l'));
          go j false
      | '\'' ->
          let v, j = if s.[i + 1] = '\\' then escape (i + 2) else Char.code s.[i + 1], i + 2 in
          emit (Num (Int64.of_int v, false));
          go (j + 1) false
      | '"' ->
          let b = Buffer.create 16 in
          let rec str j = if s.[j] = '"' then j + 1 else if s.[j] = '\\' then (let v, j = escape (j + 1) in Buffer.add_char b (Char.chr (v land 255)); str j) else (Buffer.add_char b s.[j]; str (j + 1)) in
          let j = str (i + 1) in
          (* "a" "b" is "ab" *)
          (match !out with Str a :: rest -> out := Str (a ^ Buffer.contents b) :: rest | _ -> emit (Str (Buffer.contents b)));
          go j false
      | _ ->
          let p = List.find_opt (fun p -> i + String.length p <= n && String.sub s i (String.length p) = p) puncts in
          let p = match p with Some p -> p | None -> String.make 1 s.[i] in
          emit (P p);
          go (i + String.length p) false
  in
  go 0 true;
  List.rev !out

(*****************************************************************************)
(* Expressions, typed as they are built *)
(*****************************************************************************)

(* the operators: an arithmetic one's value is of its operands' type,
 * a relation's an int; >> is logical, / % and the relations unsigned,
 * for an unsigned type *)
(* old: strings ("+", "<="): a misspelled operator was a runtime error,
 * and the machine's match over them needed a catch-all *)
type arith = Add | Sub | Mul | Div | Mod | And | Or | Xor | Shl | Shr
type rel = Lt | Gt | Le | Ge | Eq | Ne
type binop = A of arith | R of rel
type unop = Neg | Com

let binops = [ "+", A Add; "-", A Sub; "*", A Mul; "/", A Div; "%", A Mod; "&", A And; "|", A Or; "^", A Xor; "<<", A Shl;
               ">>", A Shr; "<", R Lt; ">", R Gt; "<=", R Le; ">=", R Ge; "==", R Eq; "!=", R Ne ]
let binop_name o = fst (List.find (fun (_, o') -> o' = o) binops)

(* x op= y's tokens *)
let asg_ops = List.filter_map (function s, A o -> Some (s ^ "=", o) | _ -> None) binops

(* where a variable is: a global's name in the assembly, a local's
 * offset below SP, a parameter's from FP *)
type place = Global of string | Local of int | Param of int

type expr = { d : desc; t : ty }

and desc =
  | Const of int64
  | Addr of place
  | Deref of expr                     (* the object at an address: an lvalue *)
  | Cur                               (* in x op= y, x's value *)
  | Un of unop * expr
  | Bin of binop * expr * expr        (* both operands of one type; a relation's value an int *)
  | Cond of expr * expr * expr        (* && || ! are made of it *)
  | Asg of expr * expr * bool         (* an lvalue, its new value, which uses Cur *)
  | Call of string * expr list
  | Conv of expr                      (* to t *)
  | Comma of expr * expr

let mk d t = { d; t }
let num v t = mk (Const v) t

(* an array is its address, a value of a small integer an int *)
let rv (e : expr) = match e.t, e.d with Arr (t, _), Deref a -> { a with t = Ptr t } | _ -> e

let conv (e : expr) t =
  match e.t, t, e.d with
  | a, b, _ when same a b -> e
  | Int _, Int (n, sg), Const v ->
      (* a constant converted now: truncated, extended *)
      let bits = 8 * n in
      let v = if bits = 64 then v else if sg then Int64.shift_right (Int64.shift_left v (64 - bits)) (64 - bits) else Int64.logand v (Int64.pred (Int64.shift_left 1L bits)) in
      num v t
  | (Ptr _ | Arr _), Ptr _, _ | Ptr _, Int (8, _), _ | Int (8, _), Ptr _, _ -> { e with t }
  | _ -> mk (Conv e) t

(* Plan 9's C keeps the sign as it widens: uchar and ushort become
 * uint, not int (the table of cck's sub.c, as pre-ANSI compilers) *)
let promote = function Int (n, s) when n < 4 -> Int (4, s) | t -> t

(* the usual arithmetic conversions, Plan 9's: the wider, unsigned if
 * either is *)
let common a b =
  match promote a, promote b with
  | Int (n, s), Int (m, u) -> Int (max n m, s && u)
  | t, _ -> t

let scale (i : expr) t = if size t = 1 then conv i long_t else mk (Bin (A Mul, conv i long_t, num (Int64.of_int (size t)) long_t)) long_t

let rec binary op (a : expr) (b : expr) =
  let a = rv a and b = rv b in
  match op, a.t, b.t with
  | A (Add | Sub), Ptr t, Int _ -> mk (Bin (op, a, scale b t)) a.t
  | A Add, Int _, Ptr _ -> binary op b a
  | A Sub, Ptr t, Ptr _ -> mk (Bin (A Div, mk (Bin (op, conv a long_t, conv b long_t)) long_t, num (Int64.of_int (size t)) long_t)) long_t
  | R _, Ptr _, _ | R _, _, Ptr _ -> let t = if is_ptr a.t then a.t else b.t in mk (Bin (op, conv a t, conv b t)) int_t
  | R _, Int _, Int _ -> let t = common a.t b.t in mk (Bin (op, conv a t, conv b t)) int_t
  | A o, Int _, Int _ -> let t = if o = Shl || o = Shr then promote a.t else common a.t b.t in mk (Bin (op, conv a t, conv b t)) t
  | _ -> error "bad operands for %s" (binop_name op)

let addr (e : expr) = match e.d with Deref a -> { a with t = Ptr e.t } | _ -> error "not an lvalue"
let deref (e : expr) = let e = rv e in match e.t with Ptr t -> mk (Deref e) t | _ -> error "not a pointer"

let assign ?(cur = false) (l : expr) (r : expr) = match l.d with Deref _ -> mk (Asg (l, conv (rv r) l.t, cur)) l.t | _ -> error "not an lvalue"

(* x op= y: the value computed from x's, loaded once *)
let asg_op o (l : expr) r = assign ~cur:true l (binary (A o) (mk Cur l.t) r)

(* a variable, as an lvalue *)
let var p t = mk (Deref (mk (Addr p) (Ptr t))) t

(* a condition's value, 1 or 0; !, && and || as ?: of them *)
let truth c = mk (Cond (rv c, num 1L int_t, num 0L int_t)) int_t
let lnot c = mk (Cond (rv c, num 0L int_t, num 1L int_t)) int_t
let both a b = mk (Cond (rv a, truth b, num 0L int_t)) int_t
let either a b = mk (Cond (rv a, num 1L int_t, truth b)) int_t

(*****************************************************************************)
(* Statements *)
(*****************************************************************************)

(* old: none, the parser emitted the stack machine's code as it read,
 * with break's and continue's targets on global stacks *)
type stmt =
  | Expr of expr
  | Block of stmt list
  | If of expr * stmt * stmt option
  | Do of stmt * expr
  | For of expr option * expr option * expr option * stmt   (* while too *)
  | Switch of expr * expr * stmt      (* its temporary, its value, its body *)
  | Case of int64 option              (* default: None *)
  | Break
  | Continue
  | Return of expr option

(*****************************************************************************)
(* The stack machine *)
(*****************************************************************************)

type ir =
  | Imm of int64
  | Place of place                    (* a variable's address *)
  | Load of ty                        (* the address on top by its value *)
  | Store of ty                       (* value and address by the value *)
  | Op of binop * ty                  (* a b by a op b, of the operands' type; a relation 1 or 0 *)
  | Unop of unop * ty
  | Ext of ty                         (* the value on top to a type *)
  | Dup | Drop
  | Call of string * int * bool       (* the name, the arguments, a result *)
  | Label of int | Jmp of int | Jz of int | Jnz of int
  | Ret of bool

let show i =
  let w t = Printf.sprintf "%d%s" (size t) (if unsigned t then "u" else "") in
  match i with
  | Imm v -> Printf.sprintf "imm %Ld" v | Place (Global s) -> "addr " ^ s | Place (Local o) -> Printf.sprintf "frame -%d" o
  | Place (Param o) -> Printf.sprintf "param %d" o | Load t -> "load " ^ w t | Store t -> "store " ^ w t
  | Op (o, t) -> Printf.sprintf "op %s %s" (binop_name o) (w t) | Unop (o, _) -> if o = Neg then "neg" else "com" | Ext t -> "ext " ^ w t
  | Dup -> "dup" | Drop -> "drop" | Call (f, n, r) -> Printf.sprintf "call %s %d%s" f n (if r then " ->" else "")
  | Label l -> Printf.sprintf "L%d:" l | Jmp l -> Printf.sprintf "jmp L%d" l | Jz l -> Printf.sprintf "jz L%d" l
  | Jnz l -> Printf.sprintf "jnz L%d" l | Ret v -> if v then "ret value" else "ret"

let code : ir list ref = ref []           (* the current function's, the last first *)
let emit i = code := i :: !code
let labels = ref 0
let label () = incr labels; !labels

(* the value of e, pushed *)
let rec value (e : expr) : unit =
  match e.d with
  | Const v -> emit (Imm v)
  | Addr p -> emit (Place p)
  | Deref a -> value a; (match e.t with Arr _ | Struct _ | Func _ -> () | t -> emit (Load t))
  | Cur -> emit (Load e.t)
  | Un (o, a) -> value a; emit (Unop (o, e.t))
  | Bin (o, a, b) -> value a; value b; emit (Op (o, a.t))
  | Cond (c, a, b) ->
      let other = label () and out = label () in
      value c;
      emit (Jz other);
      value a;
      emit (Jmp out);
      emit (Label other);
      value b;
      emit (Label out)
  | Asg (l, r, cur) ->
      value (addr l);
      if cur then emit Dup;
      value r;
      emit (Store l.t)
  | Call (f, args) -> List.iter value args; emit (Call (f, List.length args, e.t <> Void))
  | Conv a -> value a; (match a.t, e.t with (Arr _ | Ptr _ | Void), _ | _, Void -> () | _ -> emit (Ext e.t))
  | Comma (a, b) -> value a; if a.t <> Void then emit Drop; value b

(* an expression as a statement *)
let effect (e : expr) = value e; if e.t <> Void then emit Drop

(* where break and continue go; the labels of a switch's cases *)
type targets = { brk : int option; cont : int option; cases : (int64 option * int) list ref }

let rec lower (k : targets) (s : stmt) =
  let jump = function Some l -> emit (Jmp l) | None -> error "break or continue outside a loop" in
  match s with
  | Expr e -> effect e
  | Block l -> List.iter (lower k) l
  | If (c, a, b) ->
      let other = label () in
      value c;
      emit (Jz other);
      lower k a;
      (match b with
       | Some b -> let out = label () in emit (Jmp out); emit (Label other); lower k b; emit (Label out)
       | None -> emit (Label other))
  | Do (body, c) ->
      let top = label () and cont = label () and out = label () in
      emit (Label top);
      lower { k with brk = Some out; cont = Some cont } body;
      emit (Label cont); value c; emit (Jnz top); emit (Label out)
  | For (init, c, step, body) ->
      Option.iter effect init;
      let top = label () and cont = label () and out = label () in
      emit (Label top);
      Option.iter (fun c -> value c; emit (Jz out)) c;
      lower { k with brk = Some out; cont = Some cont } body;
      emit (Label cont);
      Option.iter effect step;
      emit (Jmp top); emit (Label out)
  | Switch (tmp, v, body) ->
      (* the value in a temporary, the cases after the body *)
      effect (assign tmp v);
      let dispatch = label () and out = label () in
      emit (Jmp dispatch);
      let cases = ref [] in
      lower { k with brk = Some out; cases } body;
      let mine = List.rev !cases in
      emit (Jmp out);
      emit (Label dispatch);
      List.iter (fun (c, l) -> match c with Some v -> value (binary (R Eq) tmp (num v long_t)); emit (Jnz l) | None -> ()) mine;
      emit (Jmp (match List.assoc_opt None mine with Some l -> l | None -> out));
      emit (Label out)
  | Case v -> let l = label () in k.cases := (v, l) :: !(k.cases); emit (Label l)
  | Break -> jump k.brk
  | Continue -> jump k.cont
  | Return None -> emit (Ret false)
  | Return (Some e) -> value e; emit (Ret true)

(*****************************************************************************)
(* The parser: declarations, and statements *)
(*****************************************************************************)

type storage = Auto | Static | Extern | Typedef

type var = { vty : ty; where : place }

let toks = ref [||] and pos = ref 0
let peek () = if !pos < Array.length !toks then !toks.(!pos) else EOF
let next () = let t = peek () in incr pos; t
let accept p = if peek () = P p then (incr pos; true) else false
let expect p = if not (accept p) then error "expected %s" p
let ident () = match next () with Id x -> x | _ -> error "expected a name"

let globals : (string, var) Hashtbl.t = Hashtbl.create 64
let typedefs : (string, ty) Hashtbl.t = Hashtbl.create 16
let structs : (string, sdef) Hashtbl.t = Hashtbl.create 16
let scopes : (string, var) Hashtbl.t list ref = ref []
let frame = ref 0                         (* the current function's locals *)
let result = ref Void
let data = Buffer.create 4096             (* the DATA and GLOBL *)
let strings = ref 0
let tags = ref 0                          (* the anonymous structures' *)

let lookup x =
  match List.find_map (fun s -> Hashtbl.find_opt s x) !scopes with
  | Some v -> v
  | None -> (match Hashtbl.find_opt globals x with Some v -> v | None -> error "undeclared: %s" x)

(* a local's place, below SP at its alignment *)
let local t = frame := round (!frame + size t) (max 1 (min 8 (align t))); Local !frame

(* a string, as a static array of bytes *)
let string_lit s =
  incr strings;
  let name = Printf.sprintf "s%d<>" !strings in
  let s = s ^ "\000" in
  let esc c = match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | ' ' -> String.make 1 c | c -> Printf.sprintf "\\%03o" (Char.code c) in
  for i = 0 to (String.length s - 1) / 8 do
    let chunk = String.sub s (8 * i) (min 8 (String.length s - (8 * i))) in
    Buffer.add_string data (Printf.sprintf "\tDATA\t%s+%d(SB)/%d, $\"%s\"\n" name (8 * i) (String.length chunk) (String.concat "" (List.map esc (List.of_seq (String.to_seq chunk)))))
  done;
  Buffer.add_string data (Printf.sprintf "\tGLOBL\t%s(SB), $%d\n" name (String.length s));
  var (Global name) (Arr (char_t, String.length s))

let is_type () =
  match peek () with
  | Id ("void" | "char" | "short" | "int" | "long" | "unsigned" | "signed" | "struct" | "static" | "extern" | "const" | "typedef") -> true
  | Id x -> Hashtbl.mem typedefs x && not (List.exists (fun s -> Hashtbl.mem s x) !scopes)
  | _ -> false

(* the words before a declarator: the type, and static, extern, typedef *)
let rec base_type () =
  let storage = ref Auto and words = ref [] and t = ref None in
  let rec go () =
    match peek () with
    | Id ("static" | "extern" | "typedef" as w) -> ignore (next ()); storage := List.assoc w [ "static", Static; "extern", Extern; "typedef", Typedef ]; go ()
    | Id ("const" | "volatile") -> ignore (next ()); go ()
    | Id (("void" | "char" | "short" | "int" | "long" | "unsigned" | "signed") as w) -> ignore (next ()); words := w :: !words; go ()
    | Id "struct" -> ignore (next ()); t := Some (struct_type ()); go ()
    | Id x when !words = [] && !t = None && Hashtbl.mem typedefs x -> ignore (next ()); t := Some (Hashtbl.find typedefs x); go ()
    | _ -> ()
  in
  go ();
  let w = !words in
  let signed = not (List.mem "unsigned" w) in
  let longs = List.length (List.filter (( = ) "long") w) in
  let width = if List.mem "char" w then 1 else if List.mem "short" w then 2 else if longs >= 2 then 8 else 4 in
  let t = match !t with Some t -> t | None -> if List.mem "void" w then Void else Int (width, signed) in
  !storage, t

and struct_type () =
  let tag = match peek () with Id x -> ignore (next ()); x | _ -> incr tags; Printf.sprintf ".%d" !tags in
  let s = match Hashtbl.find_opt structs tag with Some s -> s | None -> let s = { fields = []; ssize = 0; salign = 1 } in Hashtbl.replace structs tag s; s in
  if accept "{" then begin
    (* each member at its size's alignment, the whole rounded to 8, as 7c *)
    let off = ref 0 in
    while not (accept "}") do
      let _, bt = base_type () in
      let rec members () =
        let name, t = declarator bt in
        off := round !off (align t);
        s.fields <- s.fields @ [ name, t, !off ];
        off := !off + size t;
        s.salign <- max s.salign (align t);
        if accept "," then members ()
      in
      members ();
      expect ";"
    done;
    s.ssize <- round !off 8
  end;
  Struct s

(* * name [n]... or name(params), with the parameters' names *)
and declarator bt = let name, t, _ = declarator3 bt in name, t

and declarator3 bt =
  let t = ref bt in
  while accept "*" do t := Ptr !t; ignore (accept "const") done;
  let name = match peek () with Id x -> ignore (next ()); x | _ -> "" in
  if accept "(" then begin
    (* the parameters, named or not, an array's as a pointer; ... *)
    let rec params () =
      if accept ")" then [], false
      else if accept "..." then (expect ")"; [], true)
      else begin
        let _, pt = base_type () in
        let pname, pt = declarator pt in
        let pt = match pt with Arr (e, _) -> Ptr e | t -> t in
        ignore (accept ",");
        let rest, variadic = params () in
        (if pt <> Void || pname <> "" then (pname, pt) :: rest else rest), variadic
      end
    in
    let ps, variadic = params () in
    name, Func (!t, List.map snd ps, variadic), List.map fst ps
  end
  else begin
    let rec dims () = if accept "[" then (let n = if peek () = P "]" then 0 else Int64.to_int (const_expr ()) in expect "]"; n :: dims ()) else [] in
    name, List.fold_right (fun n t -> Arr (t, n)) (dims ()) !t, []
  end

(* expressions, by precedence climbing *)
and expr () = let e = assign_expr () in if accept "," then (let r = expr () in mk (Comma (e, r)) r.t) else e

and assign_expr () =
  let l = cond_expr () in
  match peek () with
  | P "=" -> ignore (next ()); assign l (assign_expr ())
  | P op when List.mem_assoc op asg_ops -> ignore (next ()); asg_op (List.assoc op asg_ops) l (assign_expr ())
  | _ -> l

and cond_expr () =
  let c = binary_expr 0 in
  if accept "?" then begin
    let a = rv (expr ()) in
    expect ":";
    let b = rv (cond_expr ()) in
    let t = if is_int a.t && is_int b.t then common a.t b.t else if is_ptr a.t then a.t else b.t in
    mk (Cond (rv c, conv a t, conv b t)) t
  end
  else c

and binary_expr min =
  let levels = [ [ "||" ]; [ "&&" ]; [ "|" ]; [ "^" ]; [ "&" ]; [ "=="; "!=" ]; [ "<"; ">"; "<="; ">=" ]; [ "<<"; ">>" ]; [ "+"; "-" ]; [ "*"; "/"; "%" ] ] in
  let rec loop l =
    match peek () with
    | P op -> (
        let rec index i = function [] -> None | l :: r -> if List.mem op l then Some i else index (i + 1) r in
        match index 0 levels with
        | Some lv when lv >= min ->
            ignore (next ());
            let r = binary_expr (lv + 1) in
            loop (match op with "&&" -> both l r | "||" -> either l r | op -> binary (List.assoc op binops) l r)
        | _ -> l)
    | _ -> l
  in
  loop (unary ())

and unary () =
  match peek () with
  | P "-" -> ignore (next ()); let e = rv (unary ()) in let t = promote e.t in (match e.d with Const v -> num (Int64.neg v) t | _ -> mk (Un (Neg, conv e t)) t)
  | P "+" -> ignore (next ()); let e = rv (unary ()) in conv e (promote e.t)
  | P "~" -> ignore (next ()); let e = rv (unary ()) in let t = promote e.t in mk (Un (Com, conv e t)) t
  | P "!" -> ignore (next ()); lnot (unary ())
  | P "*" -> ignore (next ()); deref (unary ())
  | P "&" -> ignore (next ()); addr (unary ())
  | P ("++" | "--" as op) -> ignore (next ()); asg_op (if op = "++" then Add else Sub) (unary ()) (num 1L int_t)
  | Id "sizeof" ->
      ignore (next ());
      let t = if paren_type () then (expect "("; let t = type_name () in expect ")"; t) else (unary ()).t in
      num (Int64.of_int (size t)) (Int (4, false))
  | P "(" when paren_type () ->
      expect "(";
      let t = type_name () in
      expect ")";
      conv (rv (unary ())) t
  | _ -> postfix (primary ())

(* ( type ...: a cast, or sizeof's type *)
and paren_type () = peek () = P "(" && (incr pos; let ty = is_type () in decr pos; ty)

and type_name () = let _, bt = base_type () in snd (declarator bt)

and postfix e =
  match peek () with
  | P "[" -> ignore (next ()); let i = expr () in expect "]"; postfix (deref (binary (A Add) e i))
  | P "." -> ignore (next ()); postfix (member e (ident ()))
  | P "->" -> ignore (next ()); postfix (member (deref e) (ident ()))
  | P ("++" | "--" as op) ->
      ignore (next ());
      (* x++ is (x += 1) - 1, and so on *)
      let o, back = if op = "++" then Add, Sub else Sub, Add in
      postfix (conv (binary (A back) (asg_op o e (num 1L int_t)) (num 1L int_t)) e.t)
  | _ -> e

and member e f =
  match e.t with
  | Struct s -> (
      match List.find_opt (fun (n, _, _) -> n = f) s.fields with
      | Some (_, t, off) -> mk (Deref (mk (Bin (A Add, conv (addr e) long_t, num (Int64.of_int off) long_t)) (Ptr t))) t
      | None -> error "no member %s" f)
  | _ -> error "not a structure"

and primary () =
  match next () with
  | Num (v, ll) -> num v (if ll || Int64.compare v 0x7fffffffL > 0 then long_t else int_t)
  | Str s -> string_lit s
  | P "(" -> let e = expr () in expect ")"; e
  | Id f when peek () = P "(" ->
      ignore (next ());
      let args = ref [] in
      if not (accept ")") then begin
        let rec go () = args := rv (assign_expr ()) :: !args; if accept "," then go () else expect ")" in
        go ()
      end;
      let args = List.rev !args in
      let rt, ps, sym = match (try Some (lookup f) with Failure _ -> None) with Some { vty = Func (r, p, _); where = Global s } -> r, p, s | _ -> int_t, [], f in
      (* a declared parameter's type, else the promotions *)
      let args = List.mapi (fun i (a : expr) -> match List.nth_opt ps i with Some t -> conv a t | None -> conv a (promote a.t)) args in
      mk (Call (sym, args)) rt
  | Id x -> let v = lookup x in var v.where v.vty
  | _ -> error "expected an expression"

and const_expr () =
  match (cond_expr ()).d with Const v -> v | _ -> error "not a constant"

(* statements *)
let cond () = expect "("; let c = rv (expr ()) in expect ")"; c

let rec statement () : stmt =
  match next () with
  | P "{" -> block ()
  | P ";" -> Block []
  | Id "if" ->
      let c = cond () in
      let a = statement () in
      If (c, a, if peek () = Id "else" then (ignore (next ()); Some (statement ())) else None)
  | Id "while" -> let c = cond () in For (None, Some c, None, statement ())
  | Id "do" -> let body = statement () in ignore (next ()); let c = cond () in expect ";"; Do (body, c)
  | Id "for" ->
      (* an expression, or none, then the token that ends it *)
      let opt close = let e = if peek () = P close then None else Some (expr ()) in expect close; e in
      expect "(";
      let init = opt ";" in
      let c = Option.map rv (opt ";") in
      let step = opt ")" in
      For (init, c, step, statement ())
  | Id "switch" ->
      let v = conv (cond ()) long_t in
      let tmp = var (local long_t) long_t in
      Switch (tmp, v, statement ())
  | Id "case" -> let v = const_expr () in expect ":"; Block [ Case (Some v); statement () ]
  | Id "default" -> expect ":"; Block [ Case None; statement () ]
  | Id "break" -> expect ";"; Break
  | Id "continue" -> expect ";"; Continue
  | Id "return" ->
      if accept ";" then Return None
      else (let e = conv (rv (expr ())) !result in expect ";"; Return (Some e))
  | _ ->
      decr pos;
      if is_type () then Block (locals ())
      else (let e = expr () in expect ";"; Expr e)

and block () =
  scopes := Hashtbl.create 8 :: !scopes;
  let rec go acc = if accept "}" then List.rev acc else go (statement () :: acc) in
  let l = go [] in
  scopes := List.tl !scopes;
  Block l

(* a declaration of locals: their initializations *)
and locals () =
  let storage, bt = base_type () in
  let rec go () =
    let name, t = declarator bt in
    let init =
      if storage = Typedef then (Hashtbl.replace typedefs name t; [])
      else begin
        let p = local t in
        Hashtbl.replace (List.hd !scopes) name { vty = t; where = p };
        if accept "=" then [ Expr (assign (var p t) (assign_expr ())) ] else []
      end
    in
    init @ (if accept "," then go () else [])
  in
  let l = go () in
  expect ";";
  l

(*****************************************************************************)
(* The machine: the stack in R1..R15 (Wirth's register stack) *)
(*****************************************************************************)

let out = Buffer.create 65536
let ins fmt = Printf.ksprintf (fun s -> Buffer.add_string out ("\t" ^ s ^ "\n")) fmt

let load_op t = match t with Int (1, s) -> if s then "MOVB" else "MOVBU" | Int (2, s) -> if s then "MOVH" else "MOVHU" | Int (4, s) -> if s then "MOVW" else "MOVWU" | _ -> "MOV"
let store_op t = match size t with 1 -> "MOVB" | 2 -> "MOVH" | 4 -> "MOVW" | _ -> "MOV"

(* a value extended from its type: an int's by SXTW or MOVWU, a smaller
 * one's by shifts or a mask *)
let extend t r =
  match t with
  | Int (4, true) -> ins "SXTW\tR%d, R%d" r r
  | Int (4, false) -> ins "MOVWU\tR%d, R%d" r r
  | Int (n, true) when n < 4 -> ins "LSL\t$%d, R%d" (64 - (8 * n)) r; ins "ASR\t$%d, R%d" (64 - (8 * n)) r
  | Int (n, false) when n < 4 -> ins "AND\t$%d, R%d" ((1 lsl (8 * n)) - 1) r
  | _ -> ()

(* a relation's branch, signed or unsigned *)
let branch o u =
  match o with
  | Lt -> if u then "BLO" else "BLT" | Gt -> if u then "BHI" else "BGT"
  | Le -> if u then "BLS" else "BLE" | Ge -> if u then "BHS" else "BGE"
  | Eq -> "BEQ" | Ne -> "BNE"

(* one function's code: sp is the depth of the stack, Rsp its top.
 * The frame, as 7c's: the locals below SP, then the saves of what is
 * live across a call, then (from 8(R31) up) the outgoing arguments *)
let machine name (params : (string * ty) list) locals (body : ir list) =
  let sp = ref 0 and saves = ref 0 and outgoing = ref 0 and dead = ref false in
  let depth_at = Hashtbl.create 16 in
  let top () = !sp in
  let push () = incr sp; if !sp > 15 then error "%s: an expression too deep" name; !sp in
  let jump l = Hashtbl.replace depth_at l !sp in
  let saved = Buffer.contents out in
  Buffer.clear out;
  let slot i = locals + (8 * i) in
  List.iter (fun i ->
    match i with
    | Label l ->
        (* after a jump, the depth the label was jumped to with *)
        (match Hashtbl.find_opt depth_at l with Some d when !dead -> sp := d | _ -> ());
        dead := false;
        Buffer.add_string out (Printf.sprintf "L%d:\n" l)
    | _ when !dead -> ()
    | Imm v -> ins "MOV\t$%Ld, R%d" v (push ())
    | Place (Global s) -> ins "MOV\t$%s(SB), R%d" s (push ())
    | Place (Local o) -> ins "MOV\t$l-%d(SP), R%d" o (push ())
    | Place (Param o) -> ins "MOV\t$p+%d(FP), R%d" o (push ())
    | Load t -> ins "%s\t0(R%d), R%d" (load_op t) (top ()) (top ())
    | Store t -> let v = top () in decr sp; ins "%s\tR%d, 0(R%d)" (store_op t) v (top ()); ins "MOV\tR%d, R%d" v (top ())
    | Op (o, t) -> (
        let b = top () in
        decr sp;
        let a = top () and u = unsigned t in
        match o with
        | R r -> ins "CMP\tR%d, R%d" b a; ins "MOV\t$1, R%d" a; ins "%s\t2(PC)" (branch r u); ins "MOV\t$0, R%d" a
        | A o ->
            ins "%s\tR%d, R%d"
              (match o with
               | Add -> "ADD" | Sub -> "SUB" | Mul -> "MUL" | Div -> if u then "UDIV" else "SDIV" | Mod -> if u then "UREM" else "REM"
               | And -> "AND" | Or -> "ORR" | Xor -> "EOR" | Shl -> "LSL" | Shr -> if u then "LSR" else "ASR")
              b a;
            extend t a)
    | Unop (o, t) -> ins "%s\tR%d, R%d" (if o = Neg then "NEG" else "MVN") (top ()) (top ()); extend t (top ())
    | Ext t -> extend t (top ())
    | Dup -> let a = top () in ins "MOV\tR%d, R%d" a (push ())
    | Drop -> decr sp
    | Call (f, n, r) ->
        (* what is live below the arguments, saved: the callee may use any register *)
        let base = !sp - n in
        saves := max !saves base;
        for i = 1 to base do ins "MOV\tR%d, l-%d(SP)" i (slot i) done;
        for i = n - 1 downto 1 do ins "MOV\tR%d, %d(R31)" (base + 1 + i) (8 + (8 * i)) done;
        if n > 0 then ins "MOV\tR%d, R0" (base + 1);
        outgoing := max !outgoing (8 * n);
        ins "BL\t%s(SB)" f;
        for i = 1 to base do ins "MOV\tl-%d(SP), R%d" (slot i) i done;
        sp := base;
        if r then ins "MOV\tR0, R%d" (push ())
    | Jmp l -> jump l; ins "B\tL%d" l; dead := true
    | Jz l -> let a = top () in decr sp; jump l; ins "CBZ\tR%d, L%d" a l
    | Jnz l -> let a = top () in decr sp; jump l; ins "CBNZ\tR%d, L%d" a l
    | Ret v -> if v then (ins "MOV\tR%d, R0" (top ()); decr sp); ins "RETURN"; dead := true)
    body;
  if not !dead then ins "RETURN";
  let code = Buffer.contents out in
  Buffer.clear out;
  Buffer.add_string out saved;
  Buffer.add_string out (Printf.sprintf "\tTEXT\t%s(SB), $%d\n" name (slot !saves + !outgoing));
  (* the first parameter arrives in R0 *)
  (match params with (_, t) :: _ -> ins "%s\tR0, p+0(FP)" (store_op t) | [] -> ());
  Buffer.add_string out code

(*****************************************************************************)
(* The file: globals and functions *)
(*****************************************************************************)

(* -ir: the stack machine's code instead of the machine's *)
let ir_only = ref false

let asm_name storage name = if storage = Static then name ^ "<>" else name

(* a global's init_data, as DATA at offsets *)
let rec init_data name t off =
  match t, peek () with
  | Arr (e, _), P "{" ->
      ignore (next ());
      (* the elements, counted *)
      let rec elems i = if accept "}" then i else (ignore (init_data name e (off + (i * size e))); ignore (accept ","); elems (i + 1)) in
      elems 0
  | Arr (Int (1, _), n), Str s ->
      ignore (next ());
      String.iteri (fun i c -> Buffer.add_string data (Printf.sprintf "\tDATA\t%s+%d(SB)/1, $%d\n" name (off + i) (Char.code c))) s;
      max n (String.length s + 1)
  | _ ->
      let e = rv (assign_expr ()) in
      (match e.d, e.t with
       | Const v, _ -> Buffer.add_string data (Printf.sprintf "\tDATA\t%s+%d(SB)/%d, $%Ld\n" name off (size t) v)
       | Addr (Global s), _ -> Buffer.add_string data (Printf.sprintf "\tDATA\t%s+%d(SB)/8, $%s(SB)\n" name off s)
       | _ -> error "%s: not a constant init_data" name);
      1

let external_decl () =
  let storage, bt = base_type () in
  let rec go () =
    let name, t, pnames = declarator3 bt in
    match t with
    | Func (rt, ps, _) when storage <> Typedef && peek () = P "{" ->
        (* a definition *)
        Hashtbl.replace globals name { vty = t; where = Global (asm_name storage name) };
        ignore (next ());
        let params = List.combine pnames ps in
        scopes := [ Hashtbl.create 8 ];
        List.iteri (fun i (p, pt) -> Hashtbl.replace (List.hd !scopes) p { vty = pt; where = Param (8 * i) }) params;
        frame := 0;
        result := rt;
        let body = block () in
        code := [];
        lower { brk = None; cont = None; cases = ref [] } body;
        if !ir_only then (Buffer.add_string out (name ^ ":\n"); List.iter (fun i -> Buffer.add_string out ("\t" ^ show i ^ "\n")) (List.rev !code))
        else machine (asm_name storage name) params (round !frame 8) (List.rev !code);
        scopes := []
    | _ ->
        let sym = asm_name storage name in
        (match storage, t with
         | Typedef, _ -> Hashtbl.replace typedefs name t
         | _, Func _ -> Hashtbl.replace globals name { vty = t; where = Global sym }
         | _ ->
             let t = if accept "=" then (match t with Arr (e, 0) -> let n = init_data sym t 0 in Arr (e, n) | _ -> ignore (init_data sym t 0); t) else t in
             Hashtbl.replace globals name { vty = t; where = Global sym };
             if storage <> Extern then Buffer.add_string data (Printf.sprintf "\tGLOBL\t%s(SB), $%d\n" sym (size t)));
        if accept "," then go () else expect ";"
  in
  if not (accept ";") then go ()

let main () =
  let output = ref "" and file = ref "" in
  let rec args = function
    | "-ir" :: r -> ir_only := true; args r
    | "-o" :: o :: r -> output := o; args r
    | f :: r -> file := f; args r
    | [] -> ()
  in
  args (List.tl (Array.to_list Sys.argv));
  if !file = "" then (prerr_endline "usage: tiny-c [-ir] [-o out.s] file.c"; exit 2);
  let read f = In_channel.with_open_bin f In_channel.input_all in
  try
    toks := Array.of_list (tokens (Hashtbl.create 16) read !file);
    while peek () <> EOF do external_decl () done;
    let text = Buffer.contents out ^ (if !ir_only then "" else Buffer.contents data) in
    if !output = "" then print_string text else Out_channel.with_open_bin !output (fun oc -> output_string oc text)
  with Failure m -> Printf.eprintf "%s: %s\n" !file m; exit 1

let () = main ()
