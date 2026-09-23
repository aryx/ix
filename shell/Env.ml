(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Env.mli *)

type t = {
  vars : (string, string list) Hashtbl.t;
  fns : (string, Ast.cmd) Hashtbl.t;
  flags : (char, unit) Hashtbl.t;
}

let create () = { vars = Hashtbl.create 101; fns = Hashtbl.create 17; flags = Hashtbl.create 7 }

let get t name = Option.value (Hashtbl.find_opt t.vars name) ~default:[]

let raw_set t name v = if v = [] then Hashtbl.remove t.vars name else Hashtbl.replace t.vars name v

(* $path and $PATH are the same list, written two ways *)
let set t name v =
  raw_set t name v;
  match name with
  | "path" -> raw_set t "PATH" (if v = [] then [] else [ String.concat ":" v ])
  | "PATH" -> raw_set t "path" (List.concat_map (String.split_on_char ':') v)
  | _ -> ()

let local t name v f =
  let saved = Hashtbl.find_opt t.vars name in
  set t name v;
  Fun.protect f ~finally:(fun () -> set t name (Option.value saved ~default:[]))

let status t = String.concat "" (get t "status")
let set_status t s = raw_set t "status" [ s ]
let ok t = String.for_all (fun c -> c = '0' || c = '|') (status t)

let fn t name = Hashtbl.find_opt t.fns name
let set_fn t name = function Some c -> Hashtbl.replace t.fns name c | None -> Hashtbl.remove t.fns name
let vars t = Hashtbl.fold (fun k v acc -> (k, v) :: acc) t.vars [] |> List.sort compare

let flag t c = Hashtbl.mem t.flags c
let set_flag t c on = if on then Hashtbl.replace t.flags c () else Hashtbl.remove t.flags c

let import t (env : string array) =
  env |> Array.iter (fun kv ->
    match String.index_opt kv '=' with
    | None -> ()
    | Some i ->
        let name = String.sub kv 0 i and v = String.sub kv (i + 1) (String.length kv - i - 1) in
        if String.length name > 3 && String.sub name 0 3 = "fn#" then
          (* the function's body, as whatis prints it *)
          match Parser.parse_string v with
          | c -> set_fn t (String.sub name 3 (String.length name - 3)) (Some c)
          | exception _ -> ()
        else set t name (String.split_on_char '\001' v))

let export t : string array =
  let vars =
    Hashtbl.fold (fun k v acc -> if v = [] then acc else (k ^ "=" ^ String.concat "\001" v) :: acc) t.vars []
  in
  (* plan9port's rc ends a function's value with a newline, and needs it *)
  let fns = Hashtbl.fold (fun k c acc -> ("fn#" ^ k ^ "=" ^ Ast.to_string Ast.cmd c ^ "\n") :: acc) t.fns [] in
  Array.of_list (List.sort compare vars @ List.sort compare fns)
