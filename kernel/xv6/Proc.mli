(* mini-xv6's processes (xv6's proc.c, less fork, exit and wait, which
 * need the files: Syscall.ml): the table, sleep and wakeup, the
 * scheduler.
 *
 * No locks. xv6 takes a lock around every change of a process's state
 * and hands it through the switch; this kernel runs on one core and is
 * never interrupted (IRQs arrive in user mode only: kernel/step5), so a
 * check and the sleep after it cannot be separated by a wakeup: xv6's
 * lost-wakeup problem does not arise, and sleep needs no lock to
 * release. *)

(* NPROC; the slot of the scheduler's context, after the processes' *)
val nproc : int
val scheduler_slot : int

(* the processes, by slot (a slot is a kernel stack and a trap frame,
 * machine.c's) *)
val procs : Types.proc option array
val nextpid : int ref

(* the clock, 100 ticks a second (xv6's ticks) *)
val ticks : int ref

(* the running process (not to be called from the scheduler) *)
val myproc : unit -> Types.proc

(* the processes, in slot order; those with a pid *)
val all : unit -> Types.proc list
val find : int -> Types.proc list

(* back to the scheduler; the running process asleep on a channel; those
 * asleep on it made runnable; the CPU given up *)
val sched : unit -> unit
val sleep : Types.chan -> unit
val wakeup : Types.chan -> unit
val yield : unit -> unit

(* xv6's kill: 0, or -1 (no such pid) *)
val kill : int -> int

val free_slot : unit -> int option

(* what the scheduler does when nothing can run: set by Main (wait for
 * an interrupt, handle it) *)
val idle : (unit -> unit) ref

(* round robin over the slots, forever (xv6's scheduler) *)
val scheduler : unit -> 'a
