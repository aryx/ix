(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#d', the descriptors as files (principia's devdup.c): for each
 * open descriptor N, N (opening it: the descriptor's channel again) and
 * Nctl (its offset and name). rc's /fd, and rcmain's '#d/0'. *)

(* the device registered *)
val init : unit -> unit
