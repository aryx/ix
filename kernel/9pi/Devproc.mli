(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#p', the processes (principia's devproc.c): a directory per process
 * (its pid), its files procdir's. Here: status, args, fd, ns, noteid,
 * segment, ctl (kill), note, notepg (notes posted); the debugger's
 * (mem, regs, text...) not yet. *)

(* the device registered *)
val init : unit -> unit
