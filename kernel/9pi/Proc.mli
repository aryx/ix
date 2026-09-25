(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The processes (principia's proc.c, as mini-xv6's Proc): a table of
 * slots (kernel/lib's runtime.c: a slot's kernel stack and trap frame),
 * a round-robin scheduler on the boot stack, sleep and wakeup on a
 * wait_chan. One core, no preemption inside the kernel: no locks. *)

open Types

val nproc : int
val procs : proc option array

(* the running process *)
val myproc : unit -> proc

(* a free slot, or None; the next pid *)
val free_slot : unit -> int option
val nextpid : int ref

(* back to the scheduler; asleep until a wakeup on the channel; the CPU
 * given up *)
val sched : unit -> unit
val sleep : wait_chan -> unit
val wakeup : wait_chan -> unit
val yield : unit -> unit

(* what the scheduler does when nothing runs (Main: wait for an
 * interrupt, handle it) *)
val idle : (unit -> unit) ref

(* runs the processes, forever *)
val scheduler : unit -> unit
