(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* tinyld, the ix linker: see CLI.mli *)

let () = Cap.main (fun caps -> Logging.setup caps ~name:"tinyld"; CapStdlib.exit caps (Ix_ld.CLI.main caps (CapSys.argv caps)))
