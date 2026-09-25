(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The system calls (principia's syscall.c, sysfile.c, sysproc.c): the
 * number in R0 (principia's numbering, sys.h), the arguments on the
 * user's stack from sp+4 (5c's stubs: MOVW R0, 0(FP); SWI $0), the
 * result in R0; a call failing returns -1, errstr saying why. Stage A:
 * nop, exec, exits, brk, open, close, pread, pwrite, errstr; the
 * others fail ("not yet", named on the console). *)

open Types

(* the running process's system call, from its trap frame *)
val syscall : proc -> unit

(* the process's end (pexit): its files closed, its memory freed; the
 * boot process's is the kernel's panic *)
val exits : proc -> string -> unit

(* the descriptors a process has (Plan 9's NFD... here fixed) *)
val nfd : int
