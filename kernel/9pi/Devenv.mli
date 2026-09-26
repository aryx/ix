(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#e', the environment (principia's devenv.c): a process's variables
 * as files (its Egrp: rc keeps its variables there, /env), created,
 * written, removed; '#ec' the kernel's configuration (confegrp: empty
 * here). *)

open Types

(* the device registered *)
val init : unit -> unit

(* a copy of an environment (RFENVG: envcpy) *)
val copy : egrp -> egrp
