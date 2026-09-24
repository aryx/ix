(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Logging.mli *)

let setup (caps : < Cap.env; Cap.stderr; .. >) ~name =
  let level =
    match CapSys.getenv caps "IX_LOG" with
    | s -> (match Logs.level_of_string s with Ok l -> l | Error _ -> Some Logs.Warning)
    | exception Not_found -> Some Logs.Warning
  in
  Logs.set_level level;
  let pp_header ppf (l, _) = Fmt.pf ppf "%s: [%s] " name (String.uppercase_ascii (Logs.level_to_string (Some l))) in
  Logs.set_reporter (Logs_fmt.reporter ~pp_header ~dst:Fmt.stderr ())
