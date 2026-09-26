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

(* the first program and its arguments: 9pi's *)
let boot = [ "/boot/boot" ]

(*****************************************************************************)
(* The devices *)
(*****************************************************************************)

(* the clock: a tick every 10ms (HZ 100) *)
let tick_us = 10000

let devices () =
  let t = Machine.timer_pending () in
  if t then begin
    Machine.timer_arm tick_us;
    incr Proc.ticks;
    Proc.wakeup Ticks
  end;
  let rec uart () = let c = Machine.uart_getc () in if c >= 0 then begin Devcons.intr c; uart () end in
  uart ();
  t

(*****************************************************************************)
(* The traps *)
(*****************************************************************************)

let guard where f =
  try f () with e -> ignore (Machine.panic ("an exception in " ^ where ^ ": " ^ Printexc.to_string e))

(* a killed process (/proc/n/ctl) ends on its way back to user mode *)
let check_killed p = if p.killed then Syscall.exits p "sys: killed"

let trap () =
  guard "a system call" (fun () ->
    let p = Proc.myproc () in
    Syscall.syscall p;
    check_killed p)

let irq () =
  guard "an interrupt" (fun () ->
    let p = Proc.myproc () in
    if devices () && Proc.preempt_due () then Proc.preempt ();
    check_killed p)

(* a hex string's value (C's "0x%016lx"): its last 8 digits, the top
 * two bits dropped (the Pi1's ints; a user's address is below 1GB) *)
let hex s =
  let t = String.sub s (String.length s - 8) 8 in
  int_of_string ("0x" ^ t) land 0x3fffffff

(* a user's trap (runtime.c's user_fault: the class, the syndrome, the
 * pc, the address): a page fault resolved (Fault), or the note 9pi's
 * trap posts, which kills it (trap.c, faultarm) *)
let fault ec ((esr : string), (pc : string), (addr : string)) =
  guard "a fault" (fun () ->
    let p = Proc.myproc () in
    (* an abort in a segment: its page given, the instruction restarted *)
    if (ec = 0x24 || ec = 0x20) && Fault.fault p (hex addr) then ()
    else
    let msg =
      if ec = 0 then Printf.sprintf "undefined instruction: pc 0x%x\n" (hex pc)
      else Printf.sprintf "sys: trap: fault %s va=0x%x"
             (if ec = 0x24 && hex esr land 0x40 <> 0 then "write" else "read") (hex addr) in
    Syscall.suicide p msg)

(* a new process's first run: the boot process's initcode, then user
 * mode *)
let process_start (_ : int) =
  guard "a process's start" (fun () ->
    let p = Proc.myproc () in
    if p.pid = 1 then begin
      (* initcode's startboot *)
      let cons m = ignore (Chan.fdalloc p (Chan.open_ (Chan.namec p "#c/cons") (Chan.mode_of_int m))) in
      cons 0; cons 1; cons 1;
      let bind n o f = Chan.bind p.pgrp (Chan.clone (Chan.namec p n)) (Chan.namec_nomount p o) f in
      bind "#c" "/dev" Chan.mafter;
      bind "#ec" "/env" Chan.mafter;
      bind "#e" "/env" (Chan.mcreate lor Chan.mafter);
      bind "#s" "/srv" (Chan.mrepl lor Chan.mcreate);
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
  (* devtab's order (9pi's conf: its "reset" lines) *)
  Devroot.init ();
  Devcons.init ();
  Devenv.init ();
  Devproc.init ();
  Devsys.init ();
  Devpipe.init ();
  Devdup.init ();
  Devarch.init ();
  Devmnt.init ();
  Devsrv.init ();
  Devsd.init ();
  Proc.idle := (fun () -> Machine.wait_interrupt (); ignore (devices ()));
  Machine.timer_arm tick_us;
  Machine.uart_rx_enable ();
  let slash = (Dev.find '/').Dev.attach "" in
  slash.cname <- "/";
  Machine.tf_init 0;
  Proc.procs.(0) <-
    Some { pid = 1; slot = 0; state = Runnable; parent = 0; nchild = 0; waitq = []; pgdir = 0; segs = [];
           fgrp = Chan.fgrp_new (); pgrp = { mnt = [] }; egrp = { vars = []; last_path = 0 };
           slash = slash; dot = Chan.clone slash; notify = 0; noteid = 1;
           errstr = ""; text = "*init*"; start = 0; psstate = ""; args = ""; killed = false };
  Proc.nextpid := 2;
  Machine.proc_context 0;
  (match Proc.procs.(0) with Some p -> Proc.ready p | None -> ());
  Proc.scheduler ()
