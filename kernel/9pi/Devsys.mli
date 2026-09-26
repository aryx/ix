(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#k', the system's files (principia's devsys.c): osversion, config,
 * hostowner (written: the kernel's owner, eve), hostdomain, sysname,
 * drivers, reboot, sysstat. *)

(* the device registered *)
val init : unit -> unit
