(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Lower.mli *)

type rel = Eq | Ne | Lt | Le | Gt | Ge

type op =
  | Add | Sub | Mul | Div | Mod | And | Or | Xor | Lsl | Lsr | Asr
  | Cmp of rel
  | Poly of rel
  | Neg | Not | IsInt | Tag | Size

type target = Direct of string | Code of int

type ir =
  | Int of int
  | Block of string
  | Sym of string
  | Get of int | Set of int
  | GetG of string | SetG of string
  | Field of int
  | SetField of int
  | Index
  | SetIndex
  | Alloc of int * int
  | Op of op
  | Call of target * int list * bool
  | CallC of string * int
  | Label of int | Jmp of int
  | Jz of int | Jnz of int
  | Drop
  | Ret
  | Raise
  | TryEnter of int * int
  | TryExit of int
  | Catch of int

type func = { name : string; nparams : int; nslots : int; code : ir list }

type data =
  | String of string * string
  | Float of string * string
  | Closure of string * string * string
  | Exception of string * string
  | Global of string * string option
  | Roots of string * string list

type unit_ = { funcs : func list; data : data list }

let error fmt = Printf.ksprintf failwith fmt
let closure_tag = 247

let mangle s =
  String.concat ""
    (List.map (function ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.') as c -> String.make 1 c | c -> "$" ^ string_of_int (Char.code c))
       (List.of_seq (String.to_seq s)))

(*****************************************************************************)
(* The unit's state *)
(*****************************************************************************)

(* where a variable's value is; for a function whose code is known,
 * that code and its arity *)
type loc = Slot of int | Env of int | Static of string
type binding = { loc : loc; known : (string * int) option }

type fn = { mutable code : ir list; mutable nslots : int; mutable ntries : int }

let cur = ref { code = []; nslots = 1; ntries = 0 }
let emit i = !cur.code <- i :: !cur.code
let slot () = let s = !cur.nslots in !cur.nslots <- s + 1; s
let labels = ref 0
let label () = incr labels; !labels
let queue : (unit -> unit) Queue.t = Queue.create ()
let funcs = ref []
let data = ref []
let arities = ref []
let file = ref ""

(* this unit's globals whose value is a known function *)
let known_globals : (string, binding) Hashtbl.t = Hashtbl.create 64

let nfuns = ref 0
let fun_label x = incr nfuns; Printf.sprintf "f%d_%s<>" !nfuns (String.map (function ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_') as c -> c | _ -> '_') x)
let curry n k = Printf.sprintf "ml_curry%d_%d<>" n k
let entry n lab = if n = 1 then lab else (if not (List.mem n !arities) then arities := n :: !arities; curry n 0)

let static_closure lab n = let sym = "c" ^ lab and e = entry n lab in data := Closure (sym, e, lab) :: !data; sym

let strings = Hashtbl.create 16
let string_block s =
  match Hashtbl.find_opt strings s with
  | Some sym -> sym
  | None -> let sym = Printf.sprintf "s%d<>" (Hashtbl.length strings) in Hashtbl.replace strings s sym; data := String (sym, s) :: !data; sym

(* a float, boxed: a static block of its bits; its operations the
 * runtime's, which for now fail (floats: phase 7) *)
let float_block f =
  let sym = Printf.sprintf "d%d<>" (Hashtbl.length strings) in
  Hashtbl.replace strings ("\000float" ^ f ^ sym) sym;
  data := Float (sym, f) :: !data;
  sym

let fresh = ref 0
let new_var x : Scope.var = decr fresh; { vname = x; vid = !fresh }

(*****************************************************************************)
(* Free variables *)
(*****************************************************************************)

let rec pvars (p : Scope.pattern) =
  match p with
  | Pvar v -> [ v ]
  | Palias (p, v) -> v :: pvars p
  | Ptuple ps | Pcons (_, ps) -> List.concat_map pvars ps
  | Precord fs -> List.concat_map (fun (_, p) -> pvars p) fs
  | Por (a, _) | Pconstraint (a, _) -> pvars a
  | Pany | Pconst _ | Prange _ -> []

(* the local variables free in e, each once, in their order *)
let rec free bound (e : Scope.expr) acc =
  let fr = free bound in
  let all l acc = List.fold_left (fun acc e -> fr e acc) acc l in
  let cases cs acc =
    List.fold_left (fun acc ((p : Scope.pattern), g, b) ->
      let bound = List.map (fun (v : Scope.var) -> v.vid) (pvars p) @ bound in
      free bound b (match g with Some g -> free bound g acc | None -> acc)) acc cs
  in
  match e.e with
  | Evar (Local v) -> if List.mem v.vid bound || List.mem v.vid acc then acc else acc @ [ v.vid ]
  | Evar _ | Econst _ -> acc
  | Elet (r, bs, b) ->
      let vs = List.concat_map (fun (p, _) -> List.map (fun (v : Scope.var) -> v.vid) (pvars p)) bs in
      let acc = List.fold_left (fun acc (_, e) -> free (if r then vs @ bound else bound) e acc) acc bs in
      free (vs @ bound) b acc
  | Efunction cs -> cases cs acc
  | Eapply (f, args) -> all (f :: args) acc
  | Ematch (e, cs) | Etry (e, cs) -> cases cs (fr e acc)
  | Etuple l | Econs (_, l) | Earray l -> all l acc
  | Erecord (_, fs) -> all (List.map snd fs) acc
  | Ewith (e, _, fs) -> all (e :: List.map snd fs) acc
  | Efield (e, _) | Eassert e -> fr e acc
  | Esetfield (a, _, b) | Eseq (a, b) | Ewhile (a, b) -> fr b (fr a acc)
  | Eif (a, b, c) -> all (a :: b :: Option.to_list c) acc
  | Efor (v, a, b, _, body) -> free (v.vid :: bound) body (fr b (fr a acc))
  | Econstraint (e, _) -> fr e acc

let lookup env (v : Scope.var) = match List.assoc_opt v.vid env with Some b -> b | None -> error "%s: unbound in its function" v.vname

(* the free variables a closure holds: the enclosing function's *)
let captured env e = List.filter (fun id -> match List.assoc_opt id env with Some { loc = Slot _ | Env _; _ } -> true | _ -> false) (free [] e [])

(* a function's variables: its closure's fields, then what isn't local *)
let body_env env fvs =
  List.mapi (fun j id -> id, { (List.assoc id env) with loc = Env j }) fvs
  @ List.filter (fun (_, b) -> match b.loc with Slot _ | Env _ -> false | _ -> true) env

(* fun p q -> e: the parameters, and the body; function | ... | ... a
 * last parameter matched *)
let rec params (e : Scope.expr) =
  match e.e with
  | Efunction [ (p, None, body) ] -> let ps, b = params body in p :: ps, b
  | Efunction cs ->
      let v = new_var "param" in
      [ Scope.Pvar v ], { e with e = Ematch ({ e with e = Evar (Local v) }, cs) }
  | _ -> [], e

(*****************************************************************************)
(* Patterns *)
(*****************************************************************************)

let rec refutable (p : Scope.pattern) =
  match p with
  | Pany | Pvar _ -> false
  | Palias (p, _) | Pconstraint (p, _) -> refutable p
  | Ptuple ps -> List.exists refutable ps
  | Precord fs -> List.exists (fun (_, p) -> refutable p) fs
  | Pcons (c, ps) -> (match c.kind with Exn _ -> true | _ -> c.nconst + c.nblock > 1) || List.exists refutable ps
  | Pconst _ | Prange _ | Por _ -> true

(* the tests of p against the value in slot s, each jumping to fail;
 * its variables bound: to s, or copied to their slot when an
 * or-pattern gave them one *)
let rec test (acc : (int * binding) list) own s (p : Scope.pattern) fail =
  let check l = emit (Get s); List.iter emit l; emit (Jz fail) in
  (* s rel n: n pushed first, the first operand on top *)
  let rel r n = emit (Int n); emit (Get s); emit (Op (Cmp r)); emit (Jz fail) in
  let bind (v : Scope.var) acc =
    match List.assoc_opt v.vid own with
    | Some slot -> emit (Get s); emit (Set slot); (v.vid, { loc = Slot slot; known = None }) :: acc
    | None -> (v.vid, { loc = Slot s; known = None }) :: acc
  in
  let field k p acc =
    match p with
    | Scope.Pany -> acc
    | p -> let s' = slot () in emit (Get s); emit (Field k); emit (Set s'); test acc own s' p fail
  in
  match p with
  | Pany -> acc
  | Pvar v -> bind v acc
  | Palias (p, v) -> test (bind v acc) own s p fail
  | Pconstraint (p, _) -> test acc own s p fail
  | Pconst (Int n) -> rel Eq n; acc
  | Pconst (Char c) -> rel Eq (Char.code c); acc
  | Pconst (String str) -> check [ Block (string_block str); Op (Poly Eq) ]; acc
  | Pconst (Float f) -> check [ Block (float_block f); Op (Poly Eq) ]; acc
  | Prange (a, b) -> rel Ge (Char.code a); rel Le (Char.code b); acc
  | Ptuple ps -> fst (List.fold_left (fun (acc, k) p -> field k p acc, k + 1) (acc, 0) ps)
  | Precord fs -> List.fold_left (fun acc ((l : Scope.label), p) -> field l.pos p acc) acc fs
  | Pcons (c, ps) ->
      (match c.kind with
       | Const n -> if c.nconst + c.nblock > 1 then rel Eq n
       | Block t ->
           if c.nconst > 0 then (emit (Get s); emit (Op IsInt); emit (Jnz fail));
           if c.nblock > 1 then check [ Op Tag; Int t; Op (Cmp Eq) ]
       | Exn g -> check [ Field 0; Block (mangle g.gsym); Op (Cmp Eq) ]);
      let base = match c.kind with Exn _ -> 1 | _ -> 0 in
      fst (List.fold_left (fun (acc, k) p -> field k p acc, k + 1) (acc, base) ps)
  | Por (a, b) ->
      (* the variables in slots of their own, which both sides fill *)
      let own = List.map (fun (v : Scope.var) -> v.vid, match List.assoc_opt v.vid own with Some s -> s | None -> slot ()) (pvars a) @ own in
      let other = label () and ok = label () in
      let acc' = test acc own s a other in
      emit (Jmp ok);
      emit (Label other);
      ignore (test acc own s b fail);
      emit (Label ok);
      acc'

let raise_failure exn line =
  (* Match_failure and Assert_failure: (file, line, column) *)
  emit (Int 0); emit (Int line); emit (Block (string_block !file)); emit (Alloc (0, 3));
  emit (Block ("caml_exn_" ^ exn)); emit (Alloc (0, 2)); emit Raise

(*****************************************************************************)
(* Primitives *)
(*****************************************************************************)

let ops =
  [ "%addint", Add; "%subint", Sub; "%mulint", Mul; "%divint", Div; "%modint", Mod; "%andint", And; "%orint", Or;
    "%xorint", Xor; "%lslint", Lsl; "%lsrint", Lsr; "%asrint", Asr; "%negint", Neg; "%boolnot", Not; "%eq", Cmp Eq;
    "%noteq", Cmp Ne; "%equal", Poly Eq; "%notequal", Poly Ne; "%lessthan", Poly Lt; "%lessequal", Poly Le;
    "%greaterthan", Poly Gt; "%greaterequal", Poly Ge; "%array_length", Size; "%obj_size", Size; "%obj_is_int", IsInt ]

(* the operands are pushed, the first on top *)
let prim p n =
  let incr d = let t = slot () in emit (Set t); emit (Int d); emit (Get t); emit (Field 0); emit (Op Add); emit (Get t); emit (SetField 0); emit (Int 0) in
  match p with
  | _ when List.mem_assoc p ops -> emit (Op (List.assoc p ops))
  | "%identity" -> ()
  | "%ignore" -> emit Drop; emit (Int 0)
  | "%succint" -> emit (Int 1); emit (Op Add)
  | "%predint" -> emit (Int (-1)); emit (Op Add)
  | "%makemutable" -> emit (Alloc (0, 1))
  | "%field0" -> emit (Field 0)
  | "%field1" -> emit (Field 1)
  | "%setfield0" -> emit (SetField 0); emit (Int 0)
  | "%incr" -> incr 1
  | "%decr" -> incr (-1)
  | "%raise" -> emit Raise
  | "%array_safe_get" | "%array_unsafe_get" | "%obj_field" -> emit Index
  | "%array_safe_set" | "%array_unsafe_set" | "%obj_set_field" -> emit SetIndex; emit (Int 0)
  | "%string_length" -> emit (CallC ("ml_string_length", 1))
  | "%string_safe_get" | "%string_unsafe_get" -> emit (CallC ("ml_string_get", 2))
  | "%string_safe_set" | "%string_unsafe_set" -> emit (CallC ("ml_string_set", 3))
  | "%negfloat" | "%absfloat" | "%floatofint" | "%intoffloat" | "%addfloat" | "%subfloat" | "%mulfloat" | "%divfloat" ->
      emit (CallC ("caml_" ^ String.sub p 1 (String.length p - 1), n))
  | _ when p.[0] = '%' -> error "unknown primitive %s" p
  | _ -> emit (CallC (p, n))

(*****************************************************************************)
(* Expressions *)
(*****************************************************************************)

(* an operand: an expression, or what pushes a value already known *)
type operand = E of Scope.expr | F of (unit -> unit)

(* e's value pushed *)
let rec value env (e : Scope.expr) =
  match e.e with
  | Econst (Int n) -> emit (Int n)
  | Econst (Char c) -> emit (Int (Char.code c))
  | Econst (String s) -> emit (Block (string_block s))
  | Econst (Float f) -> emit (Block (float_block f))
  | Evar v -> var env v
  | Econs (c, args) -> (
      match c.kind with
      | Const n -> emit (Int n)
      | Block t -> block env t (List.map (fun e -> E e) args)
      | Exn g -> block env 0 (F (fun () -> emit (Block (mangle g.gsym))) :: List.map (fun e -> E e) args))
  | Etuple es -> block env 0 (List.map (fun e -> E e) es)
  | Earray [] -> emit (Block "caml_atom0")
  | Earray es -> block env 0 (List.map (fun e -> E e) es)
  | Erecord (size, fs) ->
      block env 0
        (List.init size (fun pos ->
          match List.find_opt (fun ((l : Scope.label), _) -> l.pos = pos) fs with
          | Some (_, e) -> E e
          | None -> error "a record without its field %d" pos))
  | Ewith (r, size, fs) ->
      value env r;
      let s = slot () in
      emit (Set s);
      block env 0
        (List.init size (fun pos ->
          match List.find_opt (fun ((l : Scope.label), _) -> l.pos = pos) fs with
          | Some (_, e) -> E e
          | None -> F (fun () -> emit (Get s); emit (Field pos))))
  | Efield (r, l) -> value env r; emit (Field l.pos)
  | Esetfield (r, l, v) -> value env v; value env r; emit (SetField l.pos); emit (Int 0)
  | Eapply (f, args) -> ignore (app env f args false)
  | Efunction _ -> (match closure env "fun" e with `Static (sym, _, _) -> emit (Block sym) | `Pushed _ -> ())
  | Elet _ | Ematch _ | Eif _ | Eseq _ -> control env e false
  | Etry (b, cases) ->
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
      match_cases env s cases false e.loc (fun () -> emit (Get s); emit Raise);
      emit (Label out)
  | Ewhile (c, b) ->
      let top = label () and out = label () in
      emit (Label top); value env c; emit (Jz out); value env b; emit Drop; emit (Jmp top); emit (Label out); emit (Int 0)
  | Efor (v, a, b, dir, body) ->
      value env a;
      let i = slot () in
      emit (Set i);
      value env b;
      let lim = slot () in
      emit (Set lim);
      let top = label () and out = label () in
      emit (Label top);
      emit (Get lim); emit (Get i); emit (Op (Cmp (if dir = Upto then Gt else Lt))); emit (Jnz out);
      value ((v.vid, { loc = Slot i; known = None }) :: env) body;
      emit Drop;
      emit (Int (if dir = Upto then 1 else -1)); emit (Get i); emit (Op Add); emit (Set i);
      emit (Jmp top);
      emit (Label out);
      emit (Int 0)
  | Econstraint (e, _) -> value env e
  | Eassert c ->
      let ok = label () in
      value env c; emit (Jnz ok); raise_failure "Assert_failure" e.loc; emit (Label ok); emit (Int 0)

(* a block of the fields' values, each pushed by its function, the last
 * first; a big one allocated empty then filled, so that the stack
 * machine's depth stays small *)
and block env tag fields =
  let n = List.length fields in
  if n <= 4 then (operands env (List.rev fields); emit (Alloc (tag, n)))
  else begin
    emit (Int n); emit (Int tag); emit (CallC ("obj_block", 2));
    let b = slot () in
    emit (Set b);
    List.iteri (fun i f -> let pos = n - 1 - i in operands env [ f ]; emit (Get b); emit (SetField pos)) (List.rev fields);
    emit (Get b)
  end

(* operands pushed in their order (the last argument first); two or
 * more of them allocating or calling are computed into slots first,
 * in that order, so that the depth is the operands', not their
 * nesting's (boyer's terms: 9 on arm's 8 registers) *)
and operands env ops =
  let complex = function
    | E { e = Econst _ | Evar _ | Econs (_, []); _ } | F _ -> false
    | E _ -> true
  in
  if List.length (List.filter complex ops) < 2 then List.iter (function E e -> value env e | F f -> f ()) ops
  else begin
    let slots =
      List.map (fun o ->
        match o with
        | E e when complex o -> value env e; let s = slot () in emit (Set s); Some s
        | _ -> None) ops
    in
    List.iter2 (fun o s -> match o, s with _, Some s -> emit (Get s) | E e, None -> value env e | F f, None -> f ()) ops slots
  end

(* e as a function's last: its value returned, or a call made a jump *)
and tail env (e : Scope.expr) =
  match e.e with
  | Eapply (f, args) -> if not (app env f args true) then emit Ret
  | Elet _ | Ematch _ | Eif _ | Eseq _ -> control env e true
  | Econstraint (e, _) -> tail env e
  | _ -> value env e; emit Ret

and control env (e : Scope.expr) tl =
  let k env e = if tl then tail env e else value env e in
  match e.e with
  | Eseq (a, b) -> value env a; emit Drop; k env b
  | Eif (c, a, b) ->
      let b = match b with Some b -> b | None -> { e with e = Econs ({ cname = "()"; kind = Const 0; arity = 0; nconst = 1; nblock = 0; ctype = [], [], Scope.unit_t }, []) } in
      let other = label () in
      value env c;
      emit (Jz other);
      k env a;
      if tl then (emit (Label other); k env b)
      else (let out = label () in emit (Jmp out); emit (Label other); k env b; emit (Label out))
  | Elet (r, bs, body) -> k (bind env r bs) body
  | Ematch (scrut, cases) ->
      value env scrut;
      let s = slot () in
      emit (Set s);
      match_cases env s cases tl e.loc (fun () -> raise_failure "Match_failure" e.loc)
  | _ -> assert false

(* the clauses in order, each tests then its body; after an irrefutable
 * one, nothing *)
and match_cases env s cases tl _loc on_fail =
  let out = label () in
  let rec go = function
    | [] -> on_fail ()
    | ((p : Scope.pattern), g, body) :: rest ->
        let fail = label () in
        let env = test env [] s p fail in
        Option.iter (fun g -> value env g; emit (Jz fail)) g;
        if tl then tail env body else (value env body; emit (Jmp out));
        if refutable p || Option.is_some g then (emit (Label fail); go rest)
  in
  go cases;
  if not tl then emit (Label out)

and var env (v : Scope.value) =
  match v with
  | Local x -> (
      match (lookup env x).loc with
      | Slot s -> emit (Get s)
      | Env j -> emit (Get 0); emit (Field (2 + j))
      | Static sym -> emit (Block sym))
  | Global g -> (
      match Hashtbl.find_opt known_globals g.gsym with
      | Some { loc = Static sym; _ } -> emit (Block sym)
      | _ -> emit (GetG (mangle g.gsym)))
  | Prim (p, n, t) ->
      (* a primitive as a value: the function that applies it *)
      let xs = List.init n (fun i -> new_var (Printf.sprintf "prim%d" i)) in
      let mk e : Scope.expr = { e; loc = 0 } in
      let body = mk (Eapply (mk (Evar (Prim (p, n, t))), List.map (fun x -> mk (Evar (Local x))) xs)) in
      value env (List.fold_right (fun x b -> mk (Efunction [ Scope.Pvar x, None, b ])) xs body)

(* f args: a primitive, a known function's code called with its
 * arguments, or the closure applied to one at a time; whether it ended
 * in a tail call *)
and app env (f : Scope.expr) args tl =
  let m = List.length args in
  let first k = List.filteri (fun i _ -> i < k) args and later k = List.filteri (fun i _ -> i >= k) args in
  (* the arguments in slots, the last computed first *)
  let slots es = List.rev (List.map (to_slot env) (List.rev es)) in
  (* the result on the stack applied to the arguments in slots, one at a time *)
  let rest ss =
    let n = List.length ss in
    List.iteri (fun i a -> let r = slot () in emit (Set r); emit (Call (Code 0, [ r; a ], tl && i = n - 1))) ss;
    tl && n > 0
  in
  let known =
    match f.e with
    | Evar (Local x) -> (lookup env x).known
    | Evar (Global g) -> Option.bind (Hashtbl.find_opt known_globals g.gsym) (fun b -> b.known)
    | _ -> None
  in
  match f.e, known, args with
  | Evar (Prim ("%sequand", _, _)), _, [ a; b ] ->
      value env { f with e = Eif (a, b, Some { f with e = Econst (Int 0) }) }; false
  | Evar (Prim ("%sequor", _, _)), _, [ a; b ] ->
      value env { f with e = Eif (a, { f with e = Econst (Int 1) }, Some b) }; false
  | Evar (Prim (p, n, _)), _, _ when m >= n ->
      let ls = slots (later n) in
      operands env (List.map (fun e -> E e) (List.rev (first n)));
      prim p n;
      rest ls
  | Evar _, Some (lab, n), _ when m >= n ->
      let ss = slots args in
      let c = to_slot env f in
      emit (Call (Direct lab, c :: List.filteri (fun i _ -> i < n) ss, tl && m = n));
      if m = n then tl else rest (List.filteri (fun i _ -> i >= n) ss)
  | _, _, a :: _ ->
      let ss = slots args in
      let c = to_slot env f in
      emit (Call (Code 0, [ c; List.hd ss ], tl && m = 1));
      ignore a;
      if m = 1 then tl else rest (List.tl ss)
  | _, _, [] -> value env f; false

(* e's value in a slot: a local already in one is its own *)
and to_slot env (e : Scope.expr) =
  match e.e with
  | Evar (Local x) when (match (lookup env x).loc with Slot _ -> true | _ -> false) -> (match (lookup env x).loc with Slot s -> s | _ -> assert false)
  | _ -> value env e; let s = slot () in emit (Set s); s

(* let: the values in env, then their names *)
and bind env r bs =
  if r then bind_rec env bs
  else
    List.concat_map (fun ((p : Scope.pattern), (e : Scope.expr)) ->
      match p, e.e with
      | Pvar x, Efunction _ -> (
          match closure env x.vname e with
          | `Static (sym, lab, n) -> [ x.vid, { loc = Static sym; known = Some (lab, n) } ]
          | `Pushed (lab, n) -> let s = slot () in emit (Set s); [ x.vid, { loc = Slot s; known = Some (lab, n) } ])
      | Pany, _ -> value env e; emit Drop; []
      | _ -> value env e; let s = slot () in emit (Set s); irrefutably s p) bs
    @ env

and irrefutably s p =
  if not (refutable p) then test [] [] s p 0
  else begin
    let fail = label () and ok = label () in
    let bs = test [] [] s p fail in
    emit (Jmp ok); emit (Label fail); raise_failure "Match_failure" 0; emit (Label ok);
    bs
  end

(* a function: its code compiled later; its closure static without
 * free variables, else allocated *)
and closure env name (e : Scope.expr) =
  let lab = fun_label name in
  let ps, body = params e in
  let n = List.length ps in
  let fvs = captured env e in
  let benv = body_env env fvs in
  Queue.add (fun () -> compile_fun lab ps benv body) queue;
  if fvs = [] then `Static (static_closure lab n, lab, n)
  else begin
    alloc_closure env lab n fvs;
    `Pushed (lab, n)
  end

and alloc_closure env lab n fvs =
  let e = entry n lab in
  block env closure_tag (F (fun () -> emit (Sym e)) :: F (fun () -> emit (Sym lab)) :: List.map (fun id -> F (fun () -> var env (Local { vname = ""; vid = id }))) fvs)

(* let rec: static if the functions need nothing but each other; else
 * their closures allocated, then those that name a later one patched *)
and bind_rec env bs =
  let fs = List.map (function (Scope.Pvar x, (e : Scope.expr)) -> (match e.e with Efunction _ -> x, e | _ -> error "let rec %s: only functions" x.vname) | _ -> error "let rec: a name") bs in
  let labs = List.map (fun ((x : Scope.var), e) -> fun_label x.vname, List.length (fst (params e))) fs in
  let statics = List.map2 (fun ((x : Scope.var), _) (lab, n) -> x.vid, { loc = Static ("c" ^ lab); known = Some (lab, n) }) fs labs @ env in
  if List.for_all (fun (_, e) -> captured statics e = []) fs then begin
    List.iter2 (fun (_, e) (lab, n) ->
      ignore (static_closure lab n);
      let ps, body = params e in
      Queue.add (fun () -> compile_fun lab ps (body_env statics []) body) queue) fs labs;
    statics
  end
  else begin
    let slots = List.map (fun _ -> slot ()) fs in
    let env = List.map2 (fun ((x : Scope.var), _) ((lab, n), s) -> x.vid, { loc = Slot s; known = Some (lab, n) }) fs (List.combine labs slots) @ env in
    let ids = List.map (fun ((x : Scope.var), _) -> x.vid) fs in
    let fvss = List.map (fun (_, e) -> captured env e) fs in
    List.iteri (fun i ((_, e), fvs) ->
      let lab, n = List.nth labs i in
      let ps, body = params e in
      let benv = body_env env fvs in
      Queue.add (fun () -> compile_fun lab ps benv body) queue;
      alloc_closure env lab n fvs;
      emit (Set (List.nth slots i))) (List.combine fs fvss);
    List.iteri (fun i fvs ->
      List.iteri (fun j id ->
        let rec index k = function [] -> None | z :: l -> if z = id then Some k else index (k + 1) l in
        match index 0 ids with
        | Some m when m >= i -> emit (Get (List.nth slots m)); emit (Get (List.nth slots i)); emit (SetField (2 + j))
        | _ -> ()) fvs) fvss;
    env
  end

(* a function's code: its closure in slot 0, its parameters after *)
and compile_fun lab ps benv body =
  cur := { code = []; nslots = 1 + List.length ps; ntries = 0 };
  let env =
    List.fold_left (fun env (i, (p : Scope.pattern)) ->
      match p with
      | Pvar x -> (x.vid, { loc = Slot i; known = None }) :: env
      | p -> irrefutably i p @ env) benv (List.mapi (fun i p -> i + 1, p) ps)
  in
  tail env body;
  funcs := { name = lab; nparams = List.length ps; nslots = !cur.nslots; code = List.rev !cur.code } :: !funcs

(* ml_curry<n>_<k>: a closure of arity n given its k+1-th argument; a
 * block [the next one; the closure; the k arguments...], or the call *)
let curry_fun n k =
  cur := { code = []; nslots = 2; ntries = 0 };
  if k < n - 1 then begin
    emit (Get 1);
    for i = k downto 1 do emit (Get 0); emit (Field (1 + i)) done;
    emit (Get 0);
    if k > 0 then emit (Field 1);
    emit (Sym (curry n (k + 1))); emit (Alloc (closure_tag, k + 3)); emit Ret
  end
  else begin
    let field i = emit (Get 0); emit (Field i); let s = slot () in emit (Set s); s in
    let args = List.init k (fun i -> field (2 + i)) in
    let orig = if k > 0 then field 1 else 0 in
    emit (Call (Code 1, (orig :: args) @ [ 1 ], true))
  end;
  funcs := { name = curry n k; nparams = 1; nslots = !cur.nslots; code = List.rev !cur.code } :: !funcs

(*****************************************************************************)
(* A unit *)
(*****************************************************************************)

let unit_ name (items : Scope.item list) =
  cur := { code = []; nslots = 1; ntries = 0 };
  funcs := []; data := []; arities := []; Hashtbl.reset strings; Hashtbl.reset known_globals;
  file := String.uncapitalize_ascii name ^ ".ml";
  let globals = ref [] in
  List.iter (fun (it : Scope.item) ->
    match it with
    | Ieval e -> value [] e; emit Drop
    | Iexception (g, c) -> let name = string_block c in data := Exception (mangle g.gsym, name) :: !data
    | Iexternal (g, p, n, t) ->
        (* the primitive as a function, a static closure *)
        let sym = mangle g.gsym in
        globals := sym :: !globals;
        var [] (Prim (p, n, t));
        emit (SetG sym);
        data := Global (sym, None) :: !data
    | Ivalue (r, bs, gs) ->
        let env = bind [] r bs in
        List.iter (fun ((v : Scope.var), (g : Scope.global)) ->
          let sym = mangle g.gsym in
          globals := sym :: !globals;
          let b = List.assoc v.vid env in
          (match b.loc with
           | Static s -> data := Global (sym, Some s) :: !data
           | _ -> data := Global (sym, None) :: !data; var env (Local v); emit (SetG sym));
          if b.known <> None then Hashtbl.replace known_globals g.gsym b) gs) items;
  emit (Int 0);
  emit Ret;
  funcs := { name = mangle name ^ ".Init"; nparams = 0; nslots = !cur.nslots; code = List.rev !cur.code } :: !funcs;
  while not (Queue.is_empty queue) do (Queue.pop queue) () done;
  List.iter (fun n -> for k = 0 to n - 1 do curry_fun n k done) !arities;
  data := Roots (mangle name ^ ".Roots", List.rev !globals) :: !data;
  { funcs = List.rev !funcs; data = List.rev !data }

(*****************************************************************************)
(* -dir *)
(*****************************************************************************)

let show_rel = function Eq -> "eq" | Ne -> "ne" | Lt -> "lt" | Le -> "le" | Gt -> "gt" | Ge -> "ge"

let show = function
  | Int n -> Printf.sprintf "int %d" n
  | Block s -> "block " ^ s
  | Sym s -> "sym " ^ s
  | Get i -> Printf.sprintf "get %d" i
  | Set i -> Printf.sprintf "set %d" i
  | GetG g -> "getg " ^ g
  | SetG g -> "setg " ^ g
  | Field k -> Printf.sprintf "field %d" k
  | SetField k -> Printf.sprintf "setfield %d" k
  | Index -> "index"
  | SetIndex -> "setindex"
  | Alloc (t, n) -> Printf.sprintf "alloc %d %d" t n
  | Op o ->
      "op "
      ^ (match o with
         | Add -> "add" | Sub -> "sub" | Mul -> "mul" | Div -> "div" | Mod -> "mod" | And -> "and" | Or -> "or"
         | Xor -> "xor" | Lsl -> "lsl" | Lsr -> "lsr" | Asr -> "asr" | Cmp r -> "cmp " ^ show_rel r
         | Poly r -> "poly " ^ show_rel r | Neg -> "neg" | Not -> "not" | IsInt -> "isint" | Tag -> "tag" | Size -> "size")
  | Call (t, ss, tl) ->
      Printf.sprintf "call%s %s %s" (if tl then " tail" else "") (match t with Direct f -> f | Code k -> Printf.sprintf "field%d" k)
        (String.concat " " (List.map string_of_int ss))
  | CallC (f, n) -> Printf.sprintf "callc %s %d" f n
  | Label l -> Printf.sprintf "L%d:" l
  | Jmp l -> Printf.sprintf "jmp L%d" l
  | Jz l -> Printf.sprintf "jz L%d" l
  | Jnz l -> Printf.sprintf "jnz L%d" l
  | Drop -> "drop"
  | Ret -> "ret"
  | Raise -> "raise"
  | TryEnter (k, l) -> Printf.sprintf "try %d L%d" k l
  | TryExit k -> Printf.sprintf "untry %d" k
  | Catch k -> Printf.sprintf "catch %d" k
