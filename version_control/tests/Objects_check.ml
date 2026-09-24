(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* Every object of a repository through Store, for objects.sh: for each
 * hash on standard input, "HASH KIND SIZE" as git cat-file
 * --batch-check prints it, and "BAD" where print (parse o) does not
 * hash back to it. *)
open Ix_vcs

let () =
  Cap.main (fun caps ->
    let git = Fpath.v Sys.argv.(1) in
    let t = Store.open_git (caps :> Store.caps) git in
    let rec loop () =
      match In_channel.input_line stdin with
      | None -> ()
      | Some hex ->
          let h = Hash.of_hex hex in
          (match Store.read_raw t h with
           | None -> print_endline (hex ^ " missing")
           | Some (k, s) ->
               let o = Object.parse k s in
               let ok = Hash.compare (Object.hash o) h = 0 in
               Printf.printf "%s %s %d%s\n" hex (Object.Kind.to_string k) (String.length s) (if ok then "" else " BAD"));
          loop ()
    in
    loop ())
