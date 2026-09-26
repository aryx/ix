(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* Page faults (principia's fault.c, as far as mini-9pi needs): a
 * process's page given at its first touch, from its segment: the
 * program's file for text and data (read through its channel: devmnt's
 * Tread, devroot's bytes), zeros for bss and stack. The system calls
 * fault a user's buffer in before using it (validaddr). *)

open Types

(* [fault p va]: the page at va given (true), or not in a segment
 * (false: the process's trap) *)
val fault : proc -> int -> bool

(* [validaddr p addr len]: the pages of [addr, addr+len) that are in a
 * segment, given *)
val validaddr : proc -> int -> int -> unit

(* the segments' images released (exec, exits) *)
val release : segment list -> unit
