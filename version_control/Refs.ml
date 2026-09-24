(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Refs.mli *)

let strip = String.trim

(* git9's hparse: 40 hex digits at the start, whatever follows *)
let hparse s =
  if String.length s < 40 then None
  else let h = String.lowercase_ascii (String.sub s 0 40) in if Hash.is_hex h then Some (Hash.of_hex h) else None

let packed (t : Store.t) =
  match Files.read_opt t.caps Fpath.(t.git / "packed-refs") with
  | None -> []
  | Some s ->
      String.split_on_char '\n' s
      |> List.filter_map (fun l ->
           match String.index_opt l ' ' with
           | Some i when l <> "" && l.[0] <> '#' && l.[0] <> '^' ->
               Option.map (fun h -> String.sub l (i + 1) (String.length l - i - 1), h) (hparse l)
           | _ -> None)

let prefixes = [ ""; "refs/"; "refs/heads/"; "refs/remotes/"; "refs/tags/" ]

let rec read (t : Store.t) name =
  match hparse name with
  | Some h when String.length name = 40 -> Some h
  | _ ->
      let found s = match hparse s with
        | Some h -> Some h
        | None -> if String.starts_with ~prefix:"ref: " s then read t (String.sub s 5 (String.length s - 5)) else None in
      if name = "HEAD" then Option.bind (Files.read_opt t.caps Fpath.(t.git / "HEAD")) (fun s -> found (strip s))
      else
        let rec try_ = function
          | [] -> Store.expand t name
          | p :: rest -> (
              match (try Files.read_opt t.caps (Fpath.v (Fpath.to_string t.git ^ "/" ^ p ^ name)) with Sys_error _ -> None) with
              | Some s -> found (strip s)
              | None -> (match List.assoc_opt (p ^ name) (packed t) with Some h -> Some h | None -> try_ rest)) in
        try_ prefixes

let head_ref git =
  match In_channel.with_open_bin (Fpath.to_string Fpath.(git / "HEAD")) In_channel.input_all with
  | s -> let s = strip s in if String.starts_with ~prefix:"ref: " s then Some (String.sub s 5 (String.length s - 5)) else None
  | exception Sys_error _ -> None

let list (t : Store.t) =
  let rec walk dir name =
    match Sys.readdir dir with
    | exception Sys_error _ -> []
    | fs ->
        Array.to_list fs |> List.concat_map (fun f ->
          let path = Filename.concat dir f and n = if name = "" then f else name ^ "/" ^ f in
          if Sys.is_directory path then walk path n
          else match read t ("refs/" ^ n) with Some h -> [ n, h ] | None -> [])
  in
  let loose = walk (Fpath.to_string Fpath.(t.git / "refs")) "" in
  let packed = List.filter_map (fun (n, h) ->
    if String.starts_with ~prefix:"refs/" n then let n = String.sub n 5 (String.length n - 5) in
      if List.mem_assoc n loose then None else Some (n, h) else None) (packed t) in
  List.sort compare (loose @ packed)

let path (t : Store.t) name = Fpath.v (Fpath.to_string t.git ^ "/" ^ name)

let write_string (t : Store.t) name s =
  let p = path t name in
  let rec mkdirs d = if not (Sys.file_exists d) then (mkdirs (Filename.dirname d); Unix.mkdir d 0o755) in
  mkdirs (Filename.dirname (Fpath.to_string p));
  let tmp = Fpath.v (Fpath.to_string p ^ ".tmp") in
  Files.write t.caps tmp s;
  Unix.rename (Fpath.to_string tmp) (Fpath.to_string p)

let write t name h = write_string t name (Hash.to_hex h ^ "\n")
let write_symbolic t name target = write_string t name ("ref: " ^ target ^ "\n")
let remove t name = try Sys.remove (Fpath.to_string (path t name)) with Sys_error _ -> ()
