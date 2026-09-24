(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Procs.mli *)

let write_all fd s =
  let n = String.length s in
  let rec go off =
    if off < n then
      match Unix.write_substring fd s off (n - off) with
      | k -> go (off + k)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> go off
  in
  try go 0 with Unix.Unix_error (Unix.EPIPE, _, _) -> ()

let read_all fd =
  let b = Buffer.create 1024 and chunk = Bytes.create 4096 in
  let rec go () =
    match Unix.read fd chunk 0 4096 with
    | 0 -> ()
    | k -> Buffer.add_subbytes b chunk 0 k; go ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
  in
  go ();
  Buffer.contents b

let rec waitpid caps pid =
  match CapUnix.waitpid caps [] pid with
  | _, st -> st
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid caps pid

let rec wait_any caps =
  match CapUnix.wait caps () with
  | r -> Some r
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_any caps
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> None

let split_env env =
  Array.to_list env |> List.filter_map (fun kv ->
    match String.index_opt kv '=' with
    | Some i -> Some (String.sub kv 0 i, String.sub kv (i + 1) (String.length kv - i - 1))
    | None -> None)
