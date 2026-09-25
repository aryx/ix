(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* mini-xv6, step 4 (plan_kernel.md): the MMU. Each process has its own
 * address space, xv6 arm-pi1's: its program at 0, a guard page, its
 * stack, everything below 1GB through its own translation table
 * (TTBR0); the kernel above, the same in all (TTBR1, start.s). What the
 * kernel does with a process's memory, it does through that table: it
 * copies the program into fresh pages and maps them, it reads a system
 * call's buffer only where the process could, and a fault (a page not
 * mapped, the kernel's memory) kills the process instead of the
 * machine.
 *
 * Addresses as ints: a user's (below 1GB) and a physical one (below
 * 512MB), both fitting OCaml's 31 bits on the Pi1; the kernel's own
 * (0x80000000 and up) stay in C (machine.c) -- but for a fault's
 * address, which may be one, and comes as an Int32. *)

(*****************************************************************************)
(* The machine (machine.c) *)
(*****************************************************************************)

module Phys = struct
  external get8 : int -> int = "phys_get8"
  external set8 : int -> int -> unit = "phys_set8"
  external get32 : int -> int = "phys_get32"
  external set32 : int -> int -> unit = "phys_set32"
  external zero : int -> int -> unit = "phys_zero"
end

external uart_putc : int -> unit = "uart_putc"
external halt : unit -> unit = "machine_halt"
external tf_get : int -> int = "tf_get"
external tf_set : int -> int -> unit = "tf_set"
external mmu_switch : int -> unit = "mmu_switch"
external image_size : unit -> int = "image_size"
external image_copy : int -> int -> int -> unit = "image_copy"
external user_resume : unit -> unit = "user_resume"
external proc_init : int -> int -> int -> unit = "proc_init"
external swtch : int -> unit = "k_swtch"
external current : unit -> int = "k_current"

let print s = for i = 0 to String.length s - 1 do uart_putc (Char.code s.[i]) done

