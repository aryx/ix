(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Files.mli *)

let src = Logs.Src.create "files" ~doc:"whole files read and written"
module Log = (val Logs.src_log src : Logs.LOG)

let input caps file =
  let ic = CapStdlib.open_in caps (Fpath.to_string file) in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> In_channel.input_all ic)

let read (caps : < Cap.open_in; .. >) file =
  Log.debug (fun m -> m "read %a" Fpath.pp file);
  input caps file

let read_opt caps file =
  match input caps file with
  | s -> Log.debug (fun m -> m "read %a" Fpath.pp file); Some s
  | exception Sys_error e -> Log.debug (fun m -> m "cannot read %a: %s" Fpath.pp file e); None

let write (_ : < Cap.open_out; .. >) ?(perm = 0o644) file s =
  Log.debug (fun m -> m "write %a (%d bytes)" Fpath.pp file (String.length s));
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm (Fpath.to_string file)
    (fun oc -> Out_channel.output_string oc s)

let path s = match Fpath.of_string s with Ok p -> Ok p | Error (`Msg m) -> Error m
