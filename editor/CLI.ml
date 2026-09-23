(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See CLI.mli *)

type caps = < Command.caps; Cap.argv; Cap.exit >

let main (caps : < caps; .. >) (argv : string array) : int =
  let rec flags verbose filter = function
    | "-o" :: rest -> flags false true rest
    | "-" :: rest -> flags false filter rest
    | rest -> verbose, filter, rest
  in
  let verbose, filter, args = flags true false (List.tl (Array.to_list argv)) in
  let t = Command.create caps (Input.of_fd Unix.stdin) ~verbose ~filter in
  Sys.catch_break true;
  Sys.set_signal Sys.sighup (Sys.Signal_handle (fun _ -> Command.rescue t; Out.flush (); exit 0));
  let file = match args with f :: _ when not filter -> Some f | _ -> None in
  Command.run t ~file;
  0
