(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Typing.mli *)

exception Error of int * string

(* a variable is a cell: unbound (its number, its level), or linked to
 * what it became; a constructor is its declaration, Scope's *)
type t = Var of tv ref | Con of Scope.tdecl * t list | Arrow of t * t | Tuple of t list
and tv = Unbound of int * int | Link of t

let generic = max_int
let level = ref 1
let counter = ref 0
let newvar () = incr counter; Var (ref (Unbound (!counter, !level)))
let loc = ref 0
let error fmt = Printf.ksprintf (fun m -> raise (Error (!loc, m))) fmt

let of_scope_const = function Scope.Tconstr (d, []) -> Con (d, []) | _ -> assert false
let int_t = of_scope_const Scope.int_t and char_t = of_scope_const Scope.char_t
let string_t = of_scope_const Scope.string_t and float_t = of_scope_const Scope.float_t
let bool_t = of_scope_const Scope.bool_t and unit_t = of_scope_const Scope.unit_t and exn_t = of_scope_const Scope.exn_t

let rec repr t = match t with Var { contents = Link t } -> repr t | t -> t

(* a declared type, its variables named: each name's type in vars,
 * a fresh one the first time *)
let rec of_ty vars (ty : Scope.ty) =
  match ty with
  | Tvar v -> (match List.assoc_opt v !vars with Some t -> t | None -> let t = newvar () in vars := (v, t) :: !vars; t)
  | Tarrow (a, b) -> Arrow (of_ty vars a, of_ty vars b)
  | Ttuple ts -> Tuple (List.map (of_ty vars) ts)
  | Tconstr (d, args) -> Con (d, List.map (of_ty vars) args)

let instance ty = of_ty (ref []) ty

(* an abbreviation's body, its parameters the arguments *)
let expand (d : Scope.tdecl) args =
  match d.tabbrev with
  | Some body when List.length d.tparams = List.length args -> Some (of_ty (ref (List.combine d.tparams args)) body)
  | _ -> None

(*****************************************************************************)
(* Printing *)
(*****************************************************************************)

let current = ref ""

(* the unit's own types, and Pervasives's, by their names *)
let path (d : Scope.tdecl) =
  let strip p s = if String.starts_with ~prefix:(p ^ ".") s then String.sub s (String.length p + 1) (String.length s - String.length p - 1) else s in
  strip "Pervasives" (strip !current d.tpath)

let show ?(names = ref []) t =
  let name r =
    match List.assq_opt r !names with
    | Some n -> n
    | None ->
        let weak = match !r with Unbound (_, l) -> l <> generic | Link _ -> false in
        let n = List.length !names in
        let s = (if weak then "'_" else "'") ^ (if n < 26 then String.make 1 (Char.chr (97 + n)) else Printf.sprintf "a%d" n) in
        names := (r, s) :: !names;
        s
  in
  let rec go prec t =
    let paren p s = if prec > p then "(" ^ s ^ ")" else s in
    match repr t with
    | Var r -> name r
    | Arrow (a, b) -> let a = go 1 a in paren 0 (a ^ " -> " ^ go 0 b)
    | Tuple ts -> paren 1 (String.concat " * " (List.map (go 2) ts))
    | Con (d, []) -> path d
    | Con (d, [ a ]) -> go 2 a ^ " " ^ path d
    | Con (d, args) -> "(" ^ String.concat ", " (List.map (go 0) args) ^ ") " ^ path d
  in
  go 0 t

(*****************************************************************************)
(* Unification *)
(*****************************************************************************)

(* r's variable in t is a cycle; a variable met in t at a deeper level
 * takes r's, so that it is generalized only where both are *)
let rec occurs r lv t =
  match repr t with
  | Var r' when r == r' -> error "a type would be recursive"
  | Var ({ contents = Unbound (n, l) } as r') -> if l > lv then r' := Unbound (n, lv)
  | Var _ -> ()
  | Con (_, ts) | Tuple ts -> List.iter (occurs r lv) ts
  | Arrow (a, b) -> occurs r lv a; occurs r lv b

exception Clash

let rec unify_ a b =
  let a = repr a and b = repr b in
  if a != b then
    match a, b with
    | Var ({ contents = Unbound (_, l) } as r), t | t, Var ({ contents = Unbound (_, l) } as r) -> occurs r l t; r := Link t
    | Arrow (a1, r1), Arrow (a2, r2) -> unify_ a1 a2; unify_ r1 r2
    | Tuple l1, Tuple l2 when List.length l1 = List.length l2 -> List.iter2 unify_ l1 l2
    | Con (d1, l1), Con (d2, l2) when d1.tpath = d2.tpath && List.length l1 = List.length l2 -> List.iter2 unify_ l1 l2
    | Con (d, l), _ when expand d l <> None -> unify_ (Option.get (expand d l)) b
    | _, Con (d, l) when expand d l <> None -> unify_ a (Option.get (expand d l))
    | _ -> raise Clash

let unify ?(what = "this expression") a b =
  try unify_ a b
  with Clash ->
    let names = ref [] in
    let sa = show ~names a in
    error "%s has type %s but is used with type %s" what sa (show ~names b)

(* an arrow, through the abbreviations; a variable made one *)
let rec arrow t =
  match repr t with
  | Arrow (a, r) -> a, r
  | Con (d, l) when expand d l <> None -> arrow (Option.get (expand d l))
  | t -> let a = newvar () and r = newvar () in unify ~what:"this function" t (Arrow (a, r)); a, r

(*****************************************************************************)
(* Generalization *)
(*****************************************************************************)

let rec generalize t =
  match repr t with
  | Var ({ contents = Unbound (n, l) } as r) when l > !level -> r := Unbound (n, generic)
  | Var _ -> ()
  | Con (_, ts) | Tuple ts -> List.iter generalize ts
  | Arrow (a, b) -> generalize a; generalize b

let instantiate t =
  let copies = ref [] in
  let rec go t =
    match repr t with
    | Var ({ contents = Unbound (_, l) } as r) when l = generic -> (
        match List.assq_opt r !copies with Some v -> v | None -> let v = newvar () in copies := (r, v) :: !copies; v)
    | Var _ as t -> t
    | Con (d, ts) -> Con (d, List.map go ts)
    | Tuple ts -> Tuple (List.map go ts)
    | Arrow (a, b) -> Arrow (go a, go b)
  in
  go t

(* the value restriction: only a value is generalized *)
let rec nonexpansive (e : Scope.expr) =
  match e.e with
  | Evar _ | Econst _ | Efunction _ -> true
  | Econs (_, l) | Etuple l -> List.for_all nonexpansive l
  | Erecord (_, fs) -> List.for_all (fun ((l : Scope.label), e) -> (not l.mut) && nonexpansive e) fs
  | Earray [] -> true
  | Elet (_, bs, b) -> List.for_all (fun (_, e) -> nonexpansive e) bs && nonexpansive b
  | _ -> false

(*****************************************************************************)
(* Formats *)
(*****************************************************************************)

(* Printf's format: ('a, 'b, 'c) format, 'a the conversions' types
 * ending in 'c: %d an int, %s a string, %a a printer of 'b and its
 * argument, %t a function of 'b *)
let format s =
  let b = newvar () and c = newvar () in
  let n = String.length s in
  let rec go i =
    if i >= n then c
    else if s.[i] <> '%' then go (i + 1)
    else begin
      let j = ref (i + 1) in
      while !j < n && String.contains "-+ #0123456789.*l" s.[!j] do incr j done;
      if !j >= n then error "the format %S ends in a %%" s;
      let rest = go (!j + 1) in
      match s.[!j] with
      | '%' | '!' -> rest
      | 'd' | 'i' | 'u' | 'x' | 'X' | 'o' | 'n' | 'N' -> Arrow (int_t, rest)
      | 'c' -> Arrow (char_t, rest)
      | 's' | 'S' -> Arrow (string_t, rest)
      | 'f' | 'e' | 'E' | 'g' | 'G' | 'F' -> Arrow (float_t, rest)
      | 'b' | 'B' -> Arrow (bool_t, rest)
      | 'a' -> let x = newvar () in Arrow (Arrow (b, Arrow (x, c)), Arrow (x, rest))
      | 't' -> Arrow (Arrow (b, c), rest)
      | ch -> error "the format %S: %%%c" s ch
    end
  in
  Con (Scope.format_d, [ go 0; b; c ])

let is_format t = match repr t with Con (d, _) -> d.tpath = Scope.format_d.tpath | _ -> false

(*****************************************************************************)
(* Patterns and expressions *)
(*****************************************************************************)

(* the current unit's globals: their types, by symbol *)
let globals : (string, t) Hashtbl.t = Hashtbl.create 64

(* a constructor's or a label's type, its declaration's parameters
 * fresh (the same for all a record's labels, by vars) *)
let cons_type (c : Scope.cons) =
  let params, args, res = c.ctype in
  let vars = ref (List.map (fun p -> p, newvar ()) params) in
  List.map (of_ty vars) args, of_ty vars res

let label_types vars (l : Scope.label) =
  let params, field, res = l.ltype in
  if !vars = [] then vars := List.map (fun p -> p, newvar ()) params;
  of_ty vars field, of_ty vars res

let const_type = function Ast.Int _ -> int_t | Char _ -> char_t | String _ -> string_t | Float _ -> float_t

(* a pattern's type, and its variables' *)
let rec pattern (p : Scope.pattern) : t * (int * t) list =
  match p with
  | Pany -> newvar (), []
  | Pvar v -> let t = newvar () in t, [ v.vid, t ]
  | Palias (p, v) -> let t, bs = pattern p in t, (v.vid, t) :: bs
  | Pconst c -> const_type c, []
  | Prange _ -> char_t, []
  | Ptuple ps -> let l = List.map pattern ps in Tuple (List.map fst l), List.concat_map snd l
  | Pcons (c, ps) ->
      let args, res = cons_type c in
      res, List.concat (List.map2 (fun p t -> let pt, bs = pattern p in unify ~what:"this pattern" pt t; bs) ps args)
  | Precord fs ->
      let vars = ref [] in
      let res = ref None in
      let bs =
        List.concat_map (fun (l, p) ->
          let field, r = label_types vars l in
          (match !res with Some r' -> unify ~what:"this record" r' r | None -> res := Some r);
          let pt, bs = pattern p in
          unify ~what:"this field" pt field;
          bs) fs
      in
      Option.get !res, bs
  | Pconstraint (p, ty) -> let t, bs = pattern p in unify ~what:"this pattern" t (instance ty); t, bs
  | Por (a, b) ->
      let t, ba = pattern a and u, bb = pattern b in
      unify ~what:"this pattern" t u;
      List.iter (fun (id, t) -> match List.assoc_opt id ba with Some t' -> unify ~what:"this variable" t t' | None -> ()) bb;
      t, ba

let rec infer env (e : Scope.expr) : t =
  let saved = !loc in
  loc := e.loc;
  let t = infer_ env e in
  loc := saved;
  t

and infer_ env (e : Scope.expr) =
  match e.e with
  | Econst c -> const_type c
  | Evar (Local v) -> (match List.assoc_opt v.vid env with Some t -> instantiate t | None -> error "%s: no type" v.vname)
  | Evar (Global g) -> (
      match Hashtbl.find_opt globals g.gsym, g.gtype with
      | Some t, _ -> instantiate t
      | None, Some ty -> instance ty
      | None, None -> newvar ())
  | Evar (Prim (_, _, ty)) -> instance ty
  | Elet (false, bs, body) -> infer (let_ env bs) body
  | Elet (true, bs, body) -> infer (letrec env bs) body
  | Efunction cs ->
      let a = newvar () and r = newvar () in
      cases env a r cs;
      Arrow (a, r)
  | Eapply (f, args) ->
      List.fold_left (fun tf (arg : Scope.expr) ->
        let a, r = arrow tf in
        (match arg.e with
         | Econst (String s) when is_format a -> loc := arg.loc; unify a (format s)
         | _ -> unify (infer env arg) a);
        loc := e.loc;
        r) (infer env f) args
  | Ematch (s, cs) -> let r = newvar () in cases env (infer env s) r cs; r
  | Etry (b, cs) -> let r = infer env b in cases env exn_t r cs; r
  | Etuple es -> Tuple (List.map (infer env) es)
  | Econs (c, args) ->
      let targs, res = cons_type c in
      List.iter2 (fun a t -> unify (infer env a) t) args targs;
      res
  | Erecord (_, fs) -> record env (newvar ()) fs
  | Ewith (r, _, fs) -> let t = infer env r in record env t fs
  | Efield (r, l) -> let field, res = label_types (ref []) l in unify (infer env r) res; field
  | Esetfield (r, l, v) ->
      let field, res = label_types (ref []) l in
      unify (infer env r) res;
      unify (infer env v) field;
      unit_t
  | Earray es -> let a = newvar () in List.iter (fun e -> unify (infer env e) a) es; Con (Scope.array_d, [ a ])
  | Eif (c, a, b) ->
      unify ~what:"this condition" (infer env c) bool_t;
      let t = infer env a in
      (match b with Some b -> unify (infer env b) t | None -> unify t unit_t);
      t
  | Eseq (a, b) -> ignore (infer env a); infer env b
  | Ewhile (c, b) -> unify (infer env c) bool_t; ignore (infer env b); unit_t
  | Efor (v, a, b, _, body) ->
      unify (infer env a) int_t;
      unify (infer env b) int_t;
      ignore (infer ((v.vid, int_t) :: env) body);
      unit_t
  | Econstraint ({ e = Econst (String s); _ }, ty) when is_format (instance ty) -> let t = instance ty in unify t (format s); t
  | Econstraint (e, ty) -> let t = instance ty in unify (infer env e) t; t
  | Eassert { e = Econs ({ cname = "false"; _ }, []); _ } -> newvar ()
  | Eassert c -> unify (infer env c) bool_t; unit_t

(* a record's fields: their labels' types, one instance of the record's
 * parameters *)
and record env t fs =
  let vars = ref [] in
  List.iter (fun (l, e) ->
    let field, res = label_types vars l in
    unify ~what:"this record" t res;
    unify (infer env e) field) fs;
  t

and cases env a r cs =
  List.iter (fun (p, g, body) ->
    let pt, bs = pattern p in
    unify ~what:"this pattern" pt a;
    let env = bs @ env in
    Option.iter (fun g -> unify (infer env g) bool_t) g;
    unify (infer env body) r) cs

(* let: each value at a deeper level, generalized if it is a value; else
 * its variables lowered to the let's level *)
and let_ env bs =
  List.concat_map (fun (p, e) ->
    incr level;
    let t = infer env e in
    let pt, vs = pattern p in
    unify ~what:"this pattern" pt t;
    decr level;
    if nonexpansive e then List.iter (fun (_, t) -> generalize t) vs else List.iter (fun (_, t) -> unify (newvar ()) t) vs;
    vs) bs
  @ env

and letrec env bs =
  incr level;
  let vs = List.map (function Scope.Pvar v, _ -> v.vid, newvar () | _ -> error "let rec: a name expected") bs in
  let env' = vs @ env in
  List.iter2 (fun (_, t) (_, e) -> unify (infer env' e) t) vs bs;
  decr level;
  List.iter (fun (_, t) -> generalize t) vs;
  vs @ env

(*****************************************************************************)
(* A unit *)
(*****************************************************************************)

(* declared an instance of inferred: its variables rigid, constructors
 * of their own *)
let instance_of declared inferred =
  let rigid = ref [] in
  let rec go (ty : Scope.ty) =
    match ty with
    | Tvar v -> (
        match List.assoc_opt v !rigid with
        | Some t -> t
        | None -> let t = Con ({ tpath = "'" ^ v; tparams = []; tabbrev = None }, []) in rigid := (v, t) :: !rigid; t)
    | Tarrow (a, b) -> Arrow (go a, go b)
    | Ttuple ts -> Tuple (List.map go ts)
    | Tconstr (d, args) -> Con ((match Scope.own_type d.tpath with Some d -> d | None -> d), List.map go args)
  in
  let d = go declared in
  try unify_ (instantiate inferred) d; true with Clash | Error _ -> false

let rec generalize_all t =
  match repr t with
  | Var ({ contents = Unbound (n, _) } as r) -> r := Unbound (n, generic)
  | Var _ -> ()
  | Con (_, ts) | Tuple ts -> List.iter generalize_all ts
  | Arrow (a, b) -> generalize_all a; generalize_all b

let unit_ name (items : Scope.item list) =
  Hashtbl.reset globals;
  current := name;
  level := 1;
  let shown = ref [] in
  List.iter (fun (it : Scope.item) ->
    match it with
    | Ieval e -> ignore (infer [] e)
    | Iexception _ -> ()
    | Iexternal (g, p, _, ty) ->
        let t = instance ty in
        generalize_all t;
        Hashtbl.replace globals g.gsym t;
        shown := (g.gname, g.gsym, Printf.sprintf " = %S" p) :: !shown
    | Ivalue (r, bs, gs) ->
        let env = if r then letrec [] bs else let_ [] bs in
        List.iter (fun ((v : Scope.var), (g : Scope.global)) ->
          let t = List.assoc v.vid env in
          Hashtbl.replace globals g.gsym t;
          shown := (v.vname, g.gsym, "") :: !shown) gs) items;
  (* the .mli's values against the inferred *)
  (match Scope.interface () with
   | None -> ()
   | Some decls ->
       List.iter (fun (x, declared) ->
         match Hashtbl.find_opt globals (Scope.symbol [ name ] x) with
         | None -> ()
         | Some inferred ->
             if not (instance_of declared inferred) then
               raise (Error (0, Printf.sprintf "the value %s: its interface's type isn't an instance of %s" x (show inferred)))) decls);
  List.rev_map (fun (x, sym, prim) -> x, show (Hashtbl.find globals sym) ^ prim) !shown
