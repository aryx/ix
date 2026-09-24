(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Optimizer.mli *)
open Ast

let same a b = String.lowercase_ascii a = String.lowercase_ascii b

type side = Left | Right | Top

let classify (n1, a1, cols1) (n2, a2, cols2) (c : cond) =
  let named n a t = same t n || match a with Some a -> same t a | None -> false in
  let has cols name = List.exists (fun (col : column) -> same col.name name) cols in
  let side (r : column_ref) =
    match r.table with
    | Some t -> if named n1 a1 t then Left else if named n2 a2 t then Right else Top
    | None -> (match has cols1 r.column, has cols2 r.column with true, false -> Left | false, true -> Right | _ -> Top) in
  match c with
  | Cmp (_, { e = Column r; _ }, { e = Literal _; _ }) | Cmp (_, { e = Literal _; _ }, { e = Column r; _ }) -> side r
  | Cmp _ | And _ | Or _ | Not _ | In _ -> Top

let rec conjuncts = function And (a, b) -> conjuncts a @ conjuncts b | c -> [ c ]

let fold_and = function [] -> None | c :: rest -> Some (List.fold_left (fun acc c -> And (acc, c)) c rest)

let wrap cs s = match fold_and cs with Some c -> Select (c, s) | None -> s

let optimize schema (t : Ast.t) =
  match t.stmt with
  | Select_stmt (Project ({ sra = Select (cond, Natural_join ((Table r1 as s1), (Table r2 as s2))); _ } as p)) -> (
      match Schema.find_table schema r1.name, Schema.find_table schema r2.name with
      | Some t1, Some t2 ->
          let c1 = (r1.name, r1.alias, Schema.columns t1) and c2 = (r2.name, r2.alias, Schema.columns t2) in
          let cs = List.map (fun c -> classify c1 c2 c, c) (conjuncts cond) in
          let on s = List.filter_map (fun (s', c) -> if s' = s then Some c else None) cs in
          if on Left = [] && on Right = [] then t
          else
            let join = Natural_join (wrap (on Left) s1, wrap (on Right) s2) in
            { t with stmt = Select_stmt (Project { p with sra = wrap (on Top) join }) }
      | _ -> t)
  | _ -> t
