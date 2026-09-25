(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Syscall.mli *)

open Types

let nfd = 100
let errmax = 128
let maxpath = 1024

type call =
  | Nop | Rfork | Exec | Exits | Await | Brk | Open | Close | Dup | Fd2path | Pread | Pwrite | Seek
  | Create | Remove | Chdir | Stat | Fstat | Wstat | Fwstat | Bind | Mount | Unmount | Sleep | Alarm
  | Notify | Noted | Pipe | Segattach | Segdetach | Segfree | Segflush | Segbrk
  | Rendezvous | Semacquire | Semrelease | Tsemacquire | Fversion | Fauth | Errstr

(* by number, as sys.h has them *)
let calls = [|
  Nop, "nop"; Rfork, "rfork"; Exec, "exec"; Exits, "exits"; Await, "await"; Brk, "brk";
  Open, "open"; Close, "close"; Dup, "dup"; Fd2path, "fd2path"; Pread, "pread"; Pwrite, "pwrite";
  Seek, "seek"; Create, "create"; Remove, "remove"; Chdir, "chdir"; Stat, "stat"; Fstat, "fstat";
  Wstat, "wstat"; Fwstat, "fwstat"; Bind, "bind"; Mount, "mount"; Unmount, "unmount";
  Sleep, "sleep"; Alarm, "alarm"; Notify, "notify"; Noted, "noted"; Pipe, "pipe";
  Segattach, "segattach"; Segdetach, "segdetach"; Segfree, "segfree"; Segflush, "segflush";
  Segbrk, "segbrk"; Rendezvous, "rendezvous"; Semacquire, "semacquire"; Semrelease, "semrelease";
  Tsemacquire, "tsemacquire"; Fversion, "fversion"; Fauth, "fauth"; Errstr, "errstr" |]

