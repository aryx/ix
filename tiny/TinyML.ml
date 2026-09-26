(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny ML compiler for arm64, in one file. mini-ml (languages/ml/,
 * planned: docs/plans/plan_ml.md) is ocaml-light's native compiler's
 * twin in behavior: its dialect, its modules, the kernel as its target.
 * This is what is left of an ML compiler when the language is small and
 * the code need only be correct:
 *
 *     tiny-ml -o prog.s prog.ml
 *     tiny-c -o runtime.s TinyML_runtime.c
 *     tiny-assembler -o prog prog.s runtime.s libc/*.s && ./prog
 *
 * one ML file in, its arm64 assembly out, in Plan 9's syntax, for
 * TinyAssembler; the runtime (the allocator, Cheney's collector, the
 * primitives, the printing of an uncaught exception) in C, compiled by
 * tiny-c; goken's libc under both. A program prints what ocaml-light's
 * ocamlopt makes it print, on arm64: that is the test.
 *
 * The language: integers (63 bits), characters, strings, booleans,
 * unit, tuples, lists, variants (type declarations, polymorphic,
 * recursive), references, exceptions (declared, raised, caught);
 * let, let rec, and, fun, function, match with guards, as and
 * or-patterns (without variables), if, sequences, while, for;
 * external, for the prelude (below: the Pervasives and List functions
 * a program uses, in ML); Hindley-Milner's types with the value
 * restriction. Left out: modules (String.length is one name),
 * records, arrays, floats, labels, objects, functors, and type
 * abbreviations.
 *
 * What makes it small, and still an ML compiler:
 *
 * - {b Types checked, then forgotten.} The checker (Hindley-Milner,
 *   Rémy's levels for generalization) is a pass whose result the code
 *   generator reads at one place: a comparison whose operands are
 *   integers is inlined, the others call the runtime's polymorphic
 *   compare. Everything else is one representation: a word, an
 *   integer 2n+1 or a pointer to a block (a header, then fields).
 * - {b A stack machine in between}, TinyC's (IR, below): expressions
 *   push their value, the stack in R1..R15, and a pattern is a
 *   sequence of tests, each jumping to the next clause.
 * - {b A value stack for the roots} (plan_ml.md, decision 5;
 *   Henderson's shadow stack): each function's variables, and the
 *   registers spilled at a call or an allocation, are words of a stack
 *   of values whose top is R26, a register 7c never allocates. The
 *   machine's stack holds return addresses, C's frames and exception
 *   handlers, never a value; so the collector finds every root without
 *   a frame table, and moves them: Cheney's copying collector, in C.
 * - {b Closures, and calls of known functions.} A function is a block
 *   [unary code; n-ary code; free variables...]. Applying an unknown
 *   function passes one argument at a time through the first field;
 *   for an arity above 1 that is a curry function (ml_currynk), which
 *   gathers the arguments in blocks and calls the n-ary code, as
 *   ocaml-light's caml_curryN. A call of a let-bound function with
 *   all its arguments calls its n-ary code directly; a function
 *   without free variables is a static block. Calls in tail position
 *   are jumps, so a let rec loop runs in constant space.
 * - {b Exceptions without assembly in the runtime.} try pushes a
 *   record on the machine stack (the stack pointer, R26, the handler's
 *   address, the previous record); raise restores the two stack
 *   pointers from the latest and jumps. The handler's address is
 *   what a BL over it leaves in R30, as setjmp.
 * - {b Its own frames.} Every function is TEXT $-8, a frame
 *   TinyAssembler leaves alone: the prologue and epilogue are the
 *   compiler's, so a tail call can undo the frame and jump.
 * - {b The prelude is ML}: raise, the operators, ref, ! and := are
 *   externals whose names say the instructions ("%add"); print_string
 *   or ^ name C functions of the runtime; List.map and the others are
 *   ML, compiled with the program, and only what the program uses is
 *   linked (TinyAssembler keeps what the entry reaches).
 *
 * Its behavior follows ocaml-light's arm64 ocamlopt, the contract,
 * quirks included: right-to-left evaluation of arguments and tuples;
 * stdout buffered by 4096 bytes and lost on an uncaught exception;
 * that exception printed as ocaml-light's printexc.c prints it, with
 * the exit status 2; division by zero is 0 (SDIV's), not an
 * exception; a string's index out of bounds a fatal error.
 *
 * Exercises, each cheap because of the stack machine or the value
 * stack:
 * - records and arrays: blocks, a label a field's index;
 * - arm32: a second back end of the stack machine, as TinyC's -tm;
 * - allocation inline: the heap's pointer and limit in two registers,
 *   the collector called only when the block doesn't fit;
 * - fewer spills: at a call, only the registers below the arguments
 *   (the arguments are passed in registers, and could stay there);
 * - a switch on the constructors' tags instead of a test per clause;
 * - exhaustiveness warnings (Maranget, "Warnings for pattern
 *   matching", 2007).
 *
 * References: Robin Milner, "A Theory of Type Polymorphism in
 * Programming" (1978); Didier Rémy's levels, as Oleg Kiselyov's "How
 * OCaml type checker works" (2013) explains them; Andrew Wright, "Simple
 * imperative polymorphism" (1995), the value restriction; C. J. Cheney,
 * "A nonrecursive list compacting algorithm" (CACM, 1970); Fergus
 * Henderson, "Accurate garbage collection in an uncooperative
 * environment" (ISMM 2002); Simon Marlow and Simon Peyton Jones,
 * "Making a fast curry" (ICFP 2004); Xavier Leroy, "The ZINC experiment"
 * (1990), the representation of values (all from memory; plan_ml.md's
 * related work has them). *)

let error fmt = Printf.ksprintf failwith fmt
let sprintf = Printf.sprintf

(*****************************************************************************)
(* Tokens *)
(*****************************************************************************)

(* a keyword and a symbol are both KW *)
type token = INT of int | CHAR of int | STR of string | LID of string | UID of string | KW of string | EOF

let keywords =
  [ "let"; "rec"; "in"; "fun"; "function"; "match"; "with"; "if"; "then"; "else"; "begin"; "end"; "try"; "type"; "of";
    "exception"; "external"; "and"; "when"; "as"; "while"; "for"; "to"; "downto"; "do"; "done"; "mod"; "land"; "lor";
    "lxor"; "lsl"; "lsr"; "asr"; "or" ]

let symbols = [ ";;"; "->"; "::"; ":="; "<="; ">="; "<>"; "=="; "!="; "&&"; "||"; ".["; "~-" ]

(* the tokens of a file, each with its line; String.length is one
 * name, true and false constructors *)
let lex (s : string) : (token * int) array =
  let n = String.length s and out = ref [] and line = ref 1 in
  let add t = out := (t, !line) :: !out in
  let is_id c = match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' -> true | _ -> false in
  let rec span j = if j < n && is_id s.[j] then span (j + 1) else j in
  let escape i =
    match s.[i] with
    | 'n' -> 10, i + 1 | 't' -> 9, i + 1 | 'r' -> 13, i + 1 | 'b' -> 8, i + 1
    | '0' .. '9' -> int_of_string (String.sub s i 3), i + 3
    | c -> Char.code c, i + 1
  in
  let rec comment i depth =
    if i + 1 >= n then error "unterminated comment"
    else if s.[i] = '*' && s.[i + 1] = ')' then if depth = 1 then i + 2 else comment (i + 2) (depth - 1)
    else if s.[i] = '(' && s.[i + 1] = '*' then comment (i + 2) (depth + 1)
    else (if s.[i] = '\n' then incr line; comment (i + 1) depth)
  in
  let rec go i =
    if i < n then
      match s.[i] with
      | '\n' -> incr line; go (i + 1)
      | ' ' | '\t' | '\r' -> go (i + 1)
      | '(' when i + 1 < n && s.[i + 1] = '*' -> go (comment (i + 2) 1)
      | '0' .. '9' -> let j = span i in add (INT (int_of_string (String.sub s i (j - i)))); go j
      | 'a' .. 'z' | '_' ->
          let j = span i in
          let w = String.sub s i (j - i) in
          add (if w = "_" then KW w else if List.mem w keywords then KW w else if w = "true" || w = "false" then UID w else LID w);
          go j
      | 'A' .. 'Z' ->
          let j = span i in
          let j = if j + 1 < n && s.[j] = '.' && (match s.[j + 1] with 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false) then span (j + 1) else j in
          let w = String.sub s i (j - i) in
          add (match String.rindex_opt w '.' with Some k when w.[k + 1] >= 'a' -> LID w | _ -> UID w);
          go j
      | '\'' when i + 2 < n && (s.[i + 2] = '\'' || s.[i + 1] = '\\') ->
          let c, j = if s.[i + 1] = '\\' then escape (i + 2) else Char.code s.[i + 1], i + 2 in
          add (CHAR c);
          go (j + 1)
      | '"' ->
          let b = Buffer.create 16 in
          let rec str j =
            match s.[j] with
            | '"' -> j + 1
            | '\\' -> let c, j = escape (j + 1) in Buffer.add_char b (Char.chr c); str j
            | c -> if c = '\n' then incr line; Buffer.add_char b c; str (j + 1)
          in
          let j = str (i + 1) in
          add (STR (Buffer.contents b));
          go j
      | _ ->
          let p = List.find_opt (fun p -> i + String.length p <= n && String.sub s i (String.length p) = p) symbols in
          let p = Option.value p ~default:(String.make 1 s.[i]) in
          add (KW p);
          go (i + String.length p)
  in
  go 0;
  add EOF;
  Array.of_list (List.rev !out)

(*****************************************************************************)
(* The tree *)
(*****************************************************************************)

(* a type variable is a cell: unbound (its number and level), or linked
 * to what it became *)
type ty = TVar of tvar ref | TCon of string * ty list
and tvar = Unbound of int * int | Link of ty

type const = CInt of int | CChar of int | CStr of string

type pat = PAny | PVar of string | PConst of const | PCon of string * pat list | PTuple of pat list | PAlias of pat * string | POr of pat * pat

type expr =
  | Const of const
  | Var of string * ty ref            (* its type where it is used, which a comparison reads *)
  | Con of string * expr list
  | Tuple of expr list
  | App of expr * expr list
  | Fun of string list * expr         (* a parameter's pattern is a let in the body *)
  | Let of bool * (pat * expr) list * expr
  | Match of expr * case list
  | Try of expr * case list
  | If of expr * expr * expr
  | Seq of expr * expr
  | While of expr * expr
  | For of string * expr * expr * bool * expr

and case = pat * expr option * expr

type texpr = TE of string * texpr list | TEVar of string

type item = ILet of bool * (pat * expr) list | IExt of string * texpr * string | IExn of string

(* a constructor: its number among its type's constant ones or among
 * the others (a block's tag), or an exception; its type as
 * %c(result, arguments...), generic in the type's parameters *)
type kind = KConst of int | KBlock of int | KExn
type cinfo = { kind : kind; arity : int; nconst : int; nblock : int; scheme : ty }

let cons : (string, cinfo) Hashtbl.t = Hashtbl.create 64
let find_con c = match Hashtbl.find_opt cons c with Some ci -> ci | None -> error "unknown constructor %s" c

let generic = max_int
let level = ref 1 and counter = ref 0
let newvar () = incr counter; TVar (ref (Unbound (!counter, !level)))
let genvar () = incr counter; TVar (ref (Unbound (!counter, generic)))
let tcon c = TCon (c, [])
let arrow a b = TCon ("->", [ a; b ])
let int_t = tcon "int" and bool_t = tcon "bool" and unit_t = tcon "unit" and string_t = tcon "string"

let () =
  let a = genvar () in
  let add c kind arity nconst nblock res args = Hashtbl.replace cons c { kind; arity; nconst; nblock; scheme = TCon ("%c", res :: args) } in
  add "()" (KConst 0) 0 1 0 unit_t [];
  add "false" (KConst 0) 0 2 0 bool_t [];
  add "true" (KConst 1) 0 2 0 bool_t [];
  add "[]" (KConst 0) 0 1 1 (TCon ("list", [ a ])) [];
  add "::" (KBlock 0) 2 1 1 (TCon ("list", [ a ])) [ a; TCon ("list", [ a ]) ]

let rec of_texpr vars = function
  | TEVar v -> (match List.assoc_opt v !vars with Some t -> t | None -> let t = genvar () in vars := (v, t) :: !vars; t)
  | TE (c, args) -> TCon (c, List.map (of_texpr vars) args)

(*****************************************************************************)
(* The parser *)
(*****************************************************************************)

let toks = ref [||] and pos = ref 0
let peek () = fst !toks.(!pos)
let peek_at k = fst !toks.(min (!pos + k) (Array.length !toks - 1))
let line () = snd !toks.(!pos)
let advance () = if peek () <> EOF then incr pos
let accept t = if peek () = t then (advance (); true) else false
let show_tok = function INT n -> string_of_int n | CHAR _ -> "a character" | STR _ -> "a string" | LID x | UID x | KW x -> x | EOF -> "the end"
let fail () = error "line %d: syntax error at %s" (line ()) (show_tok (peek ()))
let expect t = if not (accept t) then fail ()
let var x = Var (x, ref (tcon "?"))
let fresh = ref 0

(* the operators: precedence and right associativity; "," is 1 *)
let binops =
  [ ":=", 0, true; "||", 2, true; "or", 2, true; "&&", 3, true; "&", 3, true; "=", 4, false; "<>", 4, false; "<", 4, false;
    ">", 4, false; "<=", 4, false; ">=", 4, false; "==", 4, false; "!=", 4, false; "@", 5, true; "^", 5, true; "::", 6, true;
    "+", 7, false; "-", 7, false; "*", 8, false; "/", 8, false; "mod", 8, false; "land", 8, false; "lor", 8, false;
    "lxor", 8, false; "lsl", 9, true; "lsr", 9, true; "asr", 9, true ]

let is_op o = List.exists (fun (b, _, _) -> b = o) binops || o = "!" || o = "~-"

(* C (a, b) is a constructor of two arguments, the tuple its parser saw *)
let con_args c args untuple =
  let ci = find_con c in
  match args with
  | [] when ci.arity = 0 -> []
  | [ a ] when ci.arity = 1 -> [ a ]
  | [ a ] when ci.arity > 1 -> (match untuple ci.arity a with Some l when List.length l = ci.arity -> l | _ -> error "line %d: %s expects %d arguments" (line ()) c ci.arity)
  | _ -> error "line %d: %s expects %d arguments" (line ()) c ci.arity

let starts_atom = function INT _ | CHAR _ | STR _ | LID _ | UID _ | KW ("(" | "[" | "begin" | "!") -> true | _ -> false
let starts_patom = function INT _ | CHAR _ | STR _ | LID _ | UID _ | KW ("_" | "(" | "[") -> true | _ -> false

(* expressions: a sequence, then let/match/fun/if, then the operators
 * by precedence climbing, then application *)
let rec expr () =
  let e = stmt () in
  if accept (KW ";") then
    match peek () with
    | KW ("end" | ")" | "done" | "in" | ";;" | "|" | "]" | "with" | "else" | "then") | EOF -> e
    | _ -> Seq (e, expr ())
  else e

and stmt () =
  match peek () with
  | KW "let" -> advance (); let r = accept (KW "rec") in let bs = bindings () in expect (KW "in"); Let (r, bs, expr ())
  | KW "match" -> advance (); let e = expr () in expect (KW "with"); Match (e, cases ())
  | KW "try" -> advance (); let e = expr () in expect (KW "with"); Try (e, cases ())
  | KW "function" -> advance (); Fun ([ "%f" ], Match (var "%f", cases ()))
  | KW "fun" -> advance (); let ps = params () in expect (KW "->"); fun_of ps (expr ())
  | KW "if" ->
      advance ();
      let c = expr () in
      expect (KW "then");
      let a = stmt () in
      If (c, a, if accept (KW "else") then stmt () else Con ("()", []))
  | KW "while" -> advance (); let c = expr () in expect (KW "do"); let b = expr () in expect (KW "done"); While (c, b)
  | KW "for" ->
      advance ();
      let x = match peek () with LID x -> advance (); x | _ -> fail () in
      expect (KW "=");
      let a = expr () in
      let up = if accept (KW "to") then true else (expect (KW "downto"); false) in
      let b = expr () in
      expect (KW "do");
      let body = expr () in
      expect (KW "done");
      For (x, a, b, up, body)
  | _ -> binary 0

and binary min =
  let rec loop lhs =
    match peek () with
    | KW "," when min <= 1 ->
        let rec more () = advance (); let e = binary 2 in if peek () = KW "," then e :: more () else [ e ] in
        loop (Tuple (lhs :: more ()))
    | KW op -> (
        match List.find_opt (fun (o, _, _) -> o = op) binops with
        | Some (_, p, right) when p >= min ->
            advance ();
            let rhs = binary (if right then p else p + 1) in
            loop
              (match op with
               | "::" -> Con ("::", [ lhs; rhs ])
               | "&&" | "&" -> If (lhs, rhs, Con ("false", []))
               | "||" | "or" -> If (lhs, Con ("true", []), rhs)
               | _ -> App (var op, [ lhs; rhs ]))
        | _ -> lhs)
    | _ -> lhs
  in
  loop (unary ())

and unary () =
  match peek () with
  | KW "-" -> advance (); (match peek () with INT n -> advance (); Const (CInt (-n)) | _ -> App (var "~-", [ unary () ]))
  | _ -> app ()

and app () =
  match peek () with
  | UID c when starts_atom (peek_at 1) && (find_con c).arity > 0 ->
      advance ();
      let a = atom () in
      Con (c, con_args c [ a ] (fun _ -> function Tuple l -> Some l | _ -> None))
  | _ -> (
      let f = atom () in
      let rec args () = if starts_atom (peek ()) then let a = atom () in a :: args () else [] in
      match args () with [] -> f | l -> App (f, l))

and atom () =
  let e =
    match peek () with
    | INT n -> advance (); Const (CInt n)
    | CHAR c -> advance (); Const (CChar c)
    | STR s -> advance (); Const (CStr s)
    | LID x -> advance (); var x
    | UID c -> advance (); Con (c, con_args c [] (fun _ _ -> None))
    | KW "!" -> advance (); App (var "!", [ atom () ])
    | KW "(" -> (
        advance ();
        if accept (KW ")") then Con ("()", [])
        else
          match peek (), peek_at 1 with
          | KW op, KW ")" when is_op op -> advance (); advance (); var op
          | _ -> let e = expr () in if accept (KW ":") then ignore (ty ()); expect (KW ")"); e)
    | KW "begin" -> advance (); if accept (KW "end") then Con ("()", []) else (let e = expr () in expect (KW "end"); e)
    | KW "[" ->
        advance ();
        let rec elems () = if accept (KW "]") then Con ("[]", []) else (let e = stmt () in ignore (accept (KW ";")); Con ("::", [ e; elems () ])) in
        elems ()
    | KW ("let" | "match" | "try" | "fun" | "function" | "if" | "while" | "for") -> stmt ()
    | _ -> fail ()
  in
  postfix e

and postfix e = if accept (KW ".[") then (let i = expr () in expect (KW "]"); postfix (App (var "String.get", [ e; i ]))) else e

and cases () =
  ignore (accept (KW "|"));
  let p = pattern () in
  let g = if accept (KW "when") then Some (expr ()) else None in
  expect (KW "->");
  let e = expr () in
  (p, g, e) :: (if peek () = KW "|" then cases () else [])

(* patterns: as, then |, then the tuple, then ::, then a constructor's *)
and pattern () =
  let p = por () in
  if accept (KW "as") then (match peek () with LID x -> advance (); PAlias (p, x) | _ -> fail ()) else p

and por () = let p = ptuple () in if accept (KW "|") then POr (p, por ()) else p

and ptuple () =
  let p = pcons () in
  if peek () = KW "," then (let rec more () = if accept (KW ",") then let q = pcons () in q :: more () else [] in PTuple (p :: more ()))
  else p

and pcons () = let p = papp () in if accept (KW "::") then PCon ("::", [ p; pcons () ]) else p

and papp () =
  match peek () with
  | UID c when starts_patom (peek_at 1) && (find_con c).arity > 0 ->
      advance ();
      let a = patom () in
      PCon (c, con_args c [ a ] (fun n -> function PTuple l -> Some l | PAny -> Some (List.init n (fun _ -> PAny)) | _ -> None))
  | _ -> patom ()

and patom () =
  match peek () with
  | LID x -> advance (); PVar x
  | KW "_" -> advance (); PAny
  | INT n -> advance (); PConst (CInt n)
  | CHAR c -> advance (); PConst (CChar c)
  | STR s -> advance (); PConst (CStr s)
  | KW "-" -> advance (); (match peek () with INT n -> advance (); PConst (CInt (-n)) | _ -> fail ())
  | UID c -> advance (); PCon (c, con_args c [] (fun _ _ -> None))
  | KW "(" -> advance (); if accept (KW ")") then PCon ("()", []) else (let p = pattern () in if accept (KW ":") then ignore (ty ()); expect (KW ")"); p)
  | KW "[" ->
      advance ();
      let rec elems () = if accept (KW "]") then PCon ("[]", []) else (let p = pattern () in ignore (accept (KW ";")); PCon ("::", [ p; elems () ])) in
      elems ()
  | _ -> fail ()

and params () = if starts_patom (peek ()) then let p = patom () in p :: params () else []

(* fun p q -> e: a pattern other than a name is a let of the parameter *)
and fun_of ps body =
  let names, body =
    List.fold_right (fun p (names, body) ->
      match p with
      | PVar x -> x :: names, body
      | p -> incr fresh; let x = sprintf "%%p%d" !fresh in x :: names, Let (false, [ p, var x ], body))
      ps ([], body)
  in
  Fun (names, body)

and bindings () = let b = binding () in if accept (KW "and") then b :: bindings () else [ b ]

and binding () =
  let name =
    match peek (), peek_at 1 with
    | LID x, t when not (List.mem t [ KW "="; KW ","; KW ":"; KW "as"; KW "::" ]) -> advance (); Some x
    | KW "(", KW op when is_op op && peek_at 2 = KW ")" -> advance (); advance (); advance (); Some op
    | _ -> None
  in
  match name with
  | Some f -> let ps = params () in if accept (KW ":") then ignore (ty ()); expect (KW "="); PVar f, (if ps = [] then expr () else fun_of ps (expr ()))
  | None -> let p = pattern () in if accept (KW ":") then ignore (ty ()); expect (KW "="); p, expr ()

(* types: ->, then *, then applications of names (int list) *)
and ty () = let t = ty_tuple () in if accept (KW "->") then TE ("->", [ t; ty () ]) else t

and ty_tuple () = match ty_args () with [ t ] -> t | l -> TE ("*", l)

and ty_args () = let t = ty_app () in if accept (KW "*") then t :: ty_args () else [ t ]

and ty_app () =
  let args =
    match peek () with
    | KW "'" -> advance (); (match peek () with LID v -> advance (); [ TEVar v ] | _ -> fail ())
    | KW "(" -> advance (); let rec go () = let t = ty () in if accept (KW ",") then t :: go () else [ t ] in let l = go () in expect (KW ")"); l
    | LID c -> advance (); [ TE (c, []) ]
    | _ -> fail ()
  in
  let rec post args = match peek () with LID c -> advance (); post [ TE (c, args) ] | _ -> args in
  match post args with [ t ] -> t | _ -> fail ()

(* type ('a, 'b) t = A | B of 'a * t and ...: the constructors
 * numbered, the constant ones and the others apart *)
let rec type_decl () =
  let tvar () = expect (KW "'"); match peek () with LID v -> advance (); v | _ -> fail () in
  let params =
    match peek () with
    | KW "'" -> [ tvar () ]
    | KW "(" -> advance (); let rec go () = let v = tvar () in if accept (KW ",") then v :: go () else [ v ] in let l = go () in expect (KW ")"); l
    | _ -> []
  in
  let name = match peek () with LID x -> advance (); x | _ -> fail () in
  expect (KW "=");
  ignore (accept (KW "|"));
  let vars = ref (List.map (fun v -> v, genvar ()) params) in
  let res = TCon (name, List.map snd !vars) in
  let rec ctors () =
    let c = match peek () with UID c -> advance (); c | _ -> error "line %d: only variant types" (line ()) in
    let args = if accept (KW "of") then List.map (of_texpr vars) (ty_args ()) else [] in
    (c, args) :: (if accept (KW "|") then ctors () else [])
  in
  let cs = ctors () in
  let nconst = List.length (List.filter (fun (_, a) -> a = []) cs) in
  let nblock = List.length cs - nconst in
  let ic = ref 0 and ib = ref 0 in
  List.iter (fun (c, args) ->
    let kind = if args = [] then (incr ic; KConst (!ic - 1)) else (incr ib; KBlock (!ib - 1)) in
    Hashtbl.replace cons c { kind; arity = List.length args; nconst; nblock; scheme = TCon ("%c", res :: args) }) cs;
  if accept (KW "and") then type_decl ()

let rec items () : (item * int) list =
  let l = line () in
  match peek () with
  | EOF -> []
  | KW ";;" -> advance (); items ()
  | KW "let" ->
      advance ();
      let r = accept (KW "rec") in
      let bs = bindings () in
      if accept (KW "in") then (let e = Let (r, bs, expr ()) in (ILet (false, [ PAny, e ]), l) :: items ())
      else (ILet (r, bs), l) :: items ()
  | KW "type" -> advance (); type_decl (); items ()
  | KW "exception" ->
      advance ();
      let c = match peek () with UID c -> advance (); c | _ -> fail () in
      let args = if accept (KW "of") then List.map (of_texpr (ref [])) (ty_args ()) else [] in
      Hashtbl.replace cons c { kind = KExn; arity = List.length args; nconst = 0; nblock = 0; scheme = TCon ("%c", tcon "exn" :: args) };
      (IExn c, l) :: items ()
  | KW "external" ->
      advance ();
      let x =
        match peek () with
        | LID x -> advance (); x
        | KW "(" -> advance (); let o = (match peek () with KW o -> advance (); o | _ -> fail ()) in expect (KW ")"); o
        | _ -> fail ()
      in
      expect (KW ":");
      let t = ty () in
      expect (KW "=");
      let p = match peek () with STR p -> advance (); p | _ -> fail () in
      (IExt (x, t, p), l) :: items ()
  | _ -> let e = expr () in (ILet (false, [ PAny, e ]), l) :: items ()

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

let rec repr t = match t with TVar { contents = Link t } -> repr t | t -> t

let rec show t =
  match repr t with
  | TVar { contents = Unbound (n, _) } -> sprintf "'_%d" n
  | TCon ("->", [ a; b ]) -> sprintf "(%s -> %s)" (show a) (show b)
  | TCon ("*", ts) -> "(" ^ String.concat " * " (List.map show ts) ^ ")"
  | TCon (c, []) -> c
  | TCon (c, ts) -> "(" ^ String.concat ", " (List.map show ts) ^ ") " ^ c
  | TVar _ -> "?"

(* x's variable in its own type is an error; a variable met at a lower
 * level takes it, so that it is generalized only where both are *)
let rec occurs r lv t =
  match repr t with
  | TVar r' when r == r' -> error "a recursive type"
  | TVar ({ contents = Unbound (n, l) } as r') -> if l > lv then r' := Unbound (n, lv)
  | TCon (_, ts) -> List.iter (occurs r lv) ts
  | TVar _ -> ()

let rec unify a b =
  match repr a, repr b with
  | TVar r, TVar r' when r == r' -> ()
  | TVar ({ contents = Unbound (_, l) } as r), t | t, TVar ({ contents = Unbound (_, l) } as r) -> occurs r l t; r := Link t
  | TCon (c, ts), TCon (d, us) when c = d && List.length ts = List.length us -> List.iter2 unify ts us
  | a, b -> error "this has type %s but is used with type %s" (show a) (show b)

(* the variables deeper than the current let become parameters *)
let rec generalize t =
  match repr t with
  | TVar ({ contents = Unbound (n, l) } as r) when l > !level -> r := Unbound (n, generic)
  | TCon (_, ts) -> List.iter generalize ts
  | TVar _ -> ()

let instantiate t =
  let copies = Hashtbl.create 8 in
  let rec go t =
    match repr t with
    | TVar { contents = Unbound (n, l) } when l = generic -> (
        match Hashtbl.find_opt copies n with Some v -> v | None -> let v = newvar () in Hashtbl.replace copies n v; v)
    | TCon (c, ts) -> TCon (c, List.map go ts)
    | t -> t
  in
  go t

(* the value restriction: only a value is generalized *)
let rec nonexpansive = function
  | Const _ | Var _ | Fun _ -> true
  | Con (_, l) | Tuple l -> List.for_all nonexpansive l
  | _ -> false

let con_type c = match instantiate (find_con c).scheme with TCon (_, res :: args) -> res, args | _ -> assert false
let const_type = function CInt _ -> int_t | CChar _ -> tcon "char" | CStr _ -> string_t

let rec pat_type p : ty * (string * ty) list =
  match p with
  | PAny -> newvar (), []
  | PVar x -> let t = newvar () in t, [ x, t ]
  | PConst c -> const_type c, []
  | PCon (c, ps) ->
      let res, args = con_type c in
      res, List.concat (List.map2 (fun p t -> let pt, b = pat_type p in unify pt t; b) ps args)
  | PTuple ps -> let l = List.map pat_type ps in TCon ("*", List.map fst l), List.concat_map snd l
  | PAlias (p, x) -> let t, b = pat_type p in t, (x, t) :: b
  | POr (a, b) ->
      let t, ba = pat_type a and u, bb = pat_type b in
      unify t u;
      if ba <> [] || bb <> [] then error "an or-pattern with variables";
      t, []

let rec infer env e : ty =
  match e with
  | Const c -> const_type c
  | Var (x, r) -> (match List.assoc_opt x env with Some t -> r := instantiate t; !r | None -> error "unbound %s" x)
  | Con (c, args) -> let res, targs = con_type c in List.iter2 (fun a t -> unify (infer env a) t) args targs; res
  | Tuple es -> TCon ("*", List.map (infer env) es)
  | App (f, args) -> List.fold_left (fun tf a -> let r = newvar () in unify tf (arrow (infer env a) r); r) (infer env f) args
  | Fun (xs, b) ->
      let ts = List.map (fun _ -> newvar ()) xs in
      List.fold_right arrow ts (infer (List.rev (List.combine xs ts) @ env) b)
  | Let (false, bs, b) -> infer (let_types env bs) b
  | Let (true, bs, b) -> infer (rec_types env bs) b
  | Match (e, cases) -> cases_type env (infer env e) cases
  | Try (e, cases) -> let t = infer env e in unify t (cases_type env (tcon "exn") cases); t
  | If (c, a, b) -> unify (infer env c) bool_t; let t = infer env a in unify t (infer env b); t
  | Seq (a, b) -> ignore (infer env a); infer env b
  | While (c, b) -> unify (infer env c) bool_t; ignore (infer env b); unit_t
  | For (x, a, b, _, body) -> unify (infer env a) int_t; unify (infer env b) int_t; ignore (infer ((x, int_t) :: env) body); unit_t

and cases_type env t cases =
  let r = newvar () in
  List.iter (fun (p, g, e) ->
    let pt, bs = pat_type p in
    unify pt t;
    let env = bs @ env in
    Option.iter (fun g -> unify (infer env g) bool_t) g;
    unify (infer env e) r) cases;
  r

and let_types env bs =
  List.concat_map (fun (p, e) ->
    incr level;
    let t = infer env e in
    decr level;
    match p with
    | PVar x -> if nonexpansive e then generalize t else unify (newvar ()) t; [ x, t ]
    | p -> let pt, b = pat_type p in unify pt t; b) bs
  @ env

and rec_types env bs =
  incr level;
  let vars = List.map (function PVar x, _ -> x, newvar () | _ -> error "let rec: a name expected") bs in
  List.iter2 (fun (_, t) (_, e) -> unify t (infer (vars @ env) e)) vars bs;
  decr level;
  List.iter (fun (_, t) -> generalize t) vars;
  vars @ env

let type_item env (it, l) =
  try
    match it with
    | ILet (false, bs) -> let_types env bs
    | ILet (true, bs) -> rec_types env bs
    | IExt (x, t, _) -> (x, of_texpr (ref []) t) :: env
    | IExn _ -> env
  with Failure m -> error "line %d: %s" l m

(*****************************************************************************)
(* The stack machine *)
(*****************************************************************************)

type rel = Eq | Ne | Lt | Le | Gt | Ge
type op = Add | Sub | Mul | Div | Mod | And | Or | Xor | Lsl | Lsr | Asr | Cmp of rel | Neg | Lnot | Not | IsInt | Tag
type target = Direct of string | Code of int   (* a function's n-ary code, or a closure's field *)

(* a binary operation's first operand is on top, as every operation's:
 * arguments are pushed from the last, as OCaml evaluates them *)
type ir =
  | Imm of int64                      (* a word, an integer already tagged *)
  | Addr of string * int              (* a symbol's address: a static block's value is its +8 *)
  | Get of int | Set of int           (* a slot of the function's frame on the value stack *)
  | GetG of int | SetG of int         (* a global of the program *)
  | Field of int                      (* a block by its field *)
  | SetField of int                   (* the value below the block stored in its field *)
  | Alloc of int * int                (* a tag, n values by the block of them, the top its field 0 *)
  | Op of op
  | Call of target * int * bool       (* the closure then n arguments by the result; a tail call *)
  | CallC of string * int             (* a runtime's function of n arguments *)
  | Label of int | Jmp of int
  | Jz of int | Jnz of int            (* false is 1, the tagged 0 *)
  | Drop
  | Ret
  | Raise                             (* the top raised; its place taken by the result, never seen *)
  | TryEnter of int * int             (* the k-th handler of the function, its code *)
  | TryExit of int
  | Catch of int                      (* the handler's entry: the exception pushed *)

let labels = ref 0
let label () = incr labels; !labels
let text = Buffer.create 65536 and data = Buffer.create 16384

(*****************************************************************************)
(* The machine: arm64, the stack in R1..R15, the value stack at R26 *)
(*****************************************************************************)

(* A function's frames. On the value stack, f words below R26 (its top,
 * which the function raises by f at its entry): slot 0 its closure,
 * then its parameters, its variables, and a slot per register of the
 * stack machine, where a call or an allocation spills it. On the
 * machine stack, m bytes: the link at 0, then C's outgoing arguments
 * (7c's: the first in R0, the others at 16(R31) up), then 32 bytes per
 * handler, from c. All are known at the end, so each line is a
 * function of them. *)
let machine name nparams nslots (code : ir list) =
  let lines = ref [] in
  let line f = lines := f :: !lines in
  let ins fmt = Printf.ksprintf (fun s -> line (fun _ _ _ -> "\t" ^ s ^ "\n")) fmt in
  let sp = ref 0 and maxsp = ref 0 and tries = ref 0 and cargs = ref 0 and dead = ref false in
  let depth_at = Hashtbl.create 16 and catch_at = Hashtbl.create 4 in
  let get i r = line (fun f _ _ -> sprintf "\tMOV\t%d(R26), R%d\n" (8 * (i - f)) r) in
  let put r i = line (fun f _ _ -> sprintf "\tMOV\tR%d, %d(R26)\n" r (8 * (i - f))) in
  let spill_slot r = nslots + r - 1 in
  let push () = incr sp; if !sp > 15 then error "%s: an expression too deep" name; maxsp := max !maxsp !sp; !sp in
  let spill () = for r = 1 to !sp do put r (spill_slot r) done in
  let reload () = for r = 1 to !sp do get (spill_slot r) r done in
  let result () = ins "MOV\tR0, R%d" (push ()) in
  let jump l = Hashtbl.replace depth_at l !sp in
  let epilogue () =
    line (fun f _ _ -> sprintf "\tSUB\t$%d, R26\n" (8 * f));
    ins "MOV\t0(R31), R30";
    line (fun _ m _ -> sprintf "\tADD\t$%d, R31\n" m)
  in
  let record c k = c + (32 * k) in
  (* a line with the offset d in the k-th handler's record *)
  let at k d f = line (fun _ _ c -> "\t" ^ f (record c k + d) ^ "\n") in
  (* a b by a op b in b's register *)
  let bin f = let a = !sp in decr sp; f a !sp in
  let tagged3 o = bin (fun a b -> ins "%s\tR%d, R%d, R%d" o b a b) in
  let op o =
    let a = !sp in
    match o with
    | Add -> bin (fun a b -> ins "ADD\tR%d, R%d, R%d" b a b; ins "SUB\t$1, R%d" b)
    | Sub -> bin (fun a b -> ins "SUB\tR%d, R%d, R%d" b a b; ins "ADD\t$1, R%d" b)
    | Mul -> bin (fun a b -> ins "SUB\t$1, R%d" a; ins "ASR\t$1, R%d" b; ins "MUL\tR%d, R%d, R%d" b a b; ins "ADD\t$1, R%d" b)
    | Div | Mod ->
        bin (fun a b ->
          ins "ASR\t$1, R%d" a; ins "ASR\t$1, R%d" b;
          ins "%s\tR%d, R%d, R%d" (if o = Div then "SDIV" else "REM") b a b;
          ins "LSL\t$1, R%d" b; ins "ADD\t$1, R%d" b)
    | And -> tagged3 "AND"
    | Or -> tagged3 "ORR"
    | Xor -> tagged3 "EOR"; ins "ORR\t$1, R%d" !sp
    | Lsl -> bin (fun a b -> ins "SUB\t$1, R%d" a; ins "ASR\t$1, R%d" b; ins "LSL\tR%d, R%d, R%d" b a b; ins "ORR\t$1, R%d" b)
    | Lsr | Asr -> bin (fun a b -> ins "ASR\t$1, R%d" b; ins "%s\tR%d, R%d, R%d" (if o = Lsr then "LSR" else "ASR") b a b; ins "ORR\t$1, R%d" b)
    | Cmp r ->
        bin (fun a b ->
          ins "CMP\tR%d, R%d" b a;
          ins "MOV\t$3, R%d" b;
          ins "B%s\t2(PC)" (match r with Eq -> "EQ" | Ne -> "NE" | Lt -> "LT" | Le -> "LE" | Gt -> "GT" | Ge -> "GE");
          ins "MOV\t$1, R%d" b)
    | Neg -> ins "NEG\tR%d, R%d" a a; ins "ADD\t$2, R%d" a
    | Lnot -> ins "MVN\tR%d, R%d" a a; ins "ORR\t$1, R%d" a
    | Not -> ins "EOR\t$2, R%d" a
    | IsInt -> ins "AND\t$1, R%d" a; ins "LSL\t$1, R%d" a; ins "ORR\t$1, R%d" a
    | Tag -> ins "MOVBU\t-8(R%d), R%d" a a; ins "LSL\t$1, R%d" a; ins "ORR\t$1, R%d" a
  in
  List.iter (fun i ->
    match i with
    | Label l ->
        (* after a jump, the depth the label was jumped to with *)
        (match Hashtbl.find_opt depth_at l with Some d when !dead -> sp := d | _ -> ());
        dead := false;
        line (fun _ _ _ -> sprintf "L%d:\n" l)
    | Catch k -> dead := false; sp := Hashtbl.find catch_at k; reload (); result ()
    | _ when !dead -> ()
    | Imm v -> ins "MOV\t$%Ld, R%d" v (push ())
    | Addr (s, o) -> ins "MOV\t$%s+%d(SB), R%d" s o (push ())
    | Get i -> get i (push ())
    | Set i -> put !sp i; decr sp
    | GetG g -> ins "MOV\tml_globals+%d(SB), R%d" (8 * g) (push ())
    | SetG g -> ins "MOV\tR%d, ml_globals+%d(SB)" !sp (8 * g); decr sp
    | Field k -> ins "MOV\t%d(R%d), R%d" (8 * k) !sp !sp
    | SetField k -> ins "MOV\tR%d, %d(R%d)" (!sp - 1) (8 * k) !sp; sp := !sp - 2
    | Alloc (tag, n) ->
        (* the collector may run: every value in a slot, the fields read back from them *)
        spill ();
        cargs := max !cargs 2;
        ins "MOV\t$%d, R0" n;
        ins "MOV\t$%d, R16" tag;
        ins "MOV\tR16, 16(R31)";
        ins "MOV\tR26, ml_vsp(SB)";
        ins "BL\tml_alloc(SB)";
        for k = 0 to n - 1 do get (spill_slot (!sp - k)) 16; ins "MOV\tR16, %d(R0)" (8 * k) done;
        sp := !sp - n;
        reload ();
        result ()
    | Op o -> op o
    | Call (t, n, tail) ->
        spill ();
        get (spill_slot !sp) 0;
        for k = 1 to n do get (spill_slot (!sp - k)) k done;
        sp := !sp - n - 1;
        let target = match t with Direct f -> f ^ "(SB)" | Code k -> ins "MOV\t%d(R0), R16" (8 * k); "(R16)" in
        if tail then (epilogue (); ins "B\t%s" target; dead := true) else (ins "BL\t%s" target; reload (); result ())
    | CallC (f, n) ->
        spill ();
        cargs := max !cargs n;
        get (spill_slot !sp) 0;
        for k = 1 to n - 1 do get (spill_slot (!sp - k)) 16; ins "MOV\tR16, %d(R31)" (8 + (8 * k)) done;
        sp := !sp - n;
        ins "MOV\tR26, ml_vsp(SB)";
        ins "BL\t%s(SB)" f;
        reload ();
        result ()
    | Jmp l -> jump l; ins "B\tL%d" l; dead := true
    | Jz l -> let r = !sp in decr sp; jump l; ins "CMP\t$1, R%d" r; ins "BEQ\tL%d" l
    | Jnz l -> let r = !sp in decr sp; jump l; ins "CMP\t$1, R%d" r; ins "BNE\tL%d" l
    | Drop -> decr sp
    | Ret -> ins "MOV\tR%d, R0" !sp; decr sp; epilogue (); ins "RET"; dead := true
    | Raise -> ins "MOV\tR%d, R0" !sp; ins "B\tml_raise(SB)"; dead := true
    | TryEnter (k, handler) ->
        (* the record: SP, R26, the handler's address (BL's link: the
         * B after it), the previous record *)
        spill ();
        Hashtbl.replace catch_at k !sp;
        tries := max !tries (k + 1);
        let set = label () in
        ins "BL\tL%d" set;
        ins "B\tL%d" handler;
        line (fun _ _ _ -> sprintf "L%d:\n" set);
        ins "MOV\tR31, R18";
        at k 0 (sprintf "MOV\tR18, %d(R31)");
        at k 8 (sprintf "MOV\tR26, %d(R31)");
        at k 16 (sprintf "MOV\tR30, %d(R31)");
        ins "MOV\tml_handler(SB), R18";
        at k 24 (sprintf "MOV\tR18, %d(R31)");
        at k 0 (sprintf "MOV\t$%d(R31), R18");
        ins "MOV\tR18, ml_handler(SB)"
    | TryExit k -> at k 24 (sprintf "MOV\t%d(R31), R18"); ins "MOV\tR18, ml_handler(SB)")
    code;
  let f = nslots + !maxsp and c = (8 + (8 * !cargs) + 15) land lnot 15 in
  let m = record c !tries in
  let out fmt = Printf.bprintf text fmt in
  out "\tTEXT\t%s(SB), $-8\n\tSUB\t$%d, R31\n\tMOV\tR30, 0(R31)\n\tADD\t$%d, R26\n" name m (8 * f);
  for i = 0 to nparams do out "\tMOV\tR%d, %d(R26)\n" i (8 * (i - f)) done;
  (* the other slots zeroed: the collector scans them *)
  for i = nparams + 1 to f - 1 do out "\tMOV\tZR, %d(R26)\n" (8 * (i - f)) done;
  List.iter (fun l -> Buffer.add_string text (l f m c)) (List.rev !lines)

(*****************************************************************************)
(* Data: static blocks *)
(*****************************************************************************)

let words sym ws =
  List.iteri (fun i w -> Printf.bprintf data "\tDATA\t%s+%d(SB)/8, $%s\n" sym (8 * i) w) ws;
  Printf.bprintf data "\tGLOBL\t%s(SB), $%d\n" sym (8 * List.length ws)

let header n tag = string_of_int ((n lsl 10) lor tag)
let closure_tag = 247 and string_tag = 252

(* a string: its words, the last byte the number of the others that are
 * padding, as OCaml's *)
let strings = Hashtbl.create 16
let static_string s =
  match Hashtbl.find_opt strings s with
  | Some sym -> sym
  | None ->
      let sym = sprintf "s%d<>" (Hashtbl.length strings) in
      let n = (String.length s / 8) + 1 in
      let b = Bytes.make (8 * n) '\000' in
      Bytes.blit_string s 0 b 0 (String.length s);
      Bytes.set b ((8 * n) - 1) (Char.chr ((8 * n) - 1 - String.length s));
      words sym (header n string_tag :: List.init n (fun i -> Int64.to_string (Bytes.get_int64_le b (8 * i))));
      Hashtbl.replace strings s sym;
      sym

(* the curry functions an arity needs *)
let arities = ref []
let curry n k = sprintf "ml_curry%d_%d<>" n k
let entry n lab = if n = 1 then lab else (if not (List.mem n !arities) then arities := n :: !arities; curry n 0)
let static_closure lab n = let sym = "c" ^ lab in words sym [ header 2 closure_tag; entry n lab ^ "(SB)"; lab ^ "(SB)" ]; sym

(* an exception: a block with its name, compared by address; its value
 * a block [the exception; its arguments], a static one without them *)
let exn_id c = "ml_exn_" ^ c
let exn_const c = "ml_exv_" ^ c

let tagged n = Int64.add (Int64.mul 2L (Int64.of_int n)) 1L

(*****************************************************************************)
(* From the tree to the stack machine *)
(*****************************************************************************)

(* where a name's value is, and, for a function whose code is known,
 * that code and its arity *)
type loc = Slot of int | Env of int | Glob of int | Static of string
type binding = Loc of loc * (string * int) option | Ext of string * int

type fn = { mutable code : ir list; mutable nslots : int; mutable ntries : int }

let cur = ref { code = []; nslots = 1; ntries = 0 }
let emit i = !cur.code <- i :: !cur.code
let slot () = let s = !cur.nslots in !cur.nslots <- s + 1; s
let queue : (unit -> unit) Queue.t = Queue.create ()
let nfuns = ref 0

let fun_label x =
  incr nfuns;
  sprintf "f%d_%s<>" !nfuns (String.map (fun c -> match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> c | _ -> '_') x)

let lookup env x = match List.assoc_opt x env with Some b -> b | None -> error "unbound %s" x

let rec pat_vars = function
  | PAny | PConst _ -> []
  | PVar x -> [ x ]
  | PCon (_, ps) | PTuple ps -> List.concat_map pat_vars ps
  | PAlias (p, x) -> x :: pat_vars p
  | POr (p, _) -> pat_vars p

(* the names free in e, each once, in their order *)
let rec free bound e acc =
  let fr = free bound in
  match e with
  | Const _ -> acc
  | Var (x, _) -> if List.mem x bound || List.mem x acc then acc else acc @ [ x ]
  | Con (_, l) | Tuple l -> List.fold_left (fun acc e -> fr e acc) acc l
  | App (f, l) -> List.fold_left (fun acc e -> fr e acc) acc (f :: l)
  | Fun (xs, b) -> free (xs @ bound) b acc
  | Let (r, bs, b) ->
      let vs = List.concat_map (fun (p, _) -> pat_vars p) bs in
      let acc = List.fold_left (fun acc (_, e) -> free (if r then vs @ bound else bound) e acc) acc bs in
      free (vs @ bound) b acc
  | Match (e, cs) | Try (e, cs) ->
      List.fold_left (fun acc (p, g, b) ->
        let bound = pat_vars p @ bound in
        free bound b (match g with Some g -> free bound g acc | None -> acc)) (fr e acc) cs
  | If (a, b, c) -> fr c (fr b (fr a acc))
  | Seq (a, b) | While (a, b) -> fr b (fr a acc)
  | For (x, a, b, _, body) -> free (x :: bound) body (fr b (fr a acc))

(* the free names a closure must hold: those of the enclosing function *)
let captured env e = List.filter (fun x -> match List.assoc_opt x env with Some (Loc ((Slot _ | Env _), _)) -> true | _ -> false) (free [] e [])

(* a function's names: its closure's fields, then what isn't local *)
let body_env env fvs =
  List.mapi (fun j x -> x, match lookup env x with Loc (_, k) -> Loc (Env j, k) | b -> b) fvs
  @ List.filter (fun (_, b) -> match b with Loc ((Slot _ | Env _), _) -> false | _ -> true) env

let rec refutable = function
  | PAny | PVar _ -> false
  | PAlias (p, _) -> refutable p
  | PTuple ps -> List.exists refutable ps
  | PCon (c, ps) -> let ci = find_con c in ci.nconst + ci.nblock > 1 || ci.kind = KExn || List.exists refutable ps
  | PConst _ | POr _ -> true

(* the tests of p against the value in slot s, each jumping to fail;
 * its names bound to slots *)
let rec test acc s p fail =
  let check l = emit (Get s); List.iter emit l; emit (Jz fail) in
  let fields base ps acc =
    fst (List.fold_left (fun (acc, k) p ->
      (match p with
       | PAny -> acc
       | p -> let s' = slot () in emit (Get s); emit (Field k); emit (Set s'); test acc s' p fail), k + 1) (acc, base) ps)
  in
  match p with
  | PAny -> acc
  | PVar x -> (x, Loc (Slot s, None)) :: acc
  | PAlias (p, x) -> test ((x, Loc (Slot s, None)) :: acc) s p fail
  | PConst (CInt n | CChar n) -> check [ Imm (tagged n); Op (Cmp Eq) ]; acc
  | PConst (CStr str) -> check [ Addr (static_string str, 8); CallC ("ml_equal", 2) ]; acc
  | PTuple ps -> fields 0 ps acc
  | PCon (c, ps) ->
      let ci = find_con c in
      (match ci.kind with
       | KConst n -> if ci.nconst + ci.nblock > 1 then check [ Imm (tagged n); Op (Cmp Eq) ]
       | KBlock t ->
           if ci.nconst > 0 then (emit (Get s); emit (Op IsInt); emit (Jnz fail));
           if ci.nblock > 1 then check [ Op Tag; Imm (tagged t); Op (Cmp Eq) ]
       | KExn -> check [ Field 0; Addr (exn_id c, 8); Op (Cmp Eq) ]);
      fields (if ci.kind = KExn then 1 else 0) ps acc
  | POr (a, b) ->
      let other = label () and ok = label () in
      ignore (test acc s a other);
      emit (Jmp ok);
      emit (Label other);
      ignore (test acc s b fail);
      emit (Label ok);
      acc

let match_failure () = emit (Addr (exn_const "Match_failure", 8)); emit Raise

(* a primitive: an instruction, or a call of the runtime; a comparison
 * of integers inlined, the others the runtime's compare *)
let prim p n ty =
  let int_arg = match repr ty with TCon ("->", [ a; _ ]) -> (match repr a with TCon (("int" | "char" | "bool" | "unit"), []) -> true | _ -> false) | _ -> false in
  let rel r =
    if int_arg then emit (Op (Cmp r))
    else
      match r with
      | Eq -> emit (CallC ("ml_equal", 2))
      | Ne -> emit (CallC ("ml_equal", 2)); emit (Op Not)
      | r ->
          (* compare's result r 0 is 0 r' compare's result *)
          emit (CallC ("ml_compare", 2)); emit (Imm 1L);
          emit (Op (Cmp (match r with Lt -> Gt | Gt -> Lt | Le -> Ge | Ge -> Le | r -> r)))
  in
  let ops = [ "%add", Add; "%sub", Sub; "%mul", Mul; "%div", Div; "%mod", Mod; "%and", And; "%or", Or; "%xor", Xor;
              "%lsl", Lsl; "%lsr", Lsr; "%asr", Asr; "%neg", Neg; "%lnot", Lnot; "%not", Not ] in
  let rels = [ "%eq", Eq; "%neq", Ne; "%lt", Lt; "%le", Le; "%gt", Gt; "%ge", Ge ] in
  match p with
  | _ when List.mem_assoc p ops -> emit (Op (List.assoc p ops))
  | _ when List.mem_assoc p rels -> rel (List.assoc p rels)
  | "%physeq" -> emit (Op (Cmp Eq))
  | "%physneq" -> emit (Op (Cmp Ne))
  | "%ref" -> emit (Alloc (0, 1))
  | "%field0" -> emit (Field 0)
  | "%field1" -> emit (Field 1)
  | "%setfield0" -> emit (SetField 0); emit (Imm 1L)
  | "%raise" -> emit Raise
  | "%identity" -> ()
  | "%ignore" -> emit Drop; emit (Imm 1L)
  | _ when p.[0] = '%' -> error "unknown primitive %s" p
  | _ -> emit (CallC (p, n))

(* e's value pushed *)
let rec value env e =
  match e with
  | Const (CInt n | CChar n) -> emit (Imm (tagged n))
  | Const (CStr s) -> emit (Addr (static_string s, 8))
  | Var (x, _) -> var env x
  | Con (c, args) -> (
      match (find_con c).kind with
      | KConst n -> emit (Imm (tagged n))
      | KBlock t -> List.iter (value env) (List.rev args); emit (Alloc (t, List.length args))
      | KExn when args = [] -> emit (Addr (exn_const c, 8))
      | KExn -> List.iter (value env) (List.rev args); emit (Addr (exn_id c, 8)); emit (Alloc (0, 1 + List.length args)))
  | Tuple es -> List.iter (value env) (List.rev es); emit (Alloc (0, List.length es))
  | App (f, args) -> ignore (app env f args false)
  | Fun (xs, b) -> (match closure env "fun" xs b with `Static (sym, _, _) -> emit (Addr (sym, 8)) | `Pushed _ -> ())
  | Let _ | Match _ | If _ | Seq _ -> control env e false
  | Try (b, cases) ->
      let k = !cur.ntries in
      !cur.ntries <- k + 1;
      let handler = label () and out = label () in
      emit (TryEnter (k, handler));
      value env b;
      emit (TryExit k);
      emit (Jmp out);
      emit (Label handler);
      emit (Catch k);
      let s = slot () in
      emit (Set s);
      (* no clause matches: raised again *)
      match_cases env s cases false (fun () -> emit (Get s); emit Raise);
      emit (Label out)
  | While (c, b) ->
      let top = label () and out = label () in
      emit (Label top); value env c; emit (Jz out); value env b; emit Drop; emit (Jmp top); emit (Label out); emit (Imm 1L)
  | For (x, a, b, up, body) ->
      value env a;
      let i = slot () in
      emit (Set i);
      value env b;
      let lim = slot () in
      emit (Set lim);
      let top = label () and out = label () in
      emit (Label top);
      emit (Get lim); emit (Get i); emit (Op (Cmp (if up then Gt else Lt))); emit (Jnz out);
      value ((x, Loc (Slot i, None)) :: env) body;
      emit Drop;
      emit (Imm 3L); emit (Get i); emit (Op (if up then Add else Sub)); emit (Set i);
      emit (Jmp top);
      emit (Label out);
      emit (Imm 1L)

(* e as a function's last: its value returned, or a call made a jump *)
and tail env e =
  match e with
  | App (f, args) -> if not (app env f args true) then emit Ret
  | Let _ | Match _ | If _ | Seq _ -> control env e true
  | _ -> value env e; emit Ret

and control env e tl =
  let k env e = if tl then tail env e else value env e in
  match e with
  | Seq (a, b) -> value env a; emit Drop; k env b
  | If (c, a, b) ->
      let other = label () in
      value env c;
      emit (Jz other);
      k env a;
      if tl then (emit (Label other); k env b)
      else (let out = label () in emit (Jmp out); emit (Label other); k env b; emit (Label out))
  | Let (r, bs, body) -> k (bind env r bs) body
  | Match (e, cases) -> value env e; let s = slot () in emit (Set s); match_cases env s cases tl match_failure
  | _ -> assert false

(* the clauses in order, each tests then its body; after an irrefutable
 * one, nothing *)
and match_cases env s cases tl on_fail =
  let out = label () in
  let rec go = function
    | [] -> on_fail ()
    | (p, g, body) :: rest ->
        let fail = label () in
        let env = test env s p fail in
        Option.iter (fun g -> value env g; emit (Jz fail)) g;
        if tl then tail env body else (value env body; emit (Jmp out));
        if refutable p || Option.is_some g then (emit (Label fail); go rest)
  in
  go cases;
  if not tl then emit (Label out)

and var env x =
  match lookup env x with
  | Loc (Slot s, _) -> emit (Get s)
  | Loc (Env j, _) -> emit (Get 0); emit (Field (2 + j))
  | Loc (Glob g, _) -> emit (GetG g)
  | Loc (Static sym, _) -> emit (Addr (sym, 8))
  | Ext (_, n) ->
      (* a primitive as a value: the function that applies it *)
      let xs = List.init n (fun i -> sprintf "%%e%d" i) in
      value env (Fun (xs, App (var_ x, List.map var_ xs)))

and var_ x = Var (x, ref (tcon "?"))

(* f args: a primitive, a known function's code called with its
 * arguments, or the closure applied to one at a time; whether it ended
 * in a tail call *)
and app env f args tl =
  let m = List.length args in
  let rest k =
    let n = m - k in
    for i = 1 to n do emit (Call (Code 0, 1, tl && i = n)) done;
    tl && n > 0
  in
  let args_in k =
    let first = List.filteri (fun i _ -> i < k) args and later = List.filteri (fun i _ -> i >= k) args in
    List.iter (value env) (List.rev later);
    List.iter (value env) (List.rev first)
  in
  match f with
  | Var (x, ty) -> (
      match lookup env x with
      | Ext (p, n) when m >= n -> args_in n; prim p n !ty; rest n
      | Loc (_, Some (lab, n)) when m >= n ->
          args_in n;
          var env x;
          emit (Call (Direct lab, n, tl && m = n));
          if m = n then tl else rest n
      | _ -> args_in m; value env f; rest 0)
  | _ -> args_in m; value env f; rest 0

(* let: the values in env, then their names *)
and bind env r bs =
  if r then bind_rec env bs
  else
    List.concat_map (fun (p, e) ->
      match p, e with
      | PVar x, Fun (xs, b) -> (
          match closure env x xs b with
          | `Static (sym, lab, n) -> [ x, Loc (Static sym, Some (lab, n)) ]
          | `Pushed (lab, n) -> let s = slot () in emit (Set s); [ x, Loc (Slot s, Some (lab, n)) ])
      | PAny, _ -> value env e; emit Drop; []
      | _ -> value env e; let s = slot () in emit (Set s); irrefutably s p) bs
    @ env

and irrefutably s p =
  if not (refutable p) then test [] s p 0
  else begin
    let fail = label () and ok = label () in
    let bs = test [] s p fail in
    emit (Jmp ok); emit (Label fail); match_failure (); emit (Label ok);
    bs
  end

(* a function: its code compiled later; its closure static without
 * free variables, else allocated *)
and closure env name xs b =
  let lab = fun_label name and n = List.length xs in
  let fvs = captured env (Fun (xs, b)) in
  let benv = body_env env fvs in
  Queue.add (fun () -> compile_fun lab xs benv b) queue;
  if fvs = [] then `Static (static_closure lab n, lab, n)
  else begin
    alloc_closure env lab n fvs;
    `Pushed (lab, n)
  end

and alloc_closure env lab n fvs =
  List.iter (var env) (List.rev fvs);
  emit (Addr (lab, 0));
  emit (Addr (entry n lab, 0));
  emit (Alloc (closure_tag, 2 + List.length fvs))

(* let rec: static if the functions need nothing but each other; else
 * their closures allocated, then those that name a later one patched *)
and bind_rec env bs =
  let fs = List.map (function PVar x, Fun (xs, b) -> x, xs, b | _ -> error "let rec: only functions") bs in
  let labs = List.map (fun (x, xs, _) -> fun_label x, List.length xs) fs in
  let statics = List.map2 (fun (x, _, _) (lab, n) -> x, Loc (Static ("c" ^ lab), Some (lab, n))) fs labs @ env in
  if List.for_all (fun (_, xs, b) -> captured statics (Fun (xs, b)) = []) fs then begin
    List.iter2 (fun (_, xs, b) (lab, n) ->
      ignore (static_closure lab n);
      Queue.add (fun () -> compile_fun lab xs (body_env statics []) b) queue) fs labs;
    statics
  end
  else begin
    let slots = List.map (fun _ -> slot ()) fs in
    let env = List.map2 (fun (x, _, _) ((lab, n), s) -> x, Loc (Slot s, Some (lab, n))) fs (List.combine labs slots) @ env in
    let names = List.map (fun (x, _, _) -> x) fs in
    let fvss = List.map (fun (_, xs, b) -> captured env (Fun (xs, b))) fs in
    List.iteri (fun i ((_, xs, b), fvs) ->
      let lab, n = List.nth labs i in
      let benv = body_env env fvs in
      Queue.add (fun () -> compile_fun lab xs benv b) queue;
      alloc_closure env lab n fvs;
      emit (Set (List.nth slots i))) (List.combine fs fvss);
    List.iteri (fun i fvs ->
      List.iteri (fun j y ->
        let rec index k = function [] -> None | z :: l -> if z = y then Some k else index (k + 1) l in
        match index 0 names with
        | Some m when m >= i -> emit (Get (List.nth slots m)); emit (Get (List.nth slots i)); emit (SetField (2 + j))
        | _ -> ()) fvs) fvss;
    env
  end

and compile_fun lab xs benv b =
  cur := { code = []; nslots = 1 + List.length xs; ntries = 0 };
  let env = List.rev (List.mapi (fun i x -> x, Loc (Slot (i + 1), None)) xs) @ benv in
  tail env b;
  machine lab (List.length xs) !cur.nslots (List.rev !cur.code)

(* ml_curry<n>_<k>: a closure of arity n given its k+1-th argument; a
 * block [the next one; the closure; the k arguments...], or the call *)
let curry_fun n k =
  cur := { code = []; nslots = 2; ntries = 0 };
  emit (Get 1);
  for i = k downto 1 do emit (Get 0); emit (Field (1 + i)) done;
  emit (Get 0);
  if k > 0 then emit (Field 1);
  if k < n - 1 then (emit (Addr (curry n (k + 1), 0)); emit (Alloc (closure_tag, k + 3)); emit Ret)
  else emit (Call (Code 1, n, true));
  machine (curry n k) 1 !cur.nslots (List.rev !cur.code)

(*****************************************************************************)
(* The program *)
(*****************************************************************************)

(* ml_init: the toplevel, in a handler that prints an uncaught
 * exception; its names globals, the collector's roots *)
let compile (items : (item * int) list) =
  cur := { code = []; nslots = 1; ntries = 1 };
  let handler = label () and nglobals = ref 0 in
  emit (TryEnter (0, handler));
  let rec arity = function TE ("->", [ _; r ]) -> 1 + arity r | _ -> 0 in
  ignore (List.fold_left (fun env (it, l) ->
    try
      match it with
      | IExt (x, t, p) -> (x, Ext (p, arity t)) :: env
      | IExn c ->
          words (exn_id c) [ header 1 0; static_string c ^ "+8(SB)" ];
          if (find_con c).arity = 0 then words (exn_const c) [ header 1 0; exn_id c ^ "+8(SB)" ];
          env
      | ILet (r, bs) ->
          let env' = bind env r bs in
          let added = List.filteri (fun i _ -> i < List.length env' - List.length env) env' in
          List.map (function
            | x, Loc (Slot s, k) -> emit (Get s); emit (SetG !nglobals); incr nglobals; x, Loc (Glob (!nglobals - 1), k)
            | b -> b) added
          @ env
    with Failure m -> error "line %d: %s" l m) [] items);
  emit (TryExit 0);
  emit (Imm 1L);
  emit Ret;
  emit (Label handler);
  emit (Catch 0);
  emit (CallC ("ml_uncaught", 1));
  emit Ret;
  machine "ml_init" 0 !cur.nslots (List.rev !cur.code);
  while not (Queue.is_empty queue) do (Queue.pop queue) () done;
  List.iter (fun n -> for k = 0 to n - 1 do curry_fun n k done) !arities;
  words "ml_nglobals" [ string_of_int !nglobals ];
  Printf.bprintf data "\tGLOBL\tml_globals(SB), $%d\n" (8 * max 1 !nglobals)

(* ml_start, from C: the value stack's base; ml_raise: to the latest
 * handler *)
let start =
  String.concat "\n\t"
    [ "\tTEXT\tml_start(SB), $-8"; "MOV\tR0, R26"; "B\tml_init(SB)";
      "TEXT\tml_raise(SB), $-8"; "MOV\tml_handler(SB), R18"; "MOV\t0(R18), R19"; "MOV\tR19, R31"; "MOV\t8(R18), R26";
      "MOV\t24(R18), R19"; "MOV\tR19, ml_handler(SB)"; "MOV\t16(R18), R19"; "B\t(R19)" ]
  ^ "\n"

(* the prelude: the Pervasives and List functions, as the program
 * would find them in ocaml-light's stdlib *)
let prelude = {|
external raise : exn -> 'a = "%raise"
external ( = ) : 'a -> 'a -> bool = "%eq"
external ( <> ) : 'a -> 'a -> bool = "%neq"
external ( < ) : 'a -> 'a -> bool = "%lt"
external ( > ) : 'a -> 'a -> bool = "%gt"
external ( <= ) : 'a -> 'a -> bool = "%le"
external ( >= ) : 'a -> 'a -> bool = "%ge"
external ( == ) : 'a -> 'a -> bool = "%physeq"
external ( != ) : 'a -> 'a -> bool = "%physneq"
external compare : 'a -> 'a -> int = "ml_compare"
external not : bool -> bool = "%not"
external ( ~- ) : int -> int = "%neg"
external ( + ) : int -> int -> int = "%add"
external ( - ) : int -> int -> int = "%sub"
external ( * ) : int -> int -> int = "%mul"
external ( / ) : int -> int -> int = "%div"
external ( mod ) : int -> int -> int = "%mod"
external ( land ) : int -> int -> int = "%and"
external ( lor ) : int -> int -> int = "%or"
external ( lxor ) : int -> int -> int = "%xor"
external ( lsl ) : int -> int -> int = "%lsl"
external ( lsr ) : int -> int -> int = "%lsr"
external ( asr ) : int -> int -> int = "%asr"
external lnot : int -> int = "%lnot"
external ref : 'a -> 'a ref = "%ref"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"
external fst : 'a * 'b -> 'a = "%field0"
external snd : 'a * 'b -> 'b = "%field1"
external ignore : 'a -> unit = "%ignore"
external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"
external Char.code : char -> int = "%identity"
external Char.chr : int -> char = "%identity"
external ( ^ ) : string -> string -> string = "ml_concat"
external string_of_int : int -> string = "ml_string_of_int"
external print_string : string -> unit = "ml_print_string"
external print_char : char -> unit = "ml_print_char"
external print_newline : unit -> unit = "ml_print_newline"
external exit : int -> 'a = "ml_exit"
external String.length : string -> int = "ml_string_length"
external String.get : string -> int -> char = "ml_string_get"
external String.make : int -> char -> string = "ml_string_make"
external ml_string_sub : string -> int -> int -> string = "ml_string_sub"
type 'a option = None | Some of 'a
exception Match_failure
exception Not_found
exception Failure of string
exception Invalid_argument of string
exception Exit
let max_int = 4611686018427387903
let min_int = - max_int - 1
let failwith s = raise (Failure s)
let invalid_arg s = raise (Invalid_argument s)
let print_int n = print_string (string_of_int n)
let print_endline s = print_string s; print_char '\n'
let incr r = r := !r + 1
let decr r = r := !r - 1
let succ n = n + 1
let pred n = n - 1
let abs n = if n < 0 then - n else n
let min a b = if a <= b then a else b
let max a b = if a >= b then a else b
let String.sub s ofs len =
  if ofs < 0 || len < 0 || ofs > String.length s - len then invalid_arg "String.sub" else ml_string_sub s ofs len
let rec ( @ ) l1 l2 = match l1 with [] -> l2 | x :: l -> x :: (l @ l2)
let List.length l = let rec len n = function [] -> n | _ :: l -> len (n + 1) l in len 0 l
let List.rev l = let rec rev acc = function [] -> acc | x :: l -> rev (x :: acc) l in rev [] l
let List.hd = function [] -> failwith "hd" | x :: _ -> x
let List.tl = function [] -> failwith "tl" | _ :: l -> l
let rec List.nth l n = match l with [] -> failwith "nth" | x :: l -> if n = 0 then x else List.nth l (n - 1)
let rec List.map f = function [] -> [] | x :: l -> let y = f x in y :: List.map f l
let rec List.iter f = function [] -> () | x :: l -> f x; List.iter f l
let rec List.fold_left f acc = function [] -> acc | x :: l -> List.fold_left f (f acc x) l
let rec List.fold_right f l acc = match l with [] -> acc | x :: l -> f x (List.fold_right f l acc)
let rec List.mem x = function [] -> false | y :: l -> x = y || List.mem x l
let rec List.assoc x = function [] -> raise Not_found | (a, b) :: l -> if a = x then b else List.assoc x l
let rec List.exists p = function [] -> false | x :: l -> p x || List.exists p l
let rec List.for_all p = function [] -> true | x :: l -> p x && List.for_all p l
let List.filter p l =
  let rec find acc = function [] -> List.rev acc | x :: l -> if p x then find (x :: acc) l else find acc l in
  find [] l
let rec List.concat = function [] -> [] | l :: r -> l @ List.concat r
|}

let main () =
  let output = ref "" and file = ref "" in
  let rec args = function
    | "-o" :: o :: r -> output := o; args r
    | f :: r -> file := f; args r
    | [] -> ()
  in
  args (List.tl (Array.to_list Sys.argv));
  if !file = "" then (prerr_endline "usage: tiny-ml [-o out.s] file.ml"; exit 2);
  let parse s = toks := lex s; pos := 0; items () in
  try
    let prelude = parse prelude in
    let program = prelude @ parse (In_channel.with_open_bin !file In_channel.input_all) in
    ignore (List.fold_left type_item [] program);
    compile program;
    let asm = start ^ Buffer.contents text ^ Buffer.contents data in
    if !output = "" then print_string asm else Out_channel.with_open_bin !output (fun oc -> output_string oc asm)
  with Failure m -> Printf.eprintf "%s: %s\n" !file m; exit 1

let () = main ()
