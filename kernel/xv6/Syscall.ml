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

(* the user's word at [addr], inside [0, sz) *)
let fetchint (p : proc) addr =
  if addr < 0 || addr >= p.sz || addr + 4 > p.sz then None
  else match Mmu.read p.pgdir addr 4 with Some s -> Some (Machine.get_le32 s 0) | None -> None

(* the user's string at [addr], its NUL before sz *)
let fetchstr (p : proc) addr =
  let b = Buffer.create 64 in
  let rec go va =
    if va >= p.sz then None
    else
      let n = min (Mmu.pgsize - (va land (Mmu.pgsize - 1))) (p.sz - va) in
      match Mmu.read p.pgdir va n with
      | None -> None
      | Some s ->
          (try Buffer.add_string b (String.sub s 0 (String.index s '\000')); Some (Buffer.contents b)
           with Not_found -> Buffer.add_string b s; go (va + n)) in
  if addr < 0 then None else go addr

(* the [n]th argument: a word of the user's stack, the usys.S stub's
 * copy of r0-r3 *)
let argint p n = fetchint p (Machine.tf_get 13 + (4 * n))

(* a pointer to [size] bytes of the user's *)
let argptr (p : proc) n size =
  match argint p n with
  | Some a when a >= 0 && a < p.sz && a + size <= p.sz -> Some a
  | _ -> None

let argstr p n = match argint p n with Some a -> fetchstr p a | None -> None

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
                   killed = false; ofile = Array.map (function Some f -> Some (File.dup f) | None -> None) p.ofile;
                   cwd = Fs.idup p.cwd; name = p.name };
          Machine.proc_context slot;
          pid

(* the files closed, the children given to init, the parent woken: a
 * zombie, its memory and kernel stack freed by the parent's wait *)
let exit (p : proc) =
  if p.pid = 1 then Machine.panic "init exiting";
  Array.iteri (fun fd o -> match o with Some f -> File.close f; p.ofile.(fd) <- None | None -> ()) p.ofile;
  Fs.iput p.cwd;
  Proc.wakeup (Child_of p.parent);
  List.iter (fun (c : proc) ->
    if c.parent = p.pid then begin
      c.parent <- 1;
      if c.state = Zombie then Proc.wakeup (Child_of 1)
    end) (Proc.all ());
  p.state <- Zombie;
  Proc.sched ();
  ignore (Machine.panic "zombie exit")

let wait (p : proc) =
  let rec loop () =
    let kids = List.filter (fun (c : proc) -> c.parent = p.pid) (Proc.all ()) in
    match List.filter (fun (c : proc) -> c.state = Zombie) kids with
    | c :: _ ->
        Mmu.free c.pgdir;
        Machine.proc_free c.slot;
        Proc.procs.(c.slot) <- None;
        c.pid
    | [] ->
        if kids = [] || p.killed then -1
        else begin Proc.sleep (Child_of p.pid); loop () end in
  loop ()

(* the old size; the new pages zeroed, the old ones freed *)
let sbrk (p : proc) n =
  let addr = p.sz in
  let r =
    if n > 0 then match Mmu.alloc p.pgdir p.sz (p.sz + n) with
      | Some sz -> p.sz <- sz; addr
      | None -> -1
    else begin
      if n < 0 && p.sz + n >= 0 then p.sz <- Mmu.dealloc p.pgdir p.sz (p.sz + n);
      addr
    end in
  Machine.mmu_switch p.pgdir;
  r

let sleep (p : proc) n =
  let t0 = !Proc.ticks in
  let rec go () =
    if !Proc.ticks - t0 >= n then 0
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
  let kind = if Fs.itype ip = Devnode then Device (ip, Fs.get ip Fs.i_major) else Inode_file ip in
  match File.alloc kind (omode land o_wronly = 0) (omode land (o_wronly lor o_rdwr) <> 0) with
  | None -> Fs.iput ip; -1
  | Some f ->
      match fdalloc p f with
      | None -> File.close f; -1
      | Some fd ->
          if omode land o_trunc <> 0 && Fs.itype ip = File then Fs.itrunc ip;
          fd

(* xv6 reads and writes the user's memory in place; here a string
 * crosses. A negative count is refused (xv6's depends on the file) *)
let read p =
  argfd p 0 >>= fun (_, f) -> argint p 2 >>= fun n -> argptr p 1 n >>= fun a ->
  if n < 0 then -1
  else File.read f n >>= fun s -> ignore (Mmu.write p.pgdir a s); String.length s

let write p =
  argfd p 0 >>= fun (_, f) -> argint p 2 >>= fun n -> argptr p 1 n >>= fun a ->
  if n < 0 then -1 else Mmu.read p.pgdir a n >>= fun s -> File.write f s

let fstat p =
  argfd p 0 >>= fun (_, f) -> argptr p 1 24 >>= fun st ->
  File.inode f >>= fun ip ->
  ignore (Mmu.write p.pgdir st (Fs.stat_head ip));
  ignore (Mmu.write p.pgdir (st + 16) (Fs.stat_size ip));
  0

let pipe p =
  argptr p 0 8 >>= fun a ->
  File.pipe () >>= fun (rf, wf) ->
  match fdalloc p rf with
  | None -> File.close rf; File.close wf; -1
  | Some fd0 ->
      match fdalloc p wf with
      | None -> p.ofile.(fd0) <- None; File.close rf; File.close wf; -1
      | Some fd1 -> ignore (Mmu.write p.pgdir a (Machine.le32 fd0 ^ Machine.le32 fd1)); 0

let chdir (p : proc) path =
  Fs.namei path >>= fun ip ->
  if Fs.itype ip <> Dir then begin Fs.iput ip; -1 end
  else begin Fs.iput p.cwd; p.cwd <- ip; 0 end

(* the arguments: MAXARG pointers at most, the last 0 *)
let exec p =
  argstr p 0 >>= fun path -> argint p 1 >>= fun uargv ->
  let rec args i acc =
    if i >= maxarg then None
    else match fetchint p (uargv + (4 * i)) with
      | None -> None
      | Some 0 -> Some (List.rev acc)
      | Some a -> (match fetchstr p a with Some s -> args (i + 1) (s :: acc) | None -> None) in
  args 0 [] >>= fun argv -> Exec.exec path argv

(*****************************************************************************)
(* The dispatch *)
(*****************************************************************************)

let call p c =
  match c with
  | Fork -> fork p
  | Exit -> exit p; 0
  | Wait -> wait p
  | Pipe -> pipe p
  | Read -> read p
  | Kill -> argint p 0 >>= Proc.kill
  | Exec -> exec p
  | Fstat -> fstat p
  | Chdir -> argstr p 0 >>= chdir p
  | Dup -> argfd p 0 >>= fun (_, f) -> fdalloc p f >>= fun fd -> ignore (File.dup f); fd
  | Getpid -> p.pid
  | Sbrk -> argint p 0 >>= sbrk p
  | Sleep -> argint p 0 >>= sleep p
  | Uptime -> !Proc.ticks
  | Open -> argstr p 0 >>= fun path -> argint p 1 >>= open_ p path
  | Write -> write p
  | Mknod ->
      argstr p 0 >>= fun path -> argint p 1 >>= fun major -> argint p 2 >>= fun minor ->
      Fs.create path Devnode major minor >>= fun ip -> Fs.iput ip; 0
  | Unlink -> argstr p 0 >>= Fs.unlink
  | Link -> argstr p 0 >>= fun old -> argstr p 1 >>= fun new_ -> Fs.link old new_
  | Mkdir -> argstr p 0 >>= fun path -> Fs.create path Dir 0 0 >>= fun ip -> Fs.iput ip; 0
  | Close -> argfd p 0 >>= fun (fd, f) -> p.ofile.(fd) <- None; File.close f; 0

(* the number in r0, the result back in r0; but a successful exec's,
 * which leaves argc there *)
let syscall (p : proc) =
  let n = Machine.tf_get 0 in
  match decode n with
  | Some Exec -> if call p Exec = -1 then Machine.tf_set 0 (-1)
  | Some c -> Machine.tf_set 0 (call p c)
  | None ->
      Machine.print (Printf.sprintf "%d %s: unknown sys call %d\n" p.pid p.name n);
      Machine.tf_set 0 (-1)