(*****************************************************************************)
(* Page table entries: ARMv6's short descriptors, as records *)
(*****************************************************************************)

(* the kernel uses a few kinds only: a user's first level holds coarse
 * tables (256 entries, 1MB each), their entries small pages (4KB) *)
type perm = Kernel_rw | User_ro | User_rw

type l1 = L1_fault | Coarse of int                     (* the table's physical address *)
type page = { pa : int; perm : perm; xn : bool }
type l2 = L2_fault | Page of page

(* the bits: a coarse table 01 and its address (domain 0); a small page
 * 1x, XN in bit 0, AP in bits 5-4 (01 the kernel's, 10 the user
 * reading, 11 the user writing; APX, bit 9, 0) *)
let encode_l1 = function L1_fault -> 0 | Coarse t -> t lor 1
let decode_l1 e = if e land 3 = 1 then Coarse (e land lnot 0x3ff) else L1_fault

let ap = function Kernel_rw -> 1 | User_ro -> 2 | User_rw -> 3

let encode_l2 = function
  | L2_fault -> 0
  | Page pg -> pg.pa lor (ap pg.perm lsl 4) lor 2 lor (if pg.xn then 1 else 0)

let decode_l2 e =
  if e land 2 = 0 then L2_fault
  else Page { pa = e land lnot 0xfff; perm = (match (e lsr 4) land 3 with 1 -> Kernel_rw | 2 -> User_ro | _ -> User_rw);
              xn = e land 1 = 1 }

(*****************************************************************************)
(* Physical pages *)
(*****************************************************************************)

(* the processes' pages: the RAM from 256MB (the OCaml heap's end) to
 * 448MB (the end of the kernel's mapping), as a list of addresses *)
let pgsize = 4096
let free_pages = ref []
let () =
  let rec fill pa = if pa >= 0x10000000 then begin free_pages := pa :: !free_pages; fill (pa - pgsize) end in
  fill (0x1c000000 - pgsize)

exception Out_of_memory_pages

let kalloc () =
  match !free_pages with
  | [] -> raise Out_of_memory_pages
  | pa :: rest -> free_pages := rest; Phys.zero pa pgsize; pa

let kfree pa = free_pages := pa :: !free_pages

(*****************************************************************************)
(* Address spaces *)
(*****************************************************************************)

(* a user's table: 1024 first-level entries (TTBCR N = 2: the addresses
 * below 1GB), a page; a coarse table in a page of its own (its first
 * KB: simple, not frugal). The user's addresses are the ints from 0:
 * 1GB itself, 0x40000000, is not one (OCaml's largest on the Pi1 is
 * 0x3fffffff; written as a bound, it wrapped to min_int and every
 * address looked out of range) *)
let user_mbs = 1024

let l1_entry pgdir va = pgdir + (4 * (va lsr 20))

(* the second-level entry's address for [va], its table made if [alloc] *)
let walk pgdir va alloc =
  match decode_l1 (Phys.get32 (l1_entry pgdir va)) with
  | Coarse t -> Some (t + (4 * ((va lsr 12) land 0xff)))
  | L1_fault when alloc ->
      let t = kalloc () in
      Phys.set32 (l1_entry pgdir va) (encode_l1 (Coarse t));
      Some (t + (4 * ((va lsr 12) land 0xff)))
  | L1_fault -> None

let map pgdir va pa perm =
  match walk pgdir va true with
  | Some e -> Phys.set32 e (encode_l2 (Page { pa = pa; perm = perm; xn = false }))
  | None -> assert false

(* the physical address of a user's byte, if the user may touch it *)
let user_pa pgdir va =
  if va < 0 then None
  else match walk pgdir va false with
    | None -> None
    | Some e ->
        (match decode_l2 (Phys.get32 e) with
         | Page pg when pg.perm <> Kernel_rw -> Some (pg.pa + (va land (pgsize - 1)))
         | _ -> None)

(* a user's bytes, or None when one is not the user's (xv6's copyin) *)
let copyin pgdir va n =
  let b = Bytes.create n in
  let rec go i = if i = n then Some (Bytes.to_string b)
    else match user_pa pgdir (va + i) with
      | Some pa -> Bytes.set b i (Char.chr (Phys.get8 pa)); go (i + 1)
      | None -> None in
  go 0

(* every page and table of a user's space freed, then the table *)
let free_space pgdir =
  for i = 0 to user_mbs - 1 do
    match decode_l1 (Phys.get32 (pgdir + (4 * i))) with
    | Coarse t ->
        for j = 0 to 255 do
          match decode_l2 (Phys.get32 (t + (4 * j))) with Page pg -> kfree pg.pa | L2_fault -> ()
        done;
        kfree t
    | L1_fault -> ()
  done;
  kfree pgdir

(* a process's space made from the program's image: its pages at 0, a
 * guard page (not mapped: a stack overflowing faults), the stack; the
 * stack pointer at its top (xv6's exec, without the ELF yet) *)
let load_image () =
  let pgdir = kalloc () in
  let size = image_size () in
  let npages = (size + pgsize - 1) / pgsize in
  for k = 0 to npages - 1 do
    let pa = kalloc () in
    image_copy pa (k * pgsize) (min pgsize (size - (k * pgsize)));
    map pgdir (k * pgsize) pa User_rw
  done;
  let stack = (npages + 1) * pgsize in
  map pgdir stack (kalloc ()) User_rw;
  pgdir, stack + pgsize

(*****************************************************************************)
(* The processes *)
(*****************************************************************************)

type state = Runnable | Running | Zombie of int

type proc = { pid : int; slot : int; mutable state : state; pgdir : int }

let nproc = 8
let scheduler_slot = nproc
let procs : proc option array = Array.make nproc None

let myproc () = match procs.(current ()) with Some p -> p | None -> failwith "myproc: the scheduler"

let sched () = swtch scheduler_slot

(* round robin; a process's table in TTBR0 while it runs, none else *)
let scheduler () =
  let rec loop () =
    let ran = ref false in
    Array.iter (function
      | Some p when p.state = Runnable ->
          ran := true;
          p.state <- Running;
          mmu_switch p.pgdir;
          swtch p.slot;
          mmu_switch 0
      | _ -> ()) procs;
    if !ran then loop () in
  loop ();
  print (Printf.sprintf "mini-xv6: no process left to run; %d pages free\n" (List.length !free_pages));
  halt ()

(* the end of a process: its space freed, never to run again *)
let exit_proc p status =
  p.state <- Zombie status;
  mmu_switch 0;
  free_space p.pgdir;
  sched ()

(*****************************************************************************)
(* The system calls, the faults *)
(*****************************************************************************)

(* an argument: a word of the user's stack, through its table *)
let arg p n =
  match copyin p.pgdir (tf_get 13 + (4 * n)) 4 with
  | Some s -> Char.code s.[0] lor (Char.code s.[1] lsl 8) lor (Char.code s.[2] lsl 16) lor (Char.code s.[3] lsl 24)
  | None -> -1

let sys_exit = 2
let sys_getpid = 11
let sys_sleep = 13
let sys_write = 16

let syscall () =
  let p = myproc () in
  let n = tf_get 0 in
  if n = sys_write then begin
    let fd = arg p 0 and buf = arg p 1 and len = arg p 2 in
    if fd <> 1 && fd <> 2 then -1
    else match copyin p.pgdir buf len with
      | Some s -> print s; len
      | None -> -1
  end
  else if n = sys_getpid then p.pid
  else if n = sys_sleep then begin
    (* no timer yet: the CPU given up [n] times *)
    for _k = 1 to max 1 (arg p 0) do p.state <- Runnable; sched () done;
    0
  end
  else if n = sys_exit then begin
    let status = arg p 0 in
    print (Printf.sprintf "mini-xv6: process %d exited, status %d\n" p.pid status);
    exit_proc p status;
    0
  end
  else begin
    print (Printf.sprintf "mini-xv6: process %d: unknown system call %d\n" p.pid n);
    -1
  end

let trap () =
  try tf_set 0 (syscall ())
  with e ->
    print ("mini-xv6: an exception in a trap: " ^ Printexc.to_string e ^ "\n");
    halt ()

(* a user's fault (machine.c's user_fault): the process killed, as xv6
 * kills one; the fault's address (an Int32: it may be the kernel's) and
 * its status (the FSR's low bits: 5 a section's translation, 7 a
 * page's, 13 a section's permission, 15 a page's) *)
let fault kind (far : Int32.t) fsr =
  let p = myproc () in
  (* the pc: the abort's lr, 8 after the instruction (4 for a prefetch) *)
  let pc = tf_get 15 - (if kind = 3 then 8 else 4) in
  print (Printf.sprintf "mini-xv6: process %d killed: %s at 0x%s, pc 0x%x, status 0x%x\n" p.pid
           (if kind = 3 then "data abort" else "prefetch abort") (Int32.format "%08x" far) pc (fsr land 0xf));
  exit_proc p (-1)

let process_start (_ : int) = user_resume ()

let () =
  Callback.register "trap" trap;
  Callback.register "fault" fault;
  Callback.register "process_start" process_start;
  print (Printf.sprintf "mini-xv6: step 4, the MMU on; %d pages free\n" (List.length !free_pages));
  for i = 0 to 2 do
    let pgdir, sp = load_image () in
    proc_init i 0 sp;
    procs.(i) <- Some { pid = i + 1; slot = i; state = Runnable; pgdir = pgdir }
  done;
  scheduler ()
