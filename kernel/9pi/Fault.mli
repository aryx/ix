(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* Segments and page faults (principia's segment.c and fault.c, as far
 * as mini-9pi needs): a segment's pages are its own (a table of them),
 * given at their first touch: from the program's file for text and data
 * (read through its channel: devmnt's Tread, devroot's bytes), zeros
 * for bss and stack. A process's table maps a segment's pages as it
 * touches them, so that a segment may be shared (text always, data and
 * bss by rfork's RFMEM): a fault maps the page another sharer made. The
 * system calls fault a user's buffer in before using it (validaddr). *)

open Types

(* a new segment, no page yet (its image, the file's bytes' offset and
 * length) *)
val create : seg_kind -> int -> int -> chan option -> int -> int -> segment

(* [fault p va]: the page at va mapped, made if need be (true), or not
 * in a segment (false: the process's trap) *)
val fault : proc -> int -> bool

(* [validaddr p addr len]: the pages of [addr, addr+len) that are in a
 * segment, mapped *)
val validaddr : proc -> int -> int -> unit

(* [page pgdir s va]: a page of s made (zeroed) and mapped in the table
 * pgdir (exec writing the arguments in its new space) *)
val page : int -> segment -> int -> unit

(* [dup s pgdir share]: a fork's segment: s itself (shared: text, and
 * with RFMEM data and bss), or a copy of its pages, mapped in pgdir *)
val dup : segment -> int -> bool -> segment

(* a process's segments given up (exec, exits): a segment's pages freed,
 * its image closed, by its last process; the table's own pages freed *)
val release : int -> segment list -> unit

(* [shrink p s newtop]: the pages from newtop up freed (brk; Error
 * einuse when shared) *)
val shrink : proc -> segment -> int -> unit
