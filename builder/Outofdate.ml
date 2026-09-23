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

type ctx = {
  time : string -> float;
  prog : string -> string -> string -> bool;
  answers : (string * string, bool) Hashtbl.t;   (* :P:'s, remembered *)
}

let create ~time ~prog = { time; prog; answers = Hashtbl.create 17 }

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
  match a.rule.attrs.prog with
  | Some cmd -> by_prog ?eval ctx cmd node p
  | None ->
      (is_member p.name && ctx.time p.name = 0.)   (* a missing archive member *)
      || ctx.time node.name <= ctx.time p.name

let after_recipe ctx ~exists ~stat (node : Graph.node) : float =
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
