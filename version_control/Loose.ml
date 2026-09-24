(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Loose.mli *)

let path git h =
  let hex = Hash.to_hex h in
  Fpath.(git / "objects" / String.sub hex 0 2 / String.sub hex 2 38)

let read caps git h =
  match Files.read_opt caps (path git h) with
  | None -> None
  | Some z ->
      let s, _ = Zlib.inflate z in
      let corrupt () = raise (Object.Corrupt ("bad loose object " ^ Hash.to_hex h)) in
      let nul = match String.index_opt s '\000' with Some i -> i | None -> corrupt () in
      match String.split_on_char ' ' (String.sub s 0 nul) with
      | [ k; size ] -> (
          match Object.Kind.of_string k, int_of_string_opt size with
          | Some k, Some n when n = String.length s - nul - 1 -> Some (k, String.sub s (nul + 1) n)
          | _ -> corrupt ())
      | _ -> corrupt ()

let write caps git (k : Object.Kind.t) data =
  let kind = Object.Kind.to_string k in
  let h = Hash.of_object kind data in
  let p = path git h in
  if not (Sys.file_exists (Fpath.to_string p)) then begin
    let dir = Fpath.to_string (Fpath.parent p) in
    if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
    let tmp = Fpath.(parent p / ("tmp." ^ string_of_int (Unix.getpid ()))) in
    Files.write caps ~perm:0o444 tmp (Zlib.deflate (Printf.sprintf "%s %d\000%s" kind (String.length data) data));
    Unix.rename (Fpath.to_string tmp) (Fpath.to_string p)
  end;
  h

let all git =
  let dir = Fpath.(to_string (git / "objects")) in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list |> List.sort compare
    |> List.concat_map (fun d ->
         if String.length d <> 2 then []
         else
           Sys.readdir (Filename.concat dir d) |> Array.to_list |> List.sort compare
           |> List.filter_map (fun f -> if Hash.is_hex (d ^ f) then Some (Hash.of_hex (d ^ f)) else None))
