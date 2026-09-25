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

let nofile = 16
let maxarg = 32
let maxpath = 128

(*****************************************************************************)
(* The calls (syscall.h) *)
(*****************************************************************************)

type call =
  | Fork | Exit | Wait | Pipe | Read | Kill | Exec | Fstat | Chdir | Dup | Getpid
  | Sbrk | Sleep | Uptime | Open | Write | Mknod | Unlink | Link | Mkdir | Close

let decode = function
  | 1 -> Some Fork | 2 -> Some Exit | 3 -> Some Wait | 4 -> Some Pipe | 5 -> Some Read
  | 6 -> Some Kill | 7 -> Some Exec | 8 -> Some Fstat | 9 -> Some Chdir | 10 -> Some Dup
  | 11 -> Some Getpid | 12 -> Some Sbrk | 13 -> Some Sleep | 14 -> Some Uptime | 15 -> Some Open
  | 16 -> Some Write | 17 -> Some Mknod | 18 -> Some Unlink | 19 -> Some Link | 20 -> Some Mkdir
  | 21 -> Some Close
  | _ -> None

(*****************************************************************************)
(* The arguments (syscall.c) *)
(*****************************************************************************)

(* an argument missing or wrong: the call returns -1 *)
let ( >>= ) o f = match o with Some x -> f x | None -> -1

(* the [n]th argument, raw: a register, or a word of the user's stack
 * (Arch.args_on_stack) *)
let argraw (p : proc) n =
  if not Arch.args_on_stack then Some (Machine.tf_get n)
  else match Mmu.read p.pgdir (Machine.tf_get Arch.tf_sp + (Arch.word * n)) Arch.word with
    | Some s -> Some (Arch.get_word s 0)
    | None -> None

let argint p n = match argraw p n with Some v -> Some (Arch.c_int v) | None -> None
let argaddr = argraw

