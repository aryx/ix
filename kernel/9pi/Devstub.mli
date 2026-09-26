(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The devices 9pi has and mini-9pi does not yet, as empty directories,
 * so that boot.rc binds them as on 9pi: '#i' draw (stage D, step 3),
 * '#I' IP (stage E; its first attach spends rxmitproc's pid, as 9pi's
 * starts that kernel process). *)

(* the devices registered *)
val init : unit -> unit
