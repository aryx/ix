(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny Raspberry Pi 1, in one file: the smallest machine a kernel
 * can run on, and one a bare-metal program for the real board runs on
 * too. mini-qemu (raspberry/) is QEMU's raspi1ap, faithfully: every
 * device 9pi and xv6 touch, the MMU, USB, the framebuffer. This is
 * what is left when the kernel is one we write: TinyArm's CPU
 * (tiny/TinyLibArm.ml) with what a kernel sees below the system call.
 *
 *   $ tiny-pi TinyPi_tests/tick.s
 *   TinyPi: a kernel, in SVC mode
 *   user: hello, from user mode
 *   undefined instruction, skipped
 *   ...
 *
 * What a machine adds to a CPU, and nothing else:
 *
 * - {b Modes.} USR (the programs), SVC (the kernel, and the reset),
 *   IRQ (an interrupt), UND (an undefined instruction), SYS (the
 *   kernel with the user's registers). Each but SYS has its own r13
 *   and r14, swapped in when the mode is entered: the stack and the
 *   return address of the code that was interrupted survive. The
 *   CPSR: the flags (TinyLibArm's), the I and F masks, the mode; each
 *   exception mode's SPSR keeps the CPSR it interrupted.
 * - {b Exceptions.} An svc, an undefined word, an interrupt: the CPSR
 *   saved in the new mode's SPSR, the return address in its r14, IRQs
 *   masked, the pc at the vector (0x4 undefined, 0x8 svc, 0x18 IRQ).
 *   Back with `movs pc, lr` or `subs pc, lr, #4`: a data-processing
 *   instruction writing the pc with the s suffix copies SPSR back to
 *   CPSR, the mode, the masks and the flags at once.
 * - {b The instructions of the privileged modes}, which the CPU's
 *   subset leaves out: mrs, msr (register and immediate, CPSR or
 *   SPSR, by fields), cpsie and cpsid (the masks), wfi (wait for an
 *   interrupt). TinyPi runs them itself, before the CPU's [step] sees
 *   the word; its assembler writes them as `.word`s for the CPU's.
 * - {b An interrupt between two instructions}: when a device's line is
 *   up, the controller lets it through, and I is clear.
 * - {b Three devices at the Pi1's addresses} (0x20000000 and up), each
 *   a few registers, behind the CPU's load and store: the PL011 UART
 *   (+0x201000: DR written, a character out; FR, never full), the
 *   system timer (+0x3000: a 1 MHz counter, four compares, a match
 *   bit each, cleared by writing it), the interrupt controller
 *   (+0xb200: the timers' pendings, enables, disables).
 * - {b Time from instructions}: [ips] instructions a simulated
 *   microsecond (default 30, mini-qemu's); a WFI with nothing pending
 *   jumps to the next compare. With IRQs masked, a WFI can never wake:
 *   the machine has halted, and tiny-pi exits.
 *
 * The program is loaded at 0x8000 and entered in SVC with I and F
 * masked, as the Pi1's firmware starts kernel.img and QEMU's loader a
 * raw image (-device loader,addr=0x8000); its vectors are its own to
 * copy to 0. The memory is TinyLibArm's 16MB from 0.
 *
 * Left out, against mini-qemu's Pi1: the MMU and CP15 (the CPU fetches
 * from physical memory), FIQ, the abort modes (a bad address stops
 * tiny-pi), the UART's input and its interrupts, the mailbox, the
 * framebuffer, USB, the SD card, DMA. Exercises: the UART's receive
 * interrupt and a shell; a second timer; a sections-only MMU (a fetch
 * hook in TinyLibArm first); FIQ with its banked r8-r12.
 *
 * The tests: TinyPi_test.sh assembles TinyPi_tests/*.s with GNU as and
 * with this, the bytes the same; runs each here, under mini-qemu and
 * under QEMU (raspi1ap), the console the same; and checks its laws:
 * the interrupts counted, the simulated time when it halts.
 *
 * References: ARM Architecture Reference Manual, ARMv6 (from memory):
 * the modes, the banked registers, the exceptions' entry and return,
 * MRS, MSR, CPS; the BCM2835 ARM Peripherals document (from memory,
 * checked against mini-qemu's raspberry/, itself checked against QEMU
 * and 9pi) for the three devices. *)

module A = TinyLibArm

(*****************************************************************************)
(* The machine *)
(*****************************************************************************)

let usr = 0x10 and irq = 0x12 and svc = 0x13 and und = 0x1b      (* and SYS, 0x1f *)

(* the banked r13 and r14: USR and SYS share theirs *)
let bank mode = if mode = irq then 1 else if mode = svc then 2 else if mode = und then 3 else 0

type t = {
  m : A.machine;
  mutable mode : int;
  mutable i_off : bool;                (* IRQs masked *)
  mutable f_off : bool;
  banked : (int * int) array;          (* r13, r14 of the modes not current *)
  spsr : int array;
  (* the devices *)
  out : char -> unit;
  mutable cs : int;                    (* the timer's match bits *)
  compare : int array;
  mutable enable : int;                (* the controller's enables, bank 1 *)
  (* the time *)
  ips : int;
  mutable instructions : int;
  mutable skipped : int;               (* microseconds jumped by WFIs *)
  mutable waiting : bool;
  mutable interrupts : int;
}

let create ~out ~ips =
  { m = A.create (); mode = svc; i_off = true; f_off = true; banked = Array.make 4 (0, 0); spsr = Array.make 4 0;
    out; cs = 0; compare = Array.make 4 0; enable = 0;
    ips; instructions = 0; skipped = 0; waiting = false; interrupts = 0 }

let now t = (t.instructions / t.ips) + t.skipped
let clo t = now t land 0xffffffff

let cpsr t =
  let b f k = if f then 1 lsl k else 0 in
  b t.m.n 31 lor b t.m.z 30 lor b t.m.c 29 lor b t.m.v 28 lor b t.i_off 7 lor b t.f_off 6 lor t.mode

(* a mode entered: r13 and r14 swapped with its bank *)
let set_mode t mode =
  if bank mode <> bank t.mode then begin
    t.banked.(bank t.mode) <- (t.m.r.(13), t.m.r.(14));
    let sp, lr = t.banked.(bank mode) in
    t.m.r.(13) <- sp; t.m.r.(14) <- lr
  end;
  t.mode <- mode

(* a CPSR written, by fields: bit 0 the control byte (mode, masks),
 * bit 3 the flags; USR changes only the flags *)
let write_cpsr t v mask =
  if mask land 8 <> 0 then begin
    let b k = (v lsr k) land 1 = 1 in
    t.m.n <- b 31; t.m.z <- b 30; t.m.c <- b 29; t.m.v <- b 28
  end;
  if mask land 1 <> 0 && t.mode <> usr then begin
    t.i_off <- (v lsr 7) land 1 = 1; t.f_off <- (v lsr 6) land 1 = 1;
    set_mode t (v land 0x1f)
  end

(* an exception: the CPSR in the mode's SPSR, the return address in its
 * r14, IRQs masked, the pc at the vector *)
let take t ~mode ~ret ~vector =
  let saved = cpsr t in
  set_mode t mode;
  t.spsr.(bank mode) <- saved;
  t.m.r.(14) <- ret;
  t.i_off <- true;
  t.m.r.(15) <- vector

(*****************************************************************************)
(* The devices *)
(*****************************************************************************)

let io = 0x20000000
let uart = io + 0x201000 and timer = io + 0x3000 and intc = io + 0xb200

(* the timers' lines: a match bit, to the controller's IRQs 0-3 *)
let pending t = t.cs land t.enable

let read t a =
  if a = uart + 0x18 then 0x90                                   (* FR: transmit empty, receive empty *)
  else if a = timer then t.cs
  else if a = timer + 4 then clo t
  else if a = timer + 8 then (now t lsr 32) land 0xffffffff
  else if a >= timer + 0xc && a < timer + 0x1c then t.compare.((a - timer - 0xc) / 4)
  else if a = intc then (if pending t <> 0 then 1 lsl 8 else 0)  (* basic pending: bank 1 has some *)
  else if a = intc + 4 then pending t
  else if a = intc + 0x10 then t.enable
  else 0

let write t a v =
  if a = uart then t.out (Char.chr (v land 0xff))
  else if a = timer then t.cs <- t.cs land lnot v                (* the match bits written to clear *)
  else if a >= timer + 0xc && a < timer + 0x1c then t.compare.((a - timer - 0xc) / 4) <- v
  else if a = intc + 0x10 then t.enable <- t.enable lor v
  else if a = intc + 0x1c then t.enable <- t.enable land lnot v

(* time moved from [before] to now: the compares passed set their bits *)
let tick t before =
  let after = now t in
  if after <> before then
    Array.iteri (fun k c ->
      let d = (c - before) land 0xffffffff in
      if d > 0 && d <= after - before then t.cs <- t.cs lor (1 lsl k)) t.compare

(* the microseconds to the next compare *)
let until_next t =
  let n = now t in
  Array.fold_left (fun acc c -> let d = (c - n) land 0xffffffff in if d > 0 then min acc d else acc) max_int t.compare

(*****************************************************************************)
(* Running *)
(*****************************************************************************)

exception Halted

let env t = {
  A.load = (fun m byte a -> if a >= io then read t a else if byte then A.load8 m a else A.load32 m a);
  store = (fun m byte a v -> if a >= io then write t a v else if byte then A.store8 m a v else A.store32 m a v);
  svc = (fun m _ -> take t ~mode:svc ~ret:m.r.(15) ~vector:0x8);
  undefined = (fun m _ -> take t ~mode:und ~ret:(m.r.(15) + 4) ~vector:0x4);
}

(* the privileged instructions (condition always), TinyPi's own: true
 * when the word was one *)
let privileged t w =
  let m = t.m in
  let r = m.r and next () = m.r.(15) <- m.r.(15) + 4 in
  let spsr_bit = (w lsr 22) land 1 = 1 in
  let msr v =
    let mask = (w lsr 16) land 15 in
    if spsr_bit then (if bank t.mode <> 0 then t.spsr.(bank t.mode) <- v) else write_cpsr t v mask in
  if w land 0xffbf0fff = 0xe10f0000 then begin          (* mrs rd, cpsr|spsr *)
    r.((w lsr 12) land 15) <- (if spsr_bit then t.spsr.(bank t.mode) else cpsr t); next (); true
  end
  else if w land 0xffb0fff0 = 0xe120f000 then (msr r.(w land 15); next (); true)     (* msr psr, rm *)
  else if w = 0xe320f003 then (t.waiting <- true; next (); true)                     (* wfi *)
  else if w land 0xffb0f000 = 0xe320f000 && (w lsr 16) land 15 <> 0 then begin      (* msr psr, #imm *)
    msr (A.ror (w land 0xff) (2 * ((w lsr 8) land 15))); next (); true
  end
  else if w land 0xfff1fe3f = 0xf1000000 && (w lsr 18) land 2 = 2 then begin        (* cpsie, cpsid *)
    let off = (w lsr 18) land 1 = 1 in
    if t.mode <> usr then begin
      if w land 0x80 <> 0 then t.i_off <- off;
      if w land 0x40 <> 0 then t.f_off <- off
    end;
    next (); true
  end
  else false

(* movs pc, lr and the like: a data-processing word with s writing the
 * pc (not tst, teq, cmp, cmn), in a mode with an SPSR *)
let exception_return t w =
  w lsr 28 = 0xe && (w lsr 26) land 3 = 0 && (w lsr 20) land 1 = 1 && (w lsr 12) land 15 = 15
  && ((w lsr 21) land 15 < 8 || (w lsr 21) land 15 > 11) && bank t.mode <> 0

(* one instruction, or an interrupt taken, or the time to the next
 * event when waiting *)
let step t =
  let before = now t in
  if pending t <> 0 && not t.i_off then begin
    t.waiting <- false;
    t.interrupts <- t.interrupts + 1;
    take t ~mode:irq ~ret:(t.m.r.(15) + 4) ~vector:0x18
  end
  else if t.waiting then begin
    if t.i_off && pending t = 0 then raise Halted;
    if pending t = 0 then t.skipped <- t.skipped + max 1 (min (until_next t) 1_000_000);
    if t.i_off then t.waiting <- false
  end
  else begin
    let w = A.load32 t.m t.m.r.(15) in
    if not (privileged t w) then begin
      let back = exception_return t w in
      let saved = if back then t.spsr.(bank t.mode) else 0 in
      A.step (env t) t.m;
      if back then write_cpsr t saved 9
    end;
    t.instructions <- t.instructions + 1
  end;
  tick t before

(*****************************************************************************)
(* The assembler: the privileged instructions as words *)
(*****************************************************************************)

let origin = 0x8000

(* mrs, msr, cpsie, cpsid, wfi, which TinyLibArm's assembler does not
 * know, rewritten as .word lines; the rest of the line as it was *)
let privileged_line line =
  let code = match String.index_opt line '@' with Some i -> String.sub line 0 i | None -> line in
  let code = String.trim code in
  (* the labels first *)
  let rec labels s acc = match String.index_opt s ':' with
    | Some i when not (String.contains (String.sub s 0 i) ' ') -> labels (String.trim (String.sub s (i + 1) (String.length s - i - 1))) (acc ^ String.sub s 0 (i + 1) ^ " ")
    | _ -> acc, s in
  let prefix, ins = labels code "" in
  let word, args = match String.index_opt ins ' ' with
    | Some i -> String.lowercase_ascii (String.sub ins 0 i), List.map String.trim (String.split_on_char ',' (String.sub ins i (String.length ins - i)))
    | None -> String.lowercase_ascii ins, [] in
  let psr s =
    let s = String.lowercase_ascii s in
    let r = if String.length s >= 4 && String.sub s 0 4 = "spsr" then 1 lsl 22 else 0 in
    let fields = if String.length s > 5 then String.sub s 5 (String.length s - 5) else "fc" in
    let mask = String.fold_left (fun acc ch -> acc lor match ch with 'c' -> 1 | 'x' -> 2 | 's' -> 4 | 'f' -> 8 | _ -> A.error "bad psr field in %s" s) 0 fields in
    r lor (mask lsl 16) in
  let masks s = String.fold_left (fun acc ch -> acc lor match ch with 'i' -> 0x80 | 'f' -> 0x40 | 'a' -> 0x100 | _ -> A.error "bad mask %s" s) 0 s in
  let word_of = match word, args with
    | "mrs", [ rd; p ] -> Some (0xe10f0000 lor (psr p land (1 lsl 22)) lor (A.reg rd lsl 12))
    | "msr", [ p; v ] when String.length v > 0 && v.[0] = '#' ->
        let n = int_of_string (String.trim (String.sub v 1 (String.length v - 1))) in
        (match A.rotated n with
         | Some (rot, imm) -> Some (0xe320f000 lor psr p lor (rot lsl 8) lor imm)
         | None -> A.error "msr: #%d not an immediate" n)
    | "msr", [ p; rm ] -> Some (0xe120f000 lor psr p lor A.reg rm)
    | "cpsie", [ f ] -> Some (0xf1080000 lor masks f)
    | "cpsid", [ f ] -> Some (0xf10c0000 lor masks f)
    | "wfi", [] -> Some 0xe320f003
    | _ -> None in
  match word_of with Some w -> Printf.sprintf "%s.word 0x%08x" prefix w | None -> line

let assemble lines = A.assemble ~origin (List.map privileged_line lines)

(*****************************************************************************)
(* The command line *)
(*****************************************************************************)

let usage = "usage: tiny-pi [-ips N] [-s] file.s|kernel.img  |  tiny-pi -o kernel.img file.s"

let main (caps : < Cap.argv; Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr; .. >) =
  let args = List.tl (Array.to_list (CapSys.argv caps)) in
  let read f = Files.read caps (Fpath.v f) in
  let image f = if Filename.check_suffix f ".s" then (let i, _, _ = assemble (String.split_on_char '\n' (read f)) in i) else read f in
  let rec opts ips stats = function
    | "-ips" :: n :: rest -> opts (int_of_string n) stats rest
    | "-s" :: rest -> opts ips true rest
    | rest -> ips, stats, rest in
  try
    match opts 30 false args with
    | _, _, [ "-o"; out; file ] -> Files.write caps (Fpath.v out) (image file); 0
    | ips, stats, [ file ] when file.[0] <> '-' ->
        let t = create ~out:(fun c -> Console.print caps (String.make 1 c); flush stdout) ~ips in
        let img = image file in
        Bytes.blit_string img 0 t.m.mem origin (String.length img);
        t.m.r.(15) <- origin;
        (try while true do step t done with Halted -> ());
        if stats then
          Console.eprint caps (Printf.sprintf "tiny-pi: halted after %d instructions, %d interrupts, at %d us\n" t.instructions t.interrupts (now t));
        0
    | _ -> Console.eprint caps (usage ^ "\n"); 2
  with A.Error e | Sys_error e | Failure e -> Console.eprint caps ("tiny-pi: " ^ e ^ "\n"); 1

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