(* a user's word at [addr], inside [0, sz) (fetchaddr) *)
let fetchaddr (p : proc) addr =
  if addr < 0 || addr >= p.sz || addr + Arch.word > p.sz then None
  else match Mmu.read p.pgdir addr Arch.word with Some s -> Some (Arch.get_word s 0) | None -> None

(* a user's string, its NUL within [max] bytes, through the user's pages
 * (copyinstr: no bound but those) *)
let fetchstr (p : proc) max addr = Mmu.read_string p.pgdir addr max

let argstr p n max = match argaddr p n with Some a -> fetchstr p max a | None -> None

(* a file descriptor, and its file *)
let argfd (p : proc) n =
  match argint p n with
  | Some fd when fd >= 0 && fd < nofile -> (match p.ofile.(fd) with Some f -> Some (fd, f) | None -> None)
  | _ -> None

let fdalloc (p : proc) f =
  let rec go fd =
    if fd = nofile then None
    else match p.ofile.(fd) with None -> p.ofile.(fd) <- Some f; Some fd | Some _ -> go (fd + 1) in
  go 0

(* the user's buffer at [addr], as File reads and writes it *)
let dst (p : proc) addr o s = Mmu.copyout p.pgdir (addr + o) s
let src (p : proc) addr o n = Mmu.read p.pgdir (addr + o) n

(*****************************************************************************)
(* Processes (proc.c, sysproc.c) *)
(*****************************************************************************)

let fork (p : proc) =
  match Proc.free_slot () with
  | None -> -1
  | Some slot ->
      let pid = !Proc.nextpid in
      incr Proc.nextpid;
      match Mmu.copy p.pgdir p.sz with
      | None -> -1
      | Some pgdir ->
          Machine.tf_copy slot;
          Proc.procs.(slot) <-
            Some { pid = pid; slot = slot; state = Runnable; pgdir = pgdir; sz = p.sz; parent = p.pid;
                   killed = false; xstate = 0;
                   ofile = Array.map (function Some f -> Some (File.dup f) | None -> None) p.ofile;
                   cwd = Fs.idup p.cwd; name = p.name };
          Machine.proc_context slot;
          pid

(* the files closed, the children given to init, the parent woken: a
 * zombie with its status, its memory and kernel stack freed by the
 * parent's wait *)
let exit (p : proc) status =
  if p.pid = 1 then Machine.panic "init exiting";
  Array.iteri (fun fd o -> match o with Some f -> File.close f; p.ofile.(fd) <- None | None -> ()) p.ofile;
  Fs.iput p.cwd;
  List.iter (fun (c : proc) ->
    if c.parent = p.pid then begin c.parent <- 1; Proc.wakeup (Child_of 1) end) (Proc.all ());
  Proc.wakeup (Child_of p.parent);
  p.xstate <- status;
  p.state <- Zombie;
  Proc.sched ();
  ignore (Machine.panic "zombie exit")

(* a zombie child's pid, its status copied to [addr] (0: not); -1 with
 * no child, killed, or [addr] out of reach (the zombie then left) *)
let wait (p : proc) addr =
  let rec loop () =
    let kids = List.filter (fun (c : proc) -> c.parent = p.pid) (Proc.all ()) in
    match List.filter (fun (c : proc) -> c.state = Zombie) kids with
    | c :: _ ->
        if addr <> 0 && not (Mmu.copyout p.pgdir addr (Machine.le32 c.xstate)) then -1
        else begin
          Mmu.free c.pgdir;
          Machine.proc_free c.slot;
          Proc.procs.(c.slot) <- None;
          c.pid
        end
    | [] ->
        if kids = [] || p.killed then -1
        else begin Proc.sleep (Child_of p.pid); loop () end in
  loop ()

(* the old size; the new pages zeroed, the old ones freed. The size is a
 * C uint (xv6-multiarch's growproc), [sz + n] 32 bits: a new size that
 * wraps below the old one leaves it, as a success (sbrk8000) *)
let sbrk (p : proc) n =
  let addr = p.sz in
  let newsz = Arch.c_uint (p.sz + n) in
  let r =
    if n > 0 then match Mmu.alloc p.pgdir p.sz newsz with
      | Some sz -> p.sz <- sz; addr
      | None -> -1
    else begin
      if n < 0 && newsz >= 0 && newsz < p.sz then p.sz <- Mmu.dealloc p.pgdir p.sz newsz;
      addr
    end in
  Machine.mmu_switch p.pgdir;
  r

(* [n] ticks; a negative [n], a C uint, forever (until killed) *)
let sleep (p : proc) n =
  let t0 = !Proc.ticks in
  let rec go () =
    if n >= 0 && !Proc.ticks - t0 >= n then 0
    else if p.killed then -1
    else begin Proc.sleep Ticks; go () end in
  go ()

(*****************************************************************************)
(* Files (sysfile.c) *)
(*****************************************************************************)

(* fcntl.h *)
let o_wronly = 0x001
let o_rdwr = 0x002
let o_create = 0x200
let o_trunc = 0x400

let open_ (p : proc) path omode =
  let ip =
    if omode land o_create <> 0 then Fs.create path File 0 0
    else match Fs.namei path with
      | Some ip when Fs.itype ip = Dir && omode <> 0 -> Fs.iput ip; None
      | r -> r in
  ip >>= fun ip ->
  let major = Fs.get ip Fs.i_major in
  if Fs.itype ip = Devnode && (major < 0 || major >= 10) then begin Fs.iput ip; -1 end
  else
  let kind = if Fs.itype ip = Devnode then Device (ip, major) else Inode_file ip in
  match File.alloc kind (omode land o_wronly = 0) (omode land (o_wronly lor o_rdwr) <> 0) with
  | None -> Fs.iput ip; -1
  | Some f ->
      match fdalloc p f with
      | None -> File.close f; -1
      | Some fd ->
          if omode land o_trunc <> 0 && Fs.itype ip = File then Fs.itrunc ip;
          fd

let read p =
  argaddr p 1 >>= fun a -> argint p 2 >>= fun n -> argfd p 0 >>= fun (_, f) -> File.read f n (dst p a)

let write p =
  argaddr p 1 >>= fun a -> argint p 2 >>= fun n -> argfd p 0 >>= fun (_, f) -> File.write f n (src p a)

(* struct stat, 24 bytes (its padding zeros) *)
let fstat p =
  argaddr p 1 >>= fun st -> argfd p 0 >>= fun (_, f) ->
  File.inode f >>= fun ip ->
  if Mmu.copyout p.pgdir st (Fs.stat_head ip ^ String.make 4 '\000' ^ Fs.stat_size ip) then 0 else -1

let pipe (p : proc) =
  argaddr p 0 >>= fun a ->
  File.pipe () >>= fun (rf, wf) ->
  match fdalloc p rf with
  | None -> File.close rf; File.close wf; -1
  | Some fd0 ->
      match fdalloc p wf with
      | None -> p.ofile.(fd0) <- None; File.close rf; File.close wf; -1
      | Some fd1 ->
          if Mmu.copyout p.pgdir a (Machine.le32 fd0) && Mmu.copyout p.pgdir (a + 4) (Machine.le32 fd1) then 0
          else begin p.ofile.(fd0) <- None; p.ofile.(fd1) <- None; File.close rf; File.close wf; -1 end

let chdir (p : proc) path =
  Fs.namei path >>= fun ip ->
  if Fs.itype ip <> Dir then begin Fs.iput ip; -1 end
  else begin Fs.iput p.cwd; p.cwd <- ip; 0 end

(* the arguments: MAXARG pointers at most, the last 0; each string's NUL
 * within a page *)
let exec p =
  argstr p 0 maxpath >>= fun path -> argaddr p 1 >>= fun uargv ->
  let rec args i acc =
    if i >= maxarg then None
    else match fetchaddr p (uargv + (Arch.word * i)) with
      | None -> None
      | Some 0 -> Some (List.rev acc)
      | Some a -> (match fetchstr p Mmu.pgsize a with Some s -> args (i + 1) (s :: acc) | None -> None) in
  args 0 [] >>= fun argv -> Exec.exec path argv

(*****************************************************************************)
(* The dispatch *)
(*****************************************************************************)

let call p c =
  match c with
  | Fork -> fork p
  | Exit -> (argint p 0 >>= fun status -> exit p status; 0)
  | Wait -> argaddr p 0 >>= wait p
  | Pipe -> pipe p
  | Read -> read p
  | Kill -> argint p 0 >>= Proc.kill
  | Exec -> exec p
  | Fstat -> fstat p
  | Chdir -> argstr p 0 maxpath >>= chdir p
  | Dup -> argfd p 0 >>= fun (_, f) -> fdalloc p f >>= fun fd -> ignore (File.dup f); fd
  | Getpid -> p.pid
  | Sbrk -> argint p 0 >>= sbrk p
  | Sleep -> argint p 0 >>= sleep p
  | Uptime -> !Proc.ticks
  | Open -> argstr p 0 maxpath >>= fun path -> argint p 1 >>= open_ p path
  | Write -> write p
  | Mknod ->
      argint p 1 >>= fun major -> argint p 2 >>= fun minor -> argstr p 0 maxpath >>= fun path ->
      Fs.create path Devnode major minor >>= fun ip -> Fs.iput ip; 0
  | Unlink -> argstr p 0 maxpath >>= Fs.unlink
  | Link -> argstr p 0 maxpath >>= fun old -> argstr p 1 maxpath >>= fun new_ -> Fs.link old new_
  | Mkdir -> argstr p 0 maxpath >>= fun path -> Fs.create path Dir 0 0 >>= fun ip -> Fs.iput ip; 0
  | Close -> argfd p 0 >>= fun (fd, f) -> p.ofile.(fd) <- None; File.close f; 0

(* the number (Arch.tf_syscall), the result in the first register *)
let syscall (p : proc) =
  let n = Arch.c_int (Machine.tf_get Arch.tf_syscall) in
  match decode n with
  | Some c -> Machine.tf_set 0 (call p c)
  | None ->
      Machine.print (Printf.sprintf "%d %s: unknown sys call %d\n" p.pid p.name n);
      Machine.tf_set 0 (-1)
