(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Main.mli *)

open Types

(*****************************************************************************)
(* The devices *)
(*****************************************************************************)

(* the clock: a tick every 10ms, the sleepers woken *)
let tick_us = 10000

let tick () =
  Machine.timer_arm tick_us;
  incr Proc.ticks;
  Proc.wakeup Ticks

(* what is pending, handled (the UART's input drained: its interrupt
 * ends with it); whether the timer was *)
let devices () =
  let t = Machine.timer_pending () in
  if t then tick ();
  let rec uart () = let c = Machine.uart_getc () in if c >= 0 then begin File.intr c; uart () end in
  uart ();
  t

(*****************************************************************************)
(* The traps (trap.c) *)
(*****************************************************************************)

(* an exception escaping the kernel is its bug *)
let guard where f =
  try f () with e -> ignore (Machine.panic ("an exception in " ^ where ^ ": " ^ Printexc.to_string e))

(* a killed process dies on its way back to user mode *)
let check_killed p = if p.killed then Syscall.exit p (-1)

let trap () =
  guard "a system call" (fun () ->
    let p = Proc.myproc () in
    check_killed p;
    Syscall.syscall p;
    check_killed p)

(* a user's interrupt: the devices, then the CPU given up on a tick *)
let irq () =
  guard "an interrupt" (fun () ->
    let p = Proc.myproc () in
    let t = devices () in
    check_killed p;
    if t then Proc.yield ();
    check_killed p)

(* a user's fault (runtime.c's user_fault): the process killed, with
 * xv6-multiarch's arm64 message: the exception class, the syndrome, the
 * pc, the fault's address, each an xv6 %p (0x and 16 digits: the
 * board's C formats the last three, a machine word) *)
let fault ec ((esr : string), (elr : string), (far : string)) =
  guard "a fault" (fun () ->
    let p = Proc.myproc () in
    Machine.print (Printf.sprintf "usertrap(): unexpected ec 0x%016x %s pid=%d\n            elr=%s far=%s\n"
                     ec esr p.pid elr far);
    p.killed <- true;
    check_killed p)

(* a new process's first run: into user mode, but init's, which first
 * runs /init (xv6's initcode, done by the kernel) *)
let process_start (_ : int) =
  guard "a process's start" (fun () ->
    let p = Proc.myproc () in
    if p.pid = 1 then begin
      let argc = Exec.exec "/init" [ "/init" ] in
      if argc < 0 then ignore (Machine.panic "exec /init");
      Machine.tf_set 0 argc
    end;
    Machine.user_resume ())

(*****************************************************************************)
(* The boot *)
(*****************************************************************************)

let () =
  Callback.register "trap" trap;
  Callback.register "irq" irq;
  Callback.register "fault" fault;
  Callback.register "process_start" process_start;
  Machine.print "mini-xv6\n";
  Proc.idle := (fun () -> Machine.wait_interrupt (); ignore (devices ()));
  Machine.timer_arm tick_us;
  Machine.uart_rx_enable ();
  (* init: slot 0, an empty space, the root as its directory *)
  let pgdir = match Mmu.create () with Some d -> d | None -> Machine.panic "no memory" in
  Machine.tf_init 0;
  Proc.procs.(0) <-
    Some { pid = 1; slot = 0; state = Runnable; pgdir = pgdir; sz = 0; parent = 0; killed = false;
           xstate = 0; ofile = Array.make Syscall.nofile None; cwd = Fs.iget Fs.rootino; name = "initcode" };
  Proc.nextpid := 2;
  Machine.proc_context 0;
  Proc.scheduler ()
