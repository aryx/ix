(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Outofdate.mli *)

type hashes = {
  digest : string -> string option;
  traces : (string, string) Hashtbl.t;
}

type ctx = {
  time : string -> float;
  prog : string -> string -> string -> bool;
  answers : (string * string, bool) Hashtbl.t;   (* :P:'s, remembered *)
  hashes : hashes option;
}

let create ?hashes ~time ~prog () = { time; prog; answers = Hashtbl.create 17; hashes }

(* -H: a node's trace is its recipe and its prerequisites' digests; a
 * virtual or missing prerequisite stands for its own trace *)
let rec trace h (n : Graph.node) : string =
  let recipe =
    List.fold_left (fun r (a : Graph.arc) -> if a.rule.recipe <> "" then a.rule.recipe else r) "" n.arcs
  in
  let deps =
    List.filter_map (fun (a : Graph.arc) ->
      Option.map (fun (p : Graph.node) -> p.name ^ " " ^ digest_of h p) a.prereq) n.arcs
  in
  Digest.to_hex (Digest.string (String.concat "\n" (recipe :: deps)))

and digest_of h (p : Graph.node) : string =
  match if p.virtual_ then None else h.digest p.name with
  | Some d -> d
  | None -> trace h p

let is_member (name : string) = String.contains name '('

let by_prog ?(eval = false) ctx cmd (node : Graph.node) (p : Graph.node) =
  let k = (node.name, p.name) in
  match Hashtbl.find_opt ctx.answers k with
  | Some b when not eval -> b
  | _ ->
      let b = not (ctx.prog cmd node.name p.name) in
      Hashtbl.replace ctx.answers k b;
      b

let arc ?eval ctx (node : Graph.node) (a : Graph.arc) (p : Graph.node) : bool =
  match a.rule.attrs.prog, ctx.hashes with
  | Some cmd, _ -> by_prog ?eval ctx cmd node p
  | None, Some h when Hashtbl.mem h.traces node.name ->
      (* -H: the whole node is out of date or not, whichever arc asks *)
      node.virtual_ || h.digest node.name = None
      || Hashtbl.find (h.traces) node.name <> trace h node
  | None, _ ->
      (* no trace yet (or no -H): the times decide *)
      (is_member p.name && ctx.time p.name = 0.)   (* a missing archive member *)
      || ctx.time node.name <= ctx.time p.name

let up_to_date ctx (node : Graph.node) : unit =
  match ctx.hashes with
  | Some h when node.arcs <> [] && not node.virtual_ ->
      Hashtbl.replace h.traces node.name (trace h node)
  | _ -> ()

let after_recipe ctx ~exists ~stat (node : Graph.node) : float =
  Option.iter (fun h -> Hashtbl.replace h.traces node.name (trace h node)) ctx.hashes;
  if node.virtual_ || not (exists node.name) then
    (* the newest prerequisite it was out of date with, at least 1 *)
    List.fold_left (fun t (a : Graph.arc) ->
      match a.prereq, a.rule.attrs.prog with
      | Some p, Some cmd -> if by_prog ~eval:true ctx cmd node p then ctx.time p.name else t
      | Some p, None -> if t <= ctx.time p.name then ctx.time p.name else t
      | None, _ -> t) 1. node.arcs
  else begin
    node.arcs |> List.iter (fun (a : Graph.arc) ->
      match a.prereq, a.rule.attrs.prog with
      | Some p, Some cmd -> ignore (by_prog ~eval:true ctx cmd node p)
      | _ -> ());
    stat node.name
  end
