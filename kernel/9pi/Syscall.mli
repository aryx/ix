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
 * result in R0; a call failing returns -1, errstr saying why. Stage B:
 * the processes (rfork, exec, exits, await, sleep, notify), the files
 * (open, create, close, pread, pwrite, seek, dup, pipe, fd2path, stat,
 * fstat, wstat, fwstat, remove, chdir), the namespace (bind, mount,
 * unmount, fauth, fversion: devmnt), brk, errstr, notes (notify,
 * noted: arm's NFrame), rendezvous, semaphores, alarm; the others fail
 * ("not yet", named on the console): the segments' (segattach...). *)

open Types

(* the running process's system call, from its trap frame *)
val syscall : proc -> unit

(* a pending note delivered on the way back to user mode (notify: to
 * the handler, or the process's end), the trap frame's type (a Ureg's:
 * the processor mode trapped to) *)
val notify : proc -> int -> unit

(* a trap's note (NDebug: "text pid: suicide: msg" when not handled),
 * delivered at once *)
val trap : proc -> string -> int -> unit

(* each call printed on the console (debugging) *)
val trace : bool ref

(* the process's end (pexit): its files closed, its parent told (a
 * wait record), its memory freed; the boot process's is the kernel's
 * panic *)
val exits : proc -> string -> unit
