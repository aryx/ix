(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Console.mli *)

let print (_ : < Cap.stdout; .. >) s = print_string s
let eprint (_ : < Cap.stderr; .. >) s = prerr_string s; flush stderr
