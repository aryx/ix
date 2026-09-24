(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Fs.mli *)

type node = File of string | Dir of string list

let ctl (r : Repo.t) =
  match Files.read_opt r.store.caps Fpath.(r.store.git / "HEAD") with
  | None | Some "" -> None
  | Some s ->
      let s = if String.starts_with ~prefix:"ref:" s then String.sub s 4 (String.length s - 4) else s in
      let s = String.trim (List.hd (String.split_on_char '\n' (String.trim s))) in
      let s = if String.starts_with ~prefix:"refs/" s then String.sub s 5 (String.length s - 5) else s in
      Some (File (Printf.sprintf "branch %s\nrepo %s\n" s (Fpath.to_string r.root)))

let rec tree (r : Repo.t) h = function
  | [] -> (match Store.read r.store h with Tree es -> Some (Dir (List.map (fun (e : Object.entry) -> e.name) es)) | _ -> None)
  | name :: rest -> (
      match Store.read r.store h with
      | Tree es -> (
          match List.find_opt (fun (e : Object.entry) -> e.name = name) es with
          | Some { mode = Dir; hash; _ } -> tree r hash rest
          | Some { mode = Submodule; _ } -> if rest = [] then Some (Dir []) else None
          | Some { hash; _ } -> (match Store.read r.store hash, rest with Blob s, [] -> Some (File s) | _ -> None)
          | None -> None)
      | _ -> None)

and commit (r : Repo.t) h path =
  match Store.read r.store h with
  | Commit c -> (
      match path with
      | [] -> Some (Dir [ "tree"; "parent"; "msg"; "hash"; "author" ])
      | "tree" :: rest -> tree r c.tree rest
      | [ "parent" ] -> Some (File (String.concat "" (List.map (fun p -> Hash.to_hex p ^ "\n") c.parents)))
      | [ "msg" ] -> Some (File (Object.message c))
      | [ "hash" ] -> Some (File (Hash.to_hex h ^ "\n"))
      | [ "author" ] -> Some (File (c.author.id ^ "\n"))
      | [ "committer" ] -> Some (File (c.committer.id ^ "\n"))
      | _ -> None)
  | Tree _ -> tree r h path
  | Blob s | Tag s -> if path = [] then Some (File s) else None

let rec branch (r : Repo.t) dir path =
  match path with
  | [] ->
      (match Sys.readdir dir with
       | fs -> Some (Dir (List.sort compare (Array.to_list fs)))
       | exception Sys_error _ -> None)
  | name :: rest ->
      let p = if Filename.basename dir = "heads" && name = "HEAD" then Fpath.to_string Fpath.(r.store.git / "HEAD") else Filename.concat dir name in
      if Sys.file_exists p && Sys.is_directory p then branch r p rest
      else
        (* git9's fs follows "ref:" relative to .git itself *)
        let rec follow p n =
          match Files.read_opt r.store.caps (Fpath.v p) with
          | Some s when n > 0 && String.starts_with ~prefix:"ref:" s ->
              follow (Filename.concat (Fpath.to_string r.store.git) (String.trim (String.sub s 4 (String.length s - 4)))) (n - 1)
          | Some s when String.length s >= 40 && Hash.is_hex (String.sub s 0 40) -> Some (Hash.of_hex (String.sub s 0 40))
          | _ -> None in
        Option.bind (follow p 10) (fun h -> commit r h rest)

let resolve (r : Repo.t) path =
  let parts = List.filter (fun s -> s <> "" && s <> ".") (String.split_on_char '/' path) in
  try
    match parts with
    | [] -> Some (Dir [ "ctl"; "HEAD"; "branch"; "object" ])
    | [ "ctl" ] -> ctl r
    | "HEAD" :: rest -> (
        match Refs.read r.store "HEAD" with
        | Some h -> commit r h rest
        | None -> if rest = [] then Some (Dir []) else None)
    | "branch" :: rest -> branch r (Fpath.to_string Fpath.(r.store.git / "refs")) rest
    | [ "object" ] -> Some (Dir (List.map Hash.to_hex (Store.all r.store)))
    | "object" :: h :: rest -> if Hash.is_hex h then commit r (Hash.of_hex h) rest else None
    | _ -> None
  with Store.Missing _ -> None