(*****************************************************************************)
(* The user's memory *)
(*****************************************************************************)

let user_string (p : proc) addr max =
  match Mmu.read_string p.pgdir addr max with Some s -> s | None -> raise (Error ebadarg)

let user_read (p : proc) addr n =
  match Mmu.read p.pgdir addr n with Some s -> s | None -> raise (Error ebadarg)

let user_write (p : proc) addr s = if not (Mmu.copyout p.pgdir addr s) then raise (Error ebadarg)

(* a vlong argument (two words, the low first): None for -1 (the
 * channel's own offset); offsets past 1GB are not the Pi1's ints *)
let offset lo hi =
  if lo = -1 && hi = -1 then None
  else if hi < 0 then raise (Error enegoff)
  else if hi > 0 || lo < 0 then raise (Error ebadarg)
  else Some lo

(*****************************************************************************)
(* Processes and memory *)
(*****************************************************************************)

let exits (p : proc) status =
  Array.iteri (fun fd o -> match o with Some c -> Chan.close c; p.fgrp.fds.(fd) <- None | None -> ()) p.fgrp.fds;
  p.exitstr <- status;
  if p.parent = 0 then ignore (Machine.panic ("boot process died: " ^ (if status = "" then "unknown" else status)));
  Machine.mmu_switch 0;
  Mmu.free p.pgdir;
  p.pgdir <- 0;
  p.state <- Zombie;
  Proc.sched ()

let seg (p : proc) kind =
  try List.find (fun s -> s.kind = kind) p.segs with Not_found -> raise (Error ebadarg)

(* ibrk on the bss: its top moved to addr (0: where it starts) *)
let brk (p : proc) addr =
  let s = seg p Bss in
  if addr = 0 then s.base
  else begin
    let addr =
      if addr >= s.base then addr
      else if addr < (seg p Data).base then raise (Error enovmem)
      else s.base in
    let newtop = Mmu.pgroundup addr in
    if newtop < s.top then begin
      ignore (Mmu.dealloc p.pgdir s.top newtop);
      s.top <- newtop
    end else begin
      List.iter (fun ns -> if ns != s && newtop >= ns.base && newtop < ns.top then raise (Error esoverlap)) p.segs;
      (match Mmu.alloc p.pgdir s.top newtop with Some _ -> () | None -> raise (Error enovmem));
      s.top <- newtop
    end;
    0
  end

(*****************************************************************************)
(* Files *)
(*****************************************************************************)

let sysopen (p : proc) name m =
  let c = Chan.namec p name in
  Chan.open_ c (Chan.mode_of_int m);
  try Chan.fdalloc p c with e -> Chan.close c; raise e

let sysclose (p : proc) fd =
  let c = Chan.fdtochan p fd None in
  p.fgrp.fds.(fd) <- None;
  Chan.close c;
  0

let pread (p : proc) fd buf n off =
  if n < 0 then raise (Error ebadarg);
  let c = Chan.fdtochan p fd (Some Oread) in
  let s = (Dev.find c.dev).Dev.read c n (match off with Some o -> o | None -> c.offset) in
  user_write p buf s;
  if off = None then c.offset <- c.offset + String.length s;
  String.length s

let pwrite (p : proc) fd buf n off =
  if n < 0 then raise (Error ebadarg);
  let s = user_read p buf n in
  let c = Chan.fdtochan p fd (Some Owrite) in
  if c.qid.typ = Qt_dir then raise (Error eisdir);
  let m = (Dev.find c.dev).Dev.write c s (match off with Some o -> o | None -> c.offset) in
  if off = None then c.offset <- c.offset + m;
  m

(* errstr: the user's message and the process's swapped *)
let errstr (p : proc) buf n =
  if n <= 0 then raise (Error ebadarg);
  let n = min n errmax in
  let mine = user_read p buf n in
  let mine = try String.sub mine 0 (String.index mine '\000') with Not_found -> String.sub mine 0 (n - 1) in
  let e = if String.length p.errstr >= n then String.sub p.errstr 0 (n - 1) else p.errstr in
  user_write p buf (e ^ "\000");
  p.errstr <- mine;
  0

(*****************************************************************************)
(* The dispatch *)
(*****************************************************************************)

(* argv: the user's array of strings, to its 0 *)
let user_args (p : proc) addr =
  let rec go a acc =
    let v = Arch.get_word (user_read p a 4) 0 in
    if v = 0 then List.rev acc else go (a + 4) (user_string p v maxpath :: acc) in
  go addr []

let call (p : proc) c a =
  match c with
  | Nop -> 0
  | Exec ->
      let name = user_string p a.(0) maxpath in
      let r = Exec.exec p name (user_args p a.(1)) in
      Exec.set_tos_pid p;
      r
  | Exits -> exits p (if a.(0) = 0 then "" else user_string p a.(0) errmax); 0
  | Brk -> brk p a.(0)
  | Open -> sysopen p (user_string p a.(0) maxpath) a.(1)
  | Close -> sysclose p a.(0)
  | Pread -> pread p a.(0) a.(1) a.(2) (offset a.(3) a.(4))
  | Pwrite -> pwrite p a.(0) a.(1) a.(2) (offset a.(3) a.(4))
  | Errstr -> errstr p a.(0) a.(1)
  | _ -> raise (Error "not yet")

let syscall (p : proc) =
  let nr = Machine.tf_get Arch.tf_syscall in
  let ret =
    try
      if nr < 0 || nr >= Array.length calls then raise (Error ebadarg);
      let c, name = calls.(nr) in
      let sp = Machine.tf_get Arch.tf_sp in
      let words = user_read p (sp + 4) 20 in
      let a = Array.init 5 (fun i -> Arch.get_word words (4 * i)) in
      (try call p c a
       with Error "not yet" as e -> Devcons.print ("mini-9pi: " ^ name ^ ": not yet\n"); raise e)
    with Error e ->
      p.errstr <- (if String.length e >= errmax then String.sub e 0 (errmax - 1) else e);
      -1 in
  Machine.tf_set 0 ret
