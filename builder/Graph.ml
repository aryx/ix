(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Graph.mli *)

type node = {
  name : string;
  arcs : arc list;
  virtual_ : bool;
  delete : bool;
  norecipe : bool;
  time : float;
}

and arc = {
  prereq : node option;
  rule : Mkfile.rule;
  stems : string array;
}

exception Error of string

type entry = {
  node : node;
  vacuous : bool;
  ambiguous : string option;   (* the error, raised only if reachable *)
}

type t = {
  mk : Mkfile.t;
  stat : string -> float;
  built : (string, entry) Hashtbl.t;
}

let create mk ~stat = { mk; stat; built = Hashtbl.create 101 }

let find g name = Option.map (fun e -> e.node) (Hashtbl.find_opt g.built name)

let is_meta (a : arc) = Pattern.is_meta a.rule.pattern
let has_recipe (a : arc) = a.rule.recipe <> ""
let same_rule (a : arc) (b : arc) = a.rule.id = b.rule.id && a.rule.target = b.rule.target

(*****************************************************************************)
(* Pruning *)
(*****************************************************************************)

(* graph.c's vacuous(): drop the arcs from metarules to vacuous nodes,
 * unless another arc of the same rule stays *)
let prune_vacuous (built : string -> entry) (arcs : arc list) : arc list * bool =
  let dropped (a : arc) =
    match a.prereq with
    | Some n -> (built n.name).vacuous && is_meta a
    | None -> false
  in
  let kept = List.filter (fun a -> not (dropped a)) arcs in
  List.filter (fun a -> not (dropped a) || List.exists (same_rule a) kept) arcs,
  List.for_all dropped arcs

(* graph.c's trace(): an arc, then down the arcs that have a recipe *)
let trace name (a : arc) : string =
  let b = Buffer.create 80 in
  Buffer.add_string b ("\t" ^ name);
  let rec go (a : arc) =
    let dest = match a.prereq with Some n -> n.name | None -> "" in
    Printf.bprintf b " <-(%s:%d)- %s" a.rule.file a.rule.line dest;
    match a.prereq with
    | Some n -> Option.iter go (List.find_opt has_recipe n.arcs)
    | None -> ()
  in
  go a;
  Buffer.contents b ^ "\n"

(* graph.c's ambiguous(): the arcs with a recipe must all carry the same
 * one, a rule naming the target beating a metarule *)
let prune_ambiguous name (arcs : arc list) : arc list * string option =
  let master = ref None and dropped = ref [] and conflicts = ref [] in
  arcs |> List.iter (fun a ->
    if has_recipe a then
      match !master with
      | None -> master := Some a
      | Some m when m.rule.id = a.rule.id -> ()
      | Some m when is_meta m && not (is_meta a) -> dropped := m :: !dropped; master := Some a
      | Some m when not (is_meta m) && is_meta a -> dropped := a :: !dropped
      | Some _ -> conflicts := a :: !conflicts);
  let error =
    match !master, List.rev !conflicts with
    | Some m, (_ :: _ as cs) ->
        Some (Printf.sprintf "ambiguous recipes for %s:\n" name
              ^ String.concat "" (List.map (trace name) (m :: cs)))
    | _ -> None
  in
  List.filter (fun a -> not (List.memq a !dropped)) arcs, error

(*****************************************************************************)
(* Main algorithm *)
(*****************************************************************************)

(* graph.c's applyrules(), memoized: a node is built once *)
let rec build g ~nrep (count : (int * string, int) Hashtbl.t) (path : string list)
    (name : string) : entry =
  match Hashtbl.find_opt g.built name with
  | Some e -> e
  | None ->
      if List.mem name path then
        raise (Error ("cycle in graph detected at target " ^ name));
      let time = g.stat name in
      let probable = ref (time > 0.) in
      let arcs = ref [] in
      let prereq p = Some (build g ~nrep count (name :: path) p).node in
      (* one use of rule [r], counted against NREP while its
       * prerequisites are being built *)
      let use (r : Mkfile.rule) f =
        let k = (r.id, r.target) in
        let c = Option.value (Hashtbl.find_opt count k) ~default:0 in
        if c < nrep then begin
          Hashtbl.replace count k (c + 1);
          f ();
          Hashtbl.replace count k c
        end
      in
      let add (r : Mkfile.rule) stems =
        match r.prereqs with
        | [] -> arcs := { prereq = None; rule = r; stems } :: !arcs
        | ps -> ps |> List.iter (fun p ->
            let p = Pattern.subst r.pattern stems p in
            arcs := { prereq = prereq p; rule = r; stems } :: !arcs)
      in
      let useless (r : Mkfile.rule) = r.recipe = "" && r.prereqs = [] in
      Mkfile.rules_for g.mk name |> List.iter (fun (r : Mkfile.rule) ->
        if not (useless r) then use r (fun () -> probable := true; add r [||]));
      Mkfile.metarules g.mk |> List.iter (fun (r : Mkfile.rule) ->
        let after_virtual () =
          match !arcs with a :: _ -> a.rule.attrs.virtual_ | [] -> false
        in
        if not (useless r) && not (r.attrs.novirtual && after_virtual ()) then
          match Pattern.matches r.pattern name with
          | Some stems -> use r (fun () -> add r stems)
          | None -> ());
      let lookup n = Hashtbl.find g.built n in
      let arcs, all_dropped = prune_vacuous lookup (List.rev !arcs) in
      let vacuous = (not !probable) && all_dropped in
      let arcs, ambiguous = prune_ambiguous name arcs in
      let any f = List.exists (fun (a : arc) -> f a.rule.attrs) arcs in
      let virtual_ = any (fun a -> a.virtual_) in
      let node = {
        name; arcs; virtual_;
        delete = any (fun a -> a.delete);
        norecipe = any (fun a -> a.norecipe);
        time = (if virtual_ then 0. else time);
      } in
      let e = { node; vacuous; ambiguous } in
      Hashtbl.replace g.built name e;
      e

let node g ~nrep target =
  let root = (build g ~nrep (Hashtbl.create 17) [] target).node in
  (* the ambiguities of the nodes that stayed in the graph *)
  let seen = Hashtbl.create 101 in
  let rec check (n : node) =
    if not (Hashtbl.mem seen n.name) then begin
      Hashtbl.replace seen n.name ();
      n.arcs |> List.iter (fun a -> Option.iter check a.prereq);
      match (Hashtbl.find g.built n.name).ambiguous with
      | Some msg -> raise (Error msg)
      | None -> ()
    end
  in
  check root;
  root

(*****************************************************************************)
(* Debug *)
(*****************************************************************************)

let dump (root : node) : string =
  let b = Buffer.create 1000 and seen = Hashtbl.create 101 in
  let rec go indent (n : node) =
    Printf.bprintf b "%s%s%s\n" indent n.name (if n.virtual_ then " (virtual)" else "");
    if not (Hashtbl.mem seen n.name) then begin
      Hashtbl.replace seen n.name ();
      n.arcs |> List.iter (fun a ->
        match a.prereq with
        | Some p -> go (indent ^ "  ") p
        | None -> Printf.bprintf b "%s  (no prerequisite, %s:%d)\n" indent a.rule.file a.rule.line)
    end
  in
  go "" root;
  Buffer.contents b
