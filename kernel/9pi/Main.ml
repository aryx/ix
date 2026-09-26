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
    Proc.wakeup Ticks;
    (* swcursor_clock's, to the mouse *)
    Swcursor.clock (Devmouse.xy ());
    (* the alarms due (alarmkproc's) *)
    Array.iter (fun o -> match o with
      | Some p when p.alarm <> 0 && !Proc.ticks >= p.alarm && p.state <> Zombie ->
          p.alarm <- 0; ignore (Proc.postnote p "alarm" Nuser)
      | _ -> ()) Proc.procs
  end;
  let rec uart () = let c = Machine.uart_getc () in if c >= 0 then begin Devcons.intr c; uart () end in
  uart ();
  t

(*****************************************************************************)
(* The traps *)
(*****************************************************************************)

let guard where f =
  try f () with e -> ignore (Machine.panic ("an exception in " ^ where ^ ": " ^ Printexc.to_string e))

(* a system call (its notes delivered on its way back: Syscall) *)
let trap () = guard "a system call" (fun () -> Syscall.syscall (Proc.myproc ()))

let irq () =
  guard "an interrupt" (fun () ->
    let p = Proc.myproc () in
    if devices () && Proc.preempt_due () then Proc.preempt ();
    Syscall.notify p 0x12)

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
    (* an abort in a segment: its page given, the instruction restarted
     * (a note interrupting the page's read: restarted too, the note
     * delivered first) *)
    let typ = if ec = 0 then 0x1b else 0x17 in
    let resolved = (ec = 0x24 || ec = 0x20) && (try Fault.fault p (hex addr) with Error e when e = Proc.eintr -> true) in
    if resolved then Syscall.notify p typ
    else
      Syscall.trap p (if ec = 0 then Printf.sprintf "undefined instruction: pc 0x%x\n" (hex pc)
                      else Printf.sprintf "sys: trap: fault %s va=0x%x"
                             (if ec = 0x24 && hex esr land 0x40 <> 0 then "write" else "read") (hex addr)) typ)

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

(* the boot process's environment, as 9pi's userinit sets it (ksetenv):
 * terminal ("ARM" and its conf file's path, as 9pi's buffer cuts it:
 * the C kernel's value under QEMU), cputype, service, etherargs (QEMU's
 * MAC) *)
let boot_env =
  let v i name value = { ename = name; evalue = value; epath = i; evers = 0 } in
  [ v 1 "terminal" "ARM /home/pad/github/principia-softwarica/kernel/COMPIL"; v 2 "cputype" "arm";
    v 3 "service" "terminal"; v 4 "etherargs" "-a 525400123457" ]

let () =
  Callback.register "trap" trap;
  Callback.register "irq" irq;
  Callback.register "fault" fault;
  Callback.register "process_start" process_start;
  Dev.seconds := (fun () -> !Proc.ticks / 100);
  (* the screen first, the console on it (9pi's screeninit, before its
   * first print) *)
  Swconsole.init ();
  Devmouse.screen := Swconsole.rect ();
  if Swconsole.rect () <> None then Swcursor.init ();
  (* 9pi's banner: its machine's lines as the C kernel prints them under
   * QEMU (mini-9pi does not measure them) *)
  Devcons.print "\nPlan 9 from Bell Labs\nboard rev: 0x900021 firmware rev: 346337\ncpu0: 0MHz ARM 1176JZF-S\n";
  Devcons.print "fp: 16 registers,  no simd\nfp: arm arch VFPv2; rev 5\n";
  (* the devices, in devtab's order (9pi's conf), each reset after its
   * line (chandevreset: a device's own messages after it) *)
  List.iteri (fun i (name, init) -> Devcons.print (Printf.sprintf "reset %d, %s\n" i name); init ())
    [ "root", Devroot.init; "cons", Devcons.init; "env", Devenv.init; "proc", Devproc.init; "sys", Devsys.init;
      "pipe", Devpipe.init; "dup", Devdup.init; "arch", Devarch.init; "mnt", Devmnt.init; "srv", Devsrv.init;
      "draw", Devdraw.init; "mouse", Devmouse.init; "kbin", Devkbin.init; "kbmap", Devstub.kbmap; "sd", Devsd.init;
      "ether", Devstub.ether; "ip", Devstub.ip; "uart", Devstub.uart; "usb", Devusb.init ];
  (* confinit's summary, 9pi's numbers *)
  Devcons.print "448M memory: 91M kernel data, 357M user, 1696M swap\n";
  Proc.idle := (fun () -> Machine.wait_interrupt (); ignore (devices ()));
  Machine.timer_arm tick_us;
  Machine.uart_rx_enable ();
  let slash = (Dev.find '/').Dev.attach "" in
  slash.cname <- "/";
  Machine.tf_init 0;
  Proc.procs.(0) <-
    Some { pid = 1; slot = 0; state = Runnable; parent = 0; nchild = 0; waitq = []; pgdir = 0; segs = [];
           fgrp = Chan.fgrp_new (); pgrp = { mnt = [] }; egrp = { vars = boot_env; last_path = List.length boot_env };
           slash = slash; dot = Chan.clone slash; notify = 0; noteid = 1;
           errstr = ""; text = "*init*"; start = 0; psstate = ""; args = ""; setargs = false;
           notes = []; notepending = false; notified = false; ureg = 0; lastnote = ("", Nuser); alarm = 0;
           rgrp = { rend = [] }; rendtag = 0; rendval = 0 };
  Proc.nextpid := 2;
  Proc.kproc "kgenrandom";
  Proc.kproc "alarm";
  Machine.proc_context 0;
  (match Proc.procs.(0) with Some p -> Proc.ready p | None -> ());
  Proc.scheduler ()
