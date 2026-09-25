(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny machine of our own: TinyLibCPU.ml's CPU with what a kernel
 * needs around it, designed as its instructions were. TinyCPU.ml runs
 * the CPU as a user program runs, its system calls answered by the
 * host; here nothing answers them but a program the machine runs, a
 * kernel, in the same assembly:
 *
 *     tiny-machine kernel.tm prog.tm...           assembled, linked, run
 *     tiny-machine -o kernel.img kernel.tm prog.tm...   the same, to an image
 *     tiny-machine kernel.img                     the image loaded and run
 *     tiny-machine -l kernel.img                  the listing (or of .tm's)
 *
 * The link is TinyLibCPU's: the files one after the other, their
 * labels one namespace, so a kernel's table names its programs; the
 * kernel first, at 0. An image is the memory's first bytes, as they are
 * at the start: no header, since the machine always starts at 0 in
 * supervisor mode (the Pi's kernel.img, loaded at 0x8000 by its
 * firmware, is the same idea). Files named .tm are assembly, another
 * an image. tiny-os/ is an OS for it, by versions: v0/ a kernel and its
 * programs, and a Makefile that links and runs them (./tiny-machine,
 * at the top of ix, too).
 *
 * The machine, what the CPU lacked to run a kernel:
 *
 * - {b Two modes}, supervisor and user, a bit of [status]. The machine
 *   starts in supervisor mode at 0.
 * - {b One way in, one way out.} A trap saves the pc in [epc], the
 *   reason in [cause] (1 sys, 2 an illegal word, 3 a fault, 4 the
 *   timer), what goes with it in [tval] (the call's number, the word,
 *   the address), the mode and the interrupts' bit in [status]; it
 *   enters supervisor mode with interrupts off and jumps to [tvec].
 *   [eret] undoes it: the mode and the interrupts' bit back, the pc at
 *   [epc]. epc is where to resume: past a sys, on a faulting
 *   instruction, on the instruction an interrupt came before.
 * - {b Registers of control}, read by [csrr d, name] and written by
 *   [csrw name, a]: status epc cause tval tvec time timecmp base
 *   bound. time counts the instructions (the time is the program's
 *   alone, so every run is the same); the timer interrupts when time
 *   reaches timecmp and interrupts are on. csrr, csrw and eret are
 *   illegal in user mode.
 * - {b Protection by a window.} In user mode an address must be in
 *   [base, bound), the fetch's too, or it is a fault. No relocation:
 *   a user program is assembled where it runs; what a window buys is
 *   that a program can harm only itself (RISC-V's PMP, the 360's
 *   storage keys, without pages).
 * - {b Two devices at the top of memory}, reached from anywhere by a
 *   negative offset from r0: a store to -16(r0) writes a byte to the
 *   console, a store to -12(r0) halts the machine, the value its exit
 *   status. They are outside any window a kernel gives, so only it
 *   reaches them.
 *
 * What tiny-os v6 (xv6's kind of kernel) adds, each kept apart so that
 * v0 runs as it did (plan_tiny_os.md, phase 2):
 *
 * - {b 16 MB}, the devices still at the top (-16(r0) the console).
 * - {b Pages}, Sv32 (RISC-V's 32-bit scheme, xv6's): satp's top bit
 *   turns them on, the window off; a fault's address in tval.
 * - {b amoswap d, a, (b)}, the atomic swap a spinlock is made of, in
 *   either mode; {b hartid}, the core's number (0: one core, for now).
 * - {b Interrupts by source}: ip (pending) and ie (enabled), a bit
 *   each; the timer's is the first, enabled at the start as v0 wants;
 *   an interrupt's cause is 4, its sources in tval.
 * - {b The console's input} at -8(r0), and its interrupt; {b a disk}
 *   (-d image), 1 KB blocks moved at once, and its interrupt.
 *
 * The CPU's hooks carry all of it (TinyLibCPU's [env]): the fetch, the
 * load and the store go through the pages or the window and find the
 * devices; sys raises a trap; a word the CPU does not know is csrr,
 * csrw or eret, in supervisor mode, or amoswap, or a trap. The loop
 * around [step] adds the rest: the time, the interrupts.
 *
 * The tests: TinyMachine_test.sh runs tiny-os/v0/kernel.tm, a page of
 * kernel, with its four user programs (two printing, one executing
 * csrw, one storing into the kernel), on a long and a short timer
 * period: every letter printed, the two faults caught, the printing
 * interleaved by the short period and not by the long one.
 *
 * References: the RISC-V privileged specification (from memory): the
 * trap registers, their names, mret; Wirth and Gutknecht, Project
 * Oberon (from memory): a machine and its system designed together;
 * Nisan and Schocken, The Elements of Computing Systems (Hack):
 * devices as memory. *)

(*****************************************************************************)
(* The registers of control, and the traps *)
(*****************************************************************************)

let status = 0 and epc = 1 and cause = 2 and tval = 3 and tvec = 4 and time = 5 and timecmp = 6 and base = 7 and bound = 8
(* v6's (plan_tiny_os.md): the core's number, the interrupts pending
 * and enabled (a bit per source), the pages' root *)
and hartid = 9 and ip = 10 and ie_csr = 11 and satp = 12
let csr_names = [| "status"; "epc"; "cause"; "tval"; "tvec"; "time"; "timecmp"; "base"; "bound"; "hartid"; "ip"; "ie"; "satp" |]
let read_only k = k = time || k = hartid || k = ip

(* status: the mode, the interrupts' bit, and the two as they were
 * before the trap *)
let supervisor_bit = 1 and ie = 2 and ps = 4 and pie = 8

(* an interrupt's cause is 4, its sources in tval: the bits of ip and
 * ie, the timer's the first (v0's only one) *)
let c_sys = 1 and c_illegal = 2 and c_fault = 3 and c_intr = 4
let i_timer = 1 and i_console = 2 and i_disk = 4

(* the devices, at the top of memory, reached from anywhere by a
 * negative offset from r0: the console's output -16(r0), the halt
 * -12(r0); v6's in the 32 bytes below the top *)
let memsize = 1 lsl 24
let console = memsize - 16 and halt = memsize - 12 and devices = memsize - 32
let console_in = memsize - 8
let disk_block = memsize - 32 and disk_addr = memsize - 28 and disk_cmd = memsize - 24 and disk_status = memsize - 20

exception Trap of int * int                (* cause, tval *)
exception Halt of int

(*****************************************************************************)
(* The devices (v6's): the console's input, a disk *)
(*****************************************************************************)

(* The console's input: -8(r0) gives the next byte, 0xffffffff when none
 * has come, 0xfffffffe at the input's end; its interrupt while bytes
 * wait. Nothing is read before a kernel asks (enables the interrupt or
 * reads the register): v0 never does. The input's end interrupts
 * too, once, until it is read. Then a file or a pipe is read
 * whole, so that a run is the same every time; a terminal is polled,
 * as a person types when they type. *)
type console = { mutable queue : string; mutable next : int; mutable eof : bool; mutable opened : bool; mutable eof_read : bool }

let tty = lazy (Unix.isatty Unix.stdin)

let console_open (caps : < Cap.stdin; .. >) k =
  if not k.opened then begin
    k.opened <- true;
    if not (Lazy.force tty) then (let (_ : < Cap.stdin; .. >) = caps in k.queue <- In_channel.input_all stdin; k.eof <- true)
  end

(* a terminal's bytes, when some are there *)
let console_poll k =
  if k.opened && not k.eof && k.next >= String.length k.queue && Lazy.force tty then
    match Unix.select [ Unix.stdin ] [] [] 0.0 with
    | [], _, _ -> ()
    | _ ->
        let b = Bytes.create 256 in
        let n = Unix.read Unix.stdin b 0 256 in
        if n = 0 then k.eof <- true else (k.queue <- Bytes.sub_string b 0 n; k.next <- 0)

let console_read k =
  if k.next < String.length k.queue then (k.next <- k.next + 1; Char.code k.queue.[k.next - 1])
  else if k.eof then (k.eof_read <- true; 0xfffffffe) else 0xffffffff

let console_waiting k = k.next < String.length k.queue || (k.eof && not k.eof_read)

(* The disk: an image file (-d), in blocks of 1 KB. The kernel writes a
 * block's number at -32(r0), a physical address at -28(r0), then the
 * command at -24(r0), 1 to read the block into memory, 2 to write it
 * from memory; the transfer is done at once, and the disk's interrupt
 * waits until the kernel writes -20(r0) (which reads 1 while it does).
 * The image is written back when the machine halts. *)
let bsize = 1024

type disk = { image : Bytes.t; mutable block : int; mutable addr : int; mutable done_ : bool; mutable dirty : bool }

let disk_command d (m : TinyLibCPU.machine) cmd =
  let off = d.block * bsize in
  if off + bsize > Bytes.length d.image || d.addr + bsize > memsize then TinyLibCPU.error "disk: block %d, address 0x%x: out of the image or the memory" d.block d.addr;
  (match cmd with
   | 1 -> Bytes.blit d.image off m.mem d.addr bsize
   | 2 -> Bytes.blit m.mem d.addr d.image off bsize; d.dirty <- true
   | _ -> TinyLibCPU.error "disk: command %d" cmd);
  d.done_ <- true

type machine = { cpu : TinyLibCPU.machine; csr : int array; cons : console; disk : disk }

(* the sources wanting an interrupt *)
let pending mc =
  (if mc.csr.(time) >= mc.csr.(timecmp) then i_timer else 0)
  lor (if console_waiting mc.cons then i_console else 0)
  lor (if mc.disk.done_ then i_disk else 0)

let supervisor mc = mc.csr.(status) land supervisor_bit <> 0

let trap mc cause_v tval_v epc_v =
  let c = mc.csr and st = mc.csr.(status) in
  c.(epc) <- epc_v; c.(cause) <- cause_v; c.(tval) <- tval_v;
  c.(status) <- supervisor_bit lor (if st land supervisor_bit <> 0 then ps else 0) lor (if st land ie <> 0 then pie else 0);
  mc.cpu.pc <- TinyLibCPU.addr c.(tvec)

(*****************************************************************************)
(* The CPU's hooks: the window, the devices, the new instructions *)
(*****************************************************************************)

let check mc a =
  let a = TinyLibCPU.addr a in
  if not (supervisor mc) && (a < mc.csr.(base) || a >= mc.csr.(bound)) then raise (Trap (c_fault, a));
  a

(* Pages (v6's): Sv32, RISC-V's 32-bit scheme, xv6's vm.c's. With satp's
 * top bit set, an address is 10 bits of the root table's index, 10 of
 * a table's, 12 in the page; an entry is a page's number above 10 bits
 * of flags: V R W X U. A table's entry has none of R W X (no large
 * pages); a page's needs V and the access's R, W or X, and U in user
 * mode (the supervisor reaches every page: xv6's copyin walks the
 * tables anyway). Else a fault, the address in tval. Off (satp's top
 * bit clear), the window, as v0 has it. The pc stays below the
 * memory's size (the CPU keeps it modulo), so the virtual addresses a
 * program runs at do too. *)
type access = Read | Write | Exec

let translate mc (m : TinyLibCPU.machine) access va =
  let sat = mc.csr.(satp) in
  if sat land 0x80000000 = 0 then check mc va
  else begin
    let va = TinyLibCPU.m32 va in
    let fault () = raise (Trap (c_fault, va)) in
    let entry at = if at >= memsize then fault (); TinyLibCPU.load m TinyLibCPU.W at in
    let e1 = entry (((sat land 0x3fffff) lsl 12) + (4 * (va lsr 22))) in
    if e1 land 1 = 0 || e1 land 14 <> 0 then fault ();
    let e0 = entry (((e1 lsr 10) lsl 12) + (4 * ((va lsr 12) land 0x3ff))) in
    let needed = match access with Read -> 2 | Write -> 4 | Exec -> 8 in
    if e0 land 1 = 0 || e0 land needed = 0 || (not (supervisor mc) && e0 land 16 = 0) then fault ();
    let pa = ((e0 lsr 10) lsl 12) lor (va land 0xfff) in
    if pa >= memsize then fault ();
    pa
  end

(* a load and a store: the pages or the window, then memory or a device *)
let load caps mc m s a =
  let a = translate mc m Read a in
  match TinyLibCPU.word a with
  | w when w = console_in -> console_open caps mc.cons; console_read mc.cons
  | w when w = disk_status -> if mc.disk.done_ then 1 else 0
  | w when w >= devices -> 0
  | _ -> TinyLibCPU.load m s a

let store caps mc m s a v =
  let a = translate mc m Write a in
  match TinyLibCPU.word a with
  | w when w = console -> Console.print caps (String.make 1 (Char.chr (v land 0xff))); flush stdout
  | w when w = halt -> raise (Halt (v land 0xff))
  | w when w = disk_block -> mc.disk.block <- v
  | w when w = disk_addr -> mc.disk.addr <- v
  | w when w = disk_cmd -> disk_command mc.disk m v
  | w when w = disk_status -> mc.disk.done_ <- false
  | w when w >= devices -> ()
  | _ -> TinyLibCPU.store m s a v

(* the words the CPU does not know: 0x3a-0x3c, csrr, csrw and eret,
 * the supervisor's; 0x3d, amoswap d, a, (b), anyone's: d the word at
 * the address in b, which becomes a, in one instruction (the atomic
 * swap a spinlock is made of, RISC-V's amoswap.w, ARM's swp) *)
let extra caps mc (m : TinyLibCPU.machine) w =
  let op = (w lsr 24) land 0xff and d = (w lsr 20) land 15 and a = (w lsr 16) land 15 and k = w land 0xffff in
  let c = mc.csr and next () = m.pc <- TinyLibCPU.addr (m.pc + 4) in
  if op = 0x3d then begin
    let at = m.r.(k land 15) in
    let old = load caps mc m TinyLibCPU.W at in
    store caps mc m TinyLibCPU.W at m.r.(a);
    if d <> 0 then m.r.(d) <- old;
    next ()
  end
  else begin
    if not (supervisor mc) || op < 0x3a || op > 0x3c || (op < 0x3c && k >= Array.length csr_names) then raise (Trap (c_illegal, w));
    match op with
    | 0x3a -> if d <> 0 then m.r.(d) <- (if k = ip then pending mc else c.(k)); next ()
    | 0x3b ->
        if not (read_only k) then c.(k) <- m.r.(a);
        if k = ie_csr && c.(k) land i_console <> 0 then console_open caps mc.cons;
        next ()
    | _ ->
        let st = c.(status) in
        c.(status) <- (if st land ps <> 0 then supervisor_bit else 0) lor (if st land pie <> 0 then ie else 0);
        m.pc <- TinyLibCPU.addr c.(epc)
  end

let env (caps : < Cap.stdin; Cap.stdout; .. >) mc : TinyLibCPU.env = {
  fetch = (fun m pc -> TinyLibCPU.load m TinyLibCPU.W (translate mc m Exec pc));
  load = load caps mc;
  store = store caps mc;
  sys = (fun _ n -> raise (Trap (c_sys, n)));
  illegal = extra caps mc;
}

(* the assembler's and the listing's new instructions *)
let ext : TinyLibCPU.extension =
  let csr s =
    match List.assoc_opt (String.trim s) (List.mapi (fun k n -> n, k) (Array.to_list csr_names)) with
    | Some k -> k | None -> TinyLibCPU.error "not a register of control: %s" s in
  let w op d a k = TinyLibCPU.Words (4, fun _ _ -> [ (op lsl 24) lor (d lsl 20) lor (a lsl 16) lor k ]) in
  {
    parse = (fun name args ->
      match name, args with
      | "csrr", [ d; c ] -> Some (w 0x3a (TinyLibCPU.reg d) 0 (csr c))
      | "csrw", [ c; a ] -> Some (w 0x3b 0 (TinyLibCPU.reg a) (csr c))
      | "eret", [] -> Some (w 0x3c 0 0 0)
      | "amoswap", [ d; a; b ] ->
          let b = String.trim b in
          if String.length b < 2 || b.[0] <> '(' || b.[String.length b - 1] <> ')' then TinyLibCPU.error "amoswap's address: (rN)";
          Some (w 0x3d (TinyLibCPU.reg d) (TinyLibCPU.reg a) (TinyLibCPU.reg (String.sub b 1 (String.length b - 2))))
      | _ -> None);
    show = (fun w ->
      let op = (w lsr 24) land 0xff and d = (w lsr 20) land 15 and a = (w lsr 16) land 15 and k = w land 0xffff in
      match op with
      | 0x3a when k < Array.length csr_names -> Some (Printf.sprintf "csrr\tr%d, %s" d csr_names.(k))
      | 0x3b when k < Array.length csr_names -> Some (Printf.sprintf "csrw\t%s, r%d" csr_names.(k) a)
      | 0x3c -> Some "eret"
      | 0x3d -> Some (Printf.sprintf "amoswap\tr%d, r%d, (r%d)" d a (k land 15))
      | _ -> None);
  }

(*****************************************************************************)
(* The loop: the time, the interrupt, a step *)
(*****************************************************************************)

let run caps ?disk_file image =
  let m = TinyLibCPU.boot image in
  m.r.(TinyLibCPU.sp) <- devices;
  let c = Array.make (Array.length csr_names) 0 in
  c.(status) <- supervisor_bit;
  c.(timecmp) <- 0xffffffff;
  c.(ie_csr) <- i_timer;
  let disk_image = match disk_file with Some f -> Bytes.of_string (Files.read caps (Fpath.v f)) | None -> Bytes.empty in
  let mc = { cpu = m; csr = c; cons = { queue = ""; next = 0; eof = false; opened = false; eof_read = false };
             disk = { image = disk_image; block = 0; addr = 0; done_ = false; dirty = false } } in
  let env = env caps mc in
  let halted n =
    (match disk_file with Some f when mc.disk.dirty -> Files.write caps (Fpath.v f) (Bytes.to_string mc.disk.image) | _ -> ());
    n in
  try
    while true do
      let pc = m.pc in
      c.(time) <- TinyLibCPU.m32 (c.(time) + 1);
      if c.(time) land 1023 = 0 then console_poll mc.cons;
      try
        let wanted = pending mc land c.(ie_csr) in
        if c.(status) land ie <> 0 && wanted <> 0 then trap mc c_intr wanted pc
        else TinyLibCPU.step env m
      with Trap (cause_v, tval_v) -> trap mc cause_v tval_v (if cause_v = c_sys then TinyLibCPU.addr (pc + 4) else pc)
    done;
    0
  with Halt n -> halted n

let main (caps : < Cap.stdin; Cap.stdout; Cap.stderr; Cap.argv; Cap.open_in; Cap.open_out; .. >) =
  let args = List.tl (Array.to_list (CapSys.argv caps)) in
  TinyLibCPU.memsize := memsize;
  let image files =
    if files = [] || (List.hd files).[0] = '-' then raise Exit;
    TinyLibCPU.image ~ext (List.map (fun f -> f, Files.read caps (Fpath.v f)) files) in
  try
    match args with
    | "-l" :: files -> Console.print caps (TinyLibCPU.listing ~ext (image files)); 0
    | "-o" :: out :: files -> Files.write caps (Fpath.v out) (image files); 0
    | "-d" :: disk :: files -> run caps ~disk_file:disk (image files)
    | files -> run caps (image files)
  with
  | Exit -> Console.eprint caps "usage: tiny-machine [-l | -o image | -d disk] kernel.tm [program.tm...] | image\n"; 2
  | TinyLibCPU.Error e | Sys_error e -> Console.eprint caps ("tiny-machine: " ^ e ^ "\n"); 1

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
