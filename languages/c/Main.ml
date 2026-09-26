(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* mini-cc, the ix C compiler: see CLI.mli *)

let () = Cap.main (fun caps -> Logging.setup caps ~name:"mini-cc"; CapStdlib.exit caps (Ix_cc_cli.CLI.main caps (CapSys.argv caps)))
