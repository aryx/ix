(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The tree of ocaml-light's ML, as the parser builds it: the subset
 * mini-ml compiles (plan_ml.md, "The subset, counted"), names still
 * names. Scope then resolves them.
 *
 * A multi-argument function is what the parser makes of it, as
 * ocaml-light's: fun x y -> e is a function of x whose body is a
 * function of y; the arities are found later. The sugar is gone: e.(i)
 * is Array.get e i, s.[i] String.get s i, [a; b] a :: b :: [], and
 * x :: l the constructor "::" of the pair.
 *
 * Each node has its line (the file is the unit's). *)

type loc = int

(* M.N.x is [ "M"; "N"; "x" ] *)
type longid = string list

type constant = Int of int | Char of char | String of string | Float of string

type rec_flag = Nonrec | Rec
type dir = Upto | Downto

type ty =
  | Tvar of string
  | Tarrow of ty * ty
  | Ttuple of ty list
  | Tconstr of longid * ty list

(* a constructor's arguments are one pattern, a tuple for several, as
 * the parser can't tell C (a, b) from C p; Scope splits them *)
type pattern = { p : pat; ploc : loc }

and pat =
  | Pany
  | Pvar of string
  | Palias of pattern * string
  | Pconst of constant
  | Prange of char * char
  | Ptuple of pattern list
  | Pconstruct of longid * pattern option
  | Precord of (longid * pattern) list
  | Por of pattern * pattern
  | Pconstraint of pattern * ty

type expr = { e : exp; eloc : loc }

and exp =
  | Eident of longid
  | Econst of constant
  | Elet of rec_flag * binding list * expr
  | Efunction of case list
  | Eapply of expr * expr list
  | Ematch of expr * case list
  | Etry of expr * case list
  | Etuple of expr list
  | Econstruct of longid * expr option
  | Erecord of (longid * expr) list
  | Ewith of expr * (longid * expr) list    (* { e with l = v } *)
  | Efield of expr * longid
  | Esetfield of expr * longid * expr
  | Earray of expr list
  | Eif of expr * expr * expr option
  | Eseq of expr * expr
  | Ewhile of expr * expr
  | Efor of string * expr * expr * dir * expr
  | Econstraint of expr * ty
  | Eassert of expr

and binding = pattern * expr

(* a clause: the pattern, its guard, its body *)
and case = pattern * expr option * expr

type type_decl = { tname : string; tparams : string list; tkind : tkind; tmanifest : ty option; tloc : loc }

and tkind =
  | Abstract
  | Variant of (string * ty list) list
  | Record of (string * bool * ty) list     (* a label, mutable, its type *)

type structure = item list
and item = { i : it; iloc : loc }

and it =
  | Ieval of expr
  | Ivalue of rec_flag * binding list
  | Iexternal of string * ty * string list
  | Itype of type_decl list
  | Iexception of string * ty list
  | Imodule of string * module_expr
  | Iopen of longid

and module_expr = Mident of longid | Mstruct of structure | Mconstraint of module_expr * module_type
and module_type = MTident of longid | MTsig of signature
and signature = sig_item list
and sig_item = { s : sg; sloc : loc }

and sg =
  | Sval of string * ty
  | Sexternal of string * ty * string list
  | Stype of type_decl list
  | Sexception of string * ty list
  | Smodule of string * module_type
  | Sopen of longid

(*****************************************************************************)
(* -dast: the tree as S-expressions *)
(*****************************************************************************)

let name l = String.concat "." l
let list f l = String.concat " " (List.map f l)

let const = function
  | Int n -> string_of_int n
  | Char c -> Printf.sprintf "%C" c
  | String s -> Printf.sprintf "%S" s
  | Float f -> f

let rec show_ty = function
  | Tvar v -> "'" ^ v
  | Tarrow (a, b) -> Printf.sprintf "(-> %s %s)" (show_ty a) (show_ty b)
  | Ttuple ts -> Printf.sprintf "(* %s)" (list show_ty ts)
  | Tconstr (c, []) -> name c
  | Tconstr (c, ts) -> Printf.sprintf "(%s %s)" (name c) (list show_ty ts)

let rec show_pat (p : pattern) =
  match p.p with
  | Pany -> "_"
  | Pvar x -> x
  | Palias (p, x) -> Printf.sprintf "(as %s %s)" (show_pat p) x
  | Pconst c -> const c
  | Prange (a, b) -> Printf.sprintf "(.. %C %C)" a b
  | Ptuple ps -> Printf.sprintf "(, %s)" (list show_pat ps)
  | Pconstruct (c, None) -> name c
  | Pconstruct (c, Some p) -> Printf.sprintf "(%s %s)" (name c) (show_pat p)
  | Precord fs -> Printf.sprintf "{%s}" (list (fun (l, p) -> Printf.sprintf "(%s %s)" (name l) (show_pat p)) fs)
  | Por (a, b) -> Printf.sprintf "(| %s %s)" (show_pat a) (show_pat b)
  | Pconstraint (p, t) -> Printf.sprintf "(: %s %s)" (show_pat p) (show_ty t)

let rec show (e : expr) =
  let fields fs = list (fun (l, e) -> Printf.sprintf "(%s %s)" (name l) (show e)) fs in
  match e.e with
  | Eident x -> name x
  | Econst c -> const c
  | Elet (r, bs, b) -> Printf.sprintf "(let%s (%s) %s)" (if r = Rec then "rec" else "") (bindings bs) (show b)
  | Efunction cs -> Printf.sprintf "(function %s)" (cases cs)
  | Eapply (f, args) -> Printf.sprintf "(%s %s)" (show f) (list show args)
  | Ematch (e, cs) -> Printf.sprintf "(match %s %s)" (show e) (cases cs)
  | Etry (e, cs) -> Printf.sprintf "(try %s %s)" (show e) (cases cs)
  | Etuple es -> Printf.sprintf "(, %s)" (list show es)
  | Econstruct (c, None) -> name c
  | Econstruct (c, Some e) -> Printf.sprintf "(%s %s)" (name c) (show e)
  | Erecord fs -> Printf.sprintf "{%s}" (fields fs)
  | Ewith (e, fs) -> Printf.sprintf "{%s with %s}" (show e) (fields fs)
  | Efield (e, l) -> Printf.sprintf "(. %s %s)" (show e) (name l)
  | Esetfield (e, l, v) -> Printf.sprintf "(<- %s %s %s)" (show e) (name l) (show v)
  | Earray es -> Printf.sprintf "[|%s|]" (list show es)
  | Eif (c, a, None) -> Printf.sprintf "(if %s %s)" (show c) (show a)
  | Eif (c, a, Some b) -> Printf.sprintf "(if %s %s %s)" (show c) (show a) (show b)
  | Eseq (a, b) -> Printf.sprintf "(seq %s %s)" (show a) (show b)
  | Ewhile (c, b) -> Printf.sprintf "(while %s %s)" (show c) (show b)
  | Efor (x, a, b, d, body) -> Printf.sprintf "(for %s %s %s %s %s)" x (show a) (if d = Upto then "to" else "downto") (show b) (show body)
  | Econstraint (e, t) -> Printf.sprintf "(: %s %s)" (show e) (show_ty t)
  | Eassert e -> Printf.sprintf "(assert %s)" (show e)

and bindings bs = list (fun (p, e) -> Printf.sprintf "(%s %s)" (show_pat p) (show e)) bs

and cases cs =
  list (fun (p, g, e) ->
    match g with
    | None -> Printf.sprintf "(%s %s)" (show_pat p) (show e)
    | Some g -> Printf.sprintf "(%s when %s %s)" (show_pat p) (show g) (show e)) cs

let show_decl d =
  let kind =
    match d.tkind with
    | Abstract -> ""
    | Variant cs -> " " ^ list (fun (c, ts) -> if ts = [] then c else Printf.sprintf "(%s %s)" c (list show_ty ts)) cs
    | Record ls -> " {" ^ list (fun (l, m, t) -> Printf.sprintf "(%s%s %s)" (if m then "mutable " else "") l (show_ty t)) ls ^ "}"
  in
  Printf.sprintf "(type %s(%s)%s%s)" d.tname (list (fun v -> "'" ^ v) d.tparams)
    (match d.tmanifest with Some t -> " = " ^ show_ty t | None -> "") kind

let rec show_item (it : item) =
  match it.i with
  | Ieval e -> Printf.sprintf "%d: %s" it.iloc (show e)
  | Ivalue (r, bs) -> Printf.sprintf "%d: (let%s %s)" it.iloc (if r = Rec then "rec" else "") (bindings bs)
  | Iexternal (x, t, ps) -> Printf.sprintf "%d: (external %s %s %s)" it.iloc x (show_ty t) (list (Printf.sprintf "%S") ps)
  | Itype ds -> Printf.sprintf "%d: %s" it.iloc (list show_decl ds)
  | Iexception (c, ts) -> Printf.sprintf "%d: (exception %s %s)" it.iloc c (list show_ty ts)
  | Imodule (m, me) -> Printf.sprintf "%d: (module %s %s)" it.iloc m (show_mod me)
  | Iopen m -> Printf.sprintf "%d: (open %s)" it.iloc (name m)

and show_mod = function
  | Mident m -> name m
  | Mstruct items -> "(struct\n" ^ String.concat "\n" (List.map show_item items) ^ ")"
  | Mconstraint (m, t) -> Printf.sprintf "(: %s %s)" (show_mod m) (show_mty t)

and show_mty = function MTident m -> name m | MTsig s -> "(sig\n" ^ String.concat "\n" (List.map show_sig s) ^ ")"

and show_sig (s : sig_item) =
  match s.s with
  | Sval (x, t) -> Printf.sprintf "%d: (val %s %s)" s.sloc x (show_ty t)
  | Sexternal (x, t, ps) -> Printf.sprintf "%d: (external %s %s %s)" s.sloc x (show_ty t) (list (Printf.sprintf "%S") ps)
  | Stype ds -> Printf.sprintf "%d: %s" s.sloc (list show_decl ds)
  | Sexception (c, ts) -> Printf.sprintf "%d: (exception %s %s)" s.sloc c (list show_ty ts)
  | Smodule (m, t) -> Printf.sprintf "%d: (module %s %s)" s.sloc m (show_mty t)
  | Sopen m -> Printf.sprintf "%d: (open %s)" s.sloc (name m)
