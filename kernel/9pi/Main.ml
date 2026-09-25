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

(* the first program and its arguments (stage A's; /boot/boot at C) *)
let boot = [ "/boot/echo"; "hello" ]

(*****************************************************************************)
(* The devices *)
(*****************************************************************************)

(* the clock: a tick every 10ms (HZ 100) *)
let tick_us = 10000

let devices () =
  let t = Machine.timer_pending () in
  if t then Machine.timer_arm tick_us;
  let rec uart () = let c = Machine.uart_getc () in if c >= 0 then begin Devcons.intr c; uart () end in
  uart ();
  t

(*****************************************************************************)
(* The traps *)
(*****************************************************************************)

let guard where f =
  try f () with e -> ignore (Machine.panic ("an exception in " ^ where ^ ": " ^ Printexc.to_string e))

let trap () = guard "a system call" (fun () -> Syscall.syscall (Proc.myproc ()))

let irq () =
  guard "an interrupt" (fun () ->
    if devices () then Proc.yield ())

(* a user's fault: the process dies (Plan 9's "suicide" note, its
 * handlers not yet: stage B) *)
let fault (_ : int) ((_ : string), (pc : string), (addr : string)) =
  guard "a fault" (fun () ->
    let p = Proc.myproc () in
    Devcons.print (Printf.sprintf "%s %d: suicide: sys: trap: fault pc=%s addr=%s\n" p.text p.pid pc addr);
    Syscall.exits p "sys: trap: fault")

(* a new process's first run: the boot process's initcode, then user
 * mode *)
let process_start (_ : int) =
  guard "a process's start" (fun () ->
    let p = Proc.myproc () in
    if p.pid = 1 then begin
      let cons m = ignore (Chan.fdalloc p (let c = Chan.namec p "#c/cons" in Chan.open_ c (Chan.mode_of_int m); c)) in
      cons 0; cons 1; cons 1;
      let r = try Exec.exec p (List.hd boot) boot with Error e -> Machine.panic ("exec " ^ List.hd boot ^ ": " ^ e) in
      Exec.set_tos_pid p;
      Machine.tf_set 0 r
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
  Devcons.print "mini-9pi\n";
  Devroot.init ();
  Devcons.init ();
  Proc.idle := (fun () -> Machine.wait_interrupt (); ignore (devices ()));
  Machine.timer_arm tick_us;
  Machine.uart_rx_enable ();
  let slash = (Dev.find '/').Dev.attach "" in
  slash.cname <- "/";
  Machine.tf_init 0;
  Proc.procs.(0) <-
    Some { pid = 1; slot = 0; state = Runnable; parent = 0; pgdir = 0; segs = [];
           fgrp = { fds = Array.make Syscall.nfd None }; slash = slash;
           dot = { dev = slash.dev; qid = slash.qid; offset = 0; opened = None; cname = "/" };
           errstr = ""; text = "*init*"; exitstr = "" };
  Proc.nextpid := 2;
  Machine.proc_context 0;
  Proc.scheduler ()
