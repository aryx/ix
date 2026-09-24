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

let read (caps : < Cap.open_in; .. >) file =
  let ic = CapStdlib.open_in caps file in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> In_channel.input_all ic)

let read_opt caps file = match CapStdlib.open_in caps file with
  | ic -> Some (Fun.protect ~finally:(fun () -> close_in ic) (fun () -> In_channel.input_all ic))
  | exception Sys_error _ -> None

let write (_ : < Cap.open_out; .. >) ?(perm = 0o644) file s =
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm file (fun oc -> Out_channel.output_string oc s)
