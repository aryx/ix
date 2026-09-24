(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Store.mli *)

type caps = < Cap.open_in; Cap.open_out >

type t = { caps : caps; git : Fpath.t; mutable packs : Pack.t list option; cache : (Hash.t, Object.t) Hashtbl.t }

exception Missing of Hash.t

let open_git caps git = { caps; git; packs = None; cache = Hashtbl.create 256 }

let refresh t = t.packs <- None

let packs t =
  match t.packs with
  | Some ps -> ps
  | None -> let ps = List.map (Pack.open_idx t.caps) (Pack.all t.git) in t.packs <- Some ps; ps

let rec read_raw t h =
  let rec in_packs = function
    | [] -> None
    | p :: rest -> (match Pack.read p ~base:(read_raw t) h with Some o -> Some o | None -> in_packs rest) in
  match in_packs (packs t) with
  | Some o -> Some o
  | None -> Loose.read t.caps t.git h

(* the empty tree exists without being stored, in C git and in git9
 * (emptydir) *)
let empty_tree = Hash.of_object "tree" ""

let read_raw t h =
  if Hash.compare h empty_tree = 0 then Some (Object.Kind.Tree, "")
  else match read_raw t h with
  | Some o -> Some o
  | None -> refresh t; read_raw t h

let read t h =
  match Hashtbl.find_opt t.cache h with
  | Some o -> o
  | None -> (
      match read_raw t h with
      | None -> raise (Missing h)
      | Some (k, s) ->
          let o = Object.parse k s in
          (* blobs are read once, for a checkout or a diff: not kept *)
          (match o with Blob _ -> () | _ -> Hashtbl.replace t.cache h o);
          o)

let mem t h =
  Hash.compare h empty_tree = 0 || Hashtbl.mem t.cache h || List.exists (fun p -> Pack.mem p h) (packs t) || Sys.file_exists (Fpath.to_string (Loose.path t.git h))

let write t o =
  let h = Loose.write t.caps t.git (Object.kind o) (Object.print o) in
  (match o with Blob _ -> () | _ -> Hashtbl.replace t.cache h o);
  h

let all t = Loose.all t.git @ List.concat_map Pack.hashes (packs t)

let expand t prefix =
  if String.length prefix < 8 || not (String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) prefix) then None
  else
    match List.sort_uniq Hash.compare (List.filter (fun h -> String.starts_with ~prefix (Hash.to_hex h)) (all t)) with
    | [ h ] -> Some h
    | _ -> None
