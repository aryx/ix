(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* mini-xv6, step 3 (plan_kernel.md): processes, each on its own kernel
 * stack. xv6's structure in small: a process table, a scheduler on the
 * boot stack switching to each runnable process in turn (swtch), and a
 * process giving the CPU back from inside a system call (sched), its
 * kernel stack keeping the frames of the call in progress until it
 * runs again.
 *
 * What it checks: that the collector sees the stacks of the processes
 * that do not run (machine.c's scan_stacks). Before each switch, a
 * process makes young values that only its kernel stack holds; while
 * it sleeps, the scheduler allocates and forces a minor and a major
 * collection, which move those values out of the minor heap; when it
 * resumes, it checks them. A stack the collector missed would find its
 * values moved and freed, not intact. *)

(*****************************************************************************)
(* The machine (machine.c) *)
(*****************************************************************************)

module Mem = struct
  external get8 : int -> int = "mem_get8"
  external get32 : int -> int = "mem_get32"
  external set32 : int -> int -> unit = "mem_set32"
end

external uart_putc : int -> unit = "uart_putc"
external halt : unit -> unit = "machine_halt"
external trapframe_addr : unit -> int = "trapframe_addr"
external user_resume : unit -> unit = "user_resume"
external user_entry : unit -> int = "user_entry"
external user_stack : int -> int = "user_stack"
external proc_init : int -> int -> int -> unit = "proc_init"
external swtch : int -> unit = "k_swtch"
external current : unit -> int = "k_current"

let print s = for i = 0 to String.length s - 1 do uart_putc (Char.code s.[i]) done

(* the running process's trap frame: r0-r12, sp, lr, pc, CPSR *)
module Trapframe = struct
  let r n = Mem.get32 (trapframe_addr () + (4 * n))
  let set_r n v = Mem.set32 (trapframe_addr () + (4 * n)) v
  let sp () = r 13
end

(*****************************************************************************)
(* The processes *)
(*****************************************************************************)

type state = Runnable | Running | Zombie of int

type proc = { pid : int; slot : int; mutable state : state; mutable intact : int }

let nproc = 8
let scheduler_slot = nproc
let procs : proc option array = Array.make nproc None

let myproc () = match procs.(current ()) with Some p -> p | None -> failwith "myproc: the scheduler"

(* back to the scheduler, from inside a system call (xv6's sched) *)
let sched () = swtch scheduler_slot

(* between two switches the scheduler allocates, then collects: the
 * sleeping processes' values move *)
let rec upto i acc = if i < 0 then acc else upto (i - 1) (i :: acc)

let churn () =
  let rec junk n acc = if n = 0 then acc else junk (n - 1) (string_of_int n :: acc) in
  ignore (junk 3000 []);
  Gc.minor ();
  Gc.full_major ()

(* round robin over the slots until none is runnable (xv6's scheduler) *)
let scheduler () =
  let rec loop () =
    let ran = ref false in
    Array.iter (function
      | Some p when p.state = Runnable ->
          ran := true;
          p.state <- Running;
          churn ();
          swtch p.slot
      | _ -> ()) procs;
    if !ran then loop () in
  loop ();
  print "mini-xv6: no process left to run\n";
  halt ()

(*****************************************************************************)
(* The system calls *)
(*****************************************************************************)

let arg n = Mem.get32 (Trapframe.sp () + (4 * n))

let sys_exit = 2
let sys_getpid = 11
let sys_sleep = 13
let sys_write = 16

(* sleep: no timer yet, so the CPU given up [n] times; around each
 * switch, the young values only this stack holds, checked after *)
let sleep p n =
  for _k = 1 to max 1 n do
    let numbers = List.map (fun x -> x * p.pid) (upto 49 []) in
    let name = Printf.sprintf "the witness of process %d" p.pid in
    p.state <- Runnable;
    sched ();
    let sum = List.fold_left ( + ) 0 numbers in
    if sum = 1225 * p.pid && name = Printf.sprintf "the witness of process %d" p.pid then p.intact <- p.intact + 1
    else print (Printf.sprintf "mini-xv6: process %d's values lost across a switch (%d)\n" p.pid sum)
  done;
  0

let syscall () =
  let p = myproc () in
  let n = Trapframe.r 0 in
  if n = sys_write then begin
    let fd = arg 0 and buf = arg 1 and len = arg 2 in
    if fd <> 1 && fd <> 2 then -1
    else begin
      for i = 0 to len - 1 do uart_putc (Mem.get8 (buf + i)) done;
      len
    end
  end
  else if n = sys_getpid then p.pid
  else if n = sys_sleep then sleep p (arg 0)
  else if n = sys_exit then begin
    let status = arg 0 in
    print (Printf.sprintf "mini-xv6: process %d exited, status %d; its values intact across %d switches\n" p.pid status p.intact);
    p.state <- Zombie status;
    sched ();
    0
  end
  else begin
    print (Printf.sprintf "mini-xv6: unknown system call %d\n" n);
    -1
  end

(* the trap, from machine.c: an exception must not escape into C *)
let trap () =
  try Trapframe.set_r 0 (syscall ())
  with e ->
    print ("mini-xv6: an exception in a trap: " ^ Printexc.to_string e ^ "\n");
    halt ()

(* a process's first run, from machine.c's trampoline on its new kernel
 * stack: to user mode (its trap frame set by proc_init) *)
let process_start (_ : int) = user_resume ()

let () =
  Callback.register "trap" trap;
  Callback.register "process_start" process_start;
  print "mini-xv6: step 3, three processes on their own kernel stacks\n";
  for i = 0 to 2 do
    proc_init i (user_entry ()) (user_stack i);
    procs.(i) <- Some { pid = i + 1; slot = i; state = Runnable; intact = 0 }
  done;
  scheduler ()
