(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The processes (principia's proc.c): a table of slots (kernel/lib's
 * runtime.c: a slot's kernel stack and trap frame), a run queue and its
 * scheduler on the boot stack, sleep and wakeup on a wait_chan. One
 * core, no preemption inside the kernel: no locks. *)

open Types

val nproc : int
val procs : proc option array

(* the running process *)
val myproc : unit -> proc

(* a pid spent as 9pi's kernel process of that name takes it (kgenrandom,
 * alarm, kpager, rxmitproc: mini-9pi has none), for the pids to be
 * 9pi's *)
val kproc : string -> unit

(* the clock's ticks (100 a second) *)
val ticks : int ref

(* a free slot, or None; the next pid *)
val free_slot : unit -> int option
val nextpid : int ref

(* a process ready to run: at the run queue's end; readied by another
 * process, it runs next (Plan 9's cooperative scheduling: cpu->readied) *)
val ready : proc -> unit

(* back to the scheduler; asleep until a wakeup on the channel (the
 * sleepers readied); the CPU given up *)
val sched : unit -> unit
val sleep : wait_chan -> unit

(* asleep [ms] milliseconds (to the next tick: 10ms each; interrupted
 * by a note, as sleep) *)
val tsleep : int -> unit

(* a sleep's error when a note is pending ("interrupted": Plan 9's
 * Eintr, the note then delivered) *)
val eintr : string
val wakeup : wait_chan -> unit
val yield : unit -> unit

(* a tick's preemption due: the running process's 100ms over, another
 * ready (hzsched); the CPU given up so, without cooperative handing
 * over *)
val preempt_due : unit -> bool
val preempt : unit -> unit

(* what the scheduler does when nothing runs (Main: wait for an
 * interrupt, handle it) *)
val idle : (unit -> unit) ref

(* runs the processes, forever, the run queue's first each time (Plan 9's
 * order: a new process runs before its parent goes on); a dead one's
 * slot freed (Zombie: once off its kernel stack) *)
val scheduler : unit -> unit

(* a live process by its pid *)
val find : int -> proc option

(* [postnote p msg flag] (postnote): the note queued (NNOTE at most:
 * false when full; a kill's, without a handler for it, alone), p's
 * sleep interrupted, a rendezvous's given up (its value -1) *)
val postnote : proc -> string -> note_flag -> bool
