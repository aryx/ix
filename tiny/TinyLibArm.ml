(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny ARM CPU: an assembler for a subset of arm32, and the
 * interpreter that runs what it assembles. The library of two
 * programs: TinyCPUArm.ml, the CPU run as Linux runs a user program (its
 * system calls answered by the host, and the ELF writer that lets the
 * real CPU run it too); and TinyMachinePi.ml (plan_pi.md), the CPU
 * in the Pi1 with its devices. mini-5i (machine/) is 5i's twin: a
 * decoder for every word the toolchains emit, two architectures,
 * Linux's and Plan 9's system calls. This is what is left when the
 * program run is one we write.
 *
 * Why this and TinyLibCPU.ml, two small CPUs with an assembler each: they
 * teach opposite things. TinyCPU is a machine designed, every choice
 * ours and nothing to check it but its own laws. This one is a machine
 * inherited, its choices made in 1985 and to be met word for word: the
 * rotated immediate, the flags and a condition on every instruction,
 * the literal pool a 32-bit constant needs. Its checks are outside it
 * (GNU as's bytes, objdump's text, the real CPU), and its words are
 * what the rest of ix runs (mini-5i's, the Pi1's). TinyCPU shows what
 * an instruction set could be; this, what a real one asks of its
 * assembler and its interpreter. Neither has devices: a system call is
 * where both stop. Below it are their machines: TinyMachinePi.ml,
 * this CPU with the Pi1's devices (plan_pi.md), and TinyMachine.ml,
 * TinyCPU's, each using its CPU as a library.
 *
 * What makes it small, and still a real machine:
 *
 * - {b One variant, three readers.} An instruction is a value of [instr];
 *   the assembler builds it from text, [encode] makes it a word,
 *   [decode] makes the word a value again, [print] writes it as
 *   objdump does, [execute] runs it. The laws tie them: decode (encode
 *   i) = i; print (decode w) = objdump's text for w; encode (parse s) =
 *   GNU as's word for s.
 * - {b The interpreter runs words, not values.} Memory holds the
 *   program's bytes; each step fetches the word at pc and decodes it,
 *   as the hardware does (and as the tutorial explains): a program may
 *   compute its own code. No decode cache: it is 5i's speed, not
 *   machine/'s.
 * - {b Two passes, every size known.} Every instruction is 4 bytes, the
 *   directives' sizes follow from their operands: the first pass gives
 *   each label its address, the second encodes. `ldr rN, =value` takes
 *   a word from the literal pool, placed after everything, as GNU as
 *   does without .ltorg (the same value once; a mov or mvn when the
 *   value fits one, as GNU as does).
 * - {b The immediate as GNU as encodes it}: the smallest rotation;
 *   and when the value does not fit, the complementary instruction
 *   (mov and mvn, add and sub, cmp and cmn, and and bic, adc and sbc):
 *   the programmer writes the value, the assembler finds the word.
 * - {b A machine changes four things}, the fields of [env]: a load, a
 *   store, an svc, and a word [decode] does not know. TinyCPUArm gives
 *   memory, Linux's calls, and an error; TinyMachinePi will give the Pi1's
 *   devices behind addresses, the exception taken, and the
 *   instructions of the privileged modes. What happens between two
 *   instructions (an interrupt) is the loop's that calls [step].
 *
 * The subset: the data processing instructions with every operand
 * form (immediate, register, shifted by an immediate or a register,
 * rrx) and the shift aliases (lsl lsr asr ror rrx), the condition and
 * the s suffix on all; mul, mla; ldr, str, ldrb, strb with an immediate
 * or register offset, pre-indexed with or without writeback,
 * post-indexed; ldm, stm in their four modes (and fd, ed, fa, ea),
 * push, pop; b, bl, bx, blx; svc; adr. The directives: .text .data
 * .global .globl .syntax .arch .align .word .byte .ascii .asciz .space
 * (sections are one: everything in the text). Left out, against
 * machine/'s Arm32: the halfword and doubleword transfers, the long
 * multiplies, clz, mrs and msr, the unprivileged transfers, Thumb;
 * against GNU as: expressions beyond label +/- constant, macros,
 * relocations and separate compilation.
 *
 * The tests: TinyCPUArm_test.sh assembles the programs of TinyCPUArm_tests/
 * with GNU as and with this, the text section byte for byte the same;
 * lists them against objdump; runs each here, on the CPU (the ELF
 * written) and under machine/'s mini-5i, the outputs and exit statuses
 * the same; and assembles random instructions of the subset both ways.
 *
 * References: ARM Architecture Reference Manual, ARMv7-A (ARM DDI 0406;
 * from memory): the encodings; GNU as and objdump 2.42, run: the
 * syntax, the choices, the printed forms; principia's Machine book
 * (5i) and machine/ in ix: the interpreter's shape. *)


(*****************************************************************************)
(* Instructions *)
(*****************************************************************************)

type reg = int

type cond = EQ | NE | CS | CC | MI | PL | VS | VC | HI | LS | GE | LT | GT | LE | AL

type op = AND | EOR | SUB | RSB | ADD | ADC | SBC | RSC | TST | TEQ | CMP | CMN | ORR | MOV | BIC | MVN

type shift = LSL | LSR | ASR | ROR

(* the second operand: a value (encoded rotated), a register shifted by
 * an amount (ROR 0 is rrx; LSR and ASR 32 are encoded as 0), or by a
 * register *)
type operand = Imm of int | Reg of reg * shift * int | Regsh of reg * shift * reg

type offset = Ioff of int | Roff of bool * reg * shift * int   (* bool: subtracted *)

type index = Offset | Pre | Post                              (* Pre: writeback *)

type mode = IA | IB | DA | DB

type instr =
  | Dp of cond * op * bool * reg * reg * operand             (* s, rd, rn *)
  | Mul of cond * bool * reg * reg * reg * reg option        (* s, rd, rm, rs, accumulator *)
  | Mem of cond * bool * bool * reg * reg * offset * index   (* load, byte, rd, rn *)
  | Block of cond * bool * reg * bool * mode * int           (* load, rn, writeback, registers *)
  | Branch of cond * bool * int                              (* link, the target *)
  | Bx of cond * bool * reg                                  (* link *)
  | Svc of cond * int

let conds = [| EQ; NE; CS; CC; MI; PL; VS; VC; HI; LS; GE; LT; GT; LE; AL |]
let ops = [| AND; EOR; SUB; RSB; ADD; ADC; SBC; RSC; TST; TEQ; CMP; CMN; ORR; MOV; BIC; MVN |]
let shifts = [| LSL; LSR; ASR; ROR |]
let index_of a x = let rec go i = if a.(i) = x then i else go (i + 1) in go 0

let cond_names = [| "eq"; "ne"; "cs"; "cc"; "mi"; "pl"; "vs"; "vc"; "hi"; "ls"; "ge"; "lt"; "gt"; "le"; "" |]
let op_names = [| "and"; "eor"; "sub"; "rsb"; "add"; "adc"; "sbc"; "rsc"; "tst"; "teq"; "cmp"; "cmn"; "orr"; "mov"; "bic"; "mvn" |]
let shift_names = [| "lsl"; "lsr"; "asr"; "ror" |]
let reg_names = [| "r0"; "r1"; "r2"; "r3"; "r4"; "r5"; "r6"; "r7"; "r8"; "r9"; "sl"; "fp"; "ip"; "sp"; "lr"; "pc" |]

let m32 v = v land 0xffffffff
let ror v n = let n = n land 31 in if n = 0 then m32 v else m32 ((v lsr n) lor (v lsl (32 - n)))
let signed v = if v land 0x80000000 <> 0 then v - (1 lsl 32) else v

(* the value as an 8-bit number rotated right by an even amount: the
 * smallest rotation, as GNU as chooses *)
let rotated v =
  let v = m32 v in
  let rec go r = if r >= 32 then None else if ror v (32 - r) <= 0xff then Some (r / 2, ror v (32 - r)) else go (r + 2) in
  go 0

(*****************************************************************************)
(* Encoding and decoding *)
(*****************************************************************************)

exception Error of string
let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

let shifted_bits rm sh n = (n land 31) lsl 7 lor (index_of shifts sh lsl 5) lor rm

let encode ~pc i =
  let c cond = index_of conds cond lsl 28 in
  let b x = if x then 1 else 0 in
  match i with
  | Dp (cond, op, s, rd, rn, operand) ->
      let o2 = match operand with
        | Imm v -> (match rotated v with Some (r, imm8) -> (1 lsl 25) lor (r lsl 8) lor imm8 | None -> error "immediate %d cannot be encoded" v)
        | Reg (rm, sh, n) -> shifted_bits rm sh n
        | Regsh (rm, sh, rs) -> (rs lsl 8) lor (index_of shifts sh lsl 5) lor 0x10 lor rm in
      c cond lor (index_of ops op lsl 21) lor (b s lsl 20) lor (rn lsl 16) lor (rd lsl 12) lor o2
  | Mul (cond, s, rd, rm, rs, acc) ->
      c cond lor (b (acc <> None) lsl 21) lor (b s lsl 20) lor (rd lsl 16) lor (Option.value acc ~default:0 lsl 12)
      lor (rs lsl 8) lor 0x90 lor rm
  | Mem (cond, load, byte, rd, rn, off, index) ->
      let up, bits = match off with
        | Ioff n -> n >= 0, abs n
        | Roff (sub, rm, sh, n) -> not sub, (1 lsl 25) lor shifted_bits rm sh n in
      if bits land (1 lsl 25) = 0 && bits > 0xfff then error "offset %d out of range" bits;
      let p, w = match index with Offset -> 1, 0 | Pre -> 1, 1 | Post -> 0, 0 in
      c cond lor (1 lsl 26) lor bits lor (p lsl 24) lor (b up lsl 23) lor (b byte lsl 22) lor (w lsl 21) lor (b load lsl 20)
      lor (rn lsl 16) lor (rd lsl 12)
  | Block (cond, load, rn, wb, mode, regs) ->
      let p, u = match mode with IA -> 0, 1 | IB -> 1, 1 | DA -> 0, 0 | DB -> 1, 0 in
      c cond lor (4 lsl 25) lor (p lsl 24) lor (u lsl 23) lor (b wb lsl 21) lor (b load lsl 20) lor (rn lsl 16) lor regs
  | Branch (cond, link, target) ->
      let d = target - (pc + 8) in
      if d land 3 <> 0 || d < -(1 lsl 25) || d >= 1 lsl 25 then error "branch to 0x%x out of range" target;
      c cond lor (5 lsl 25) lor (b link lsl 24) lor ((d asr 2) land 0xffffff)
  | Bx (cond, link, rm) -> c cond lor 0x012fff10 lor (b link lsl 5) lor rm
  | Svc (cond, n) -> c cond lor (0xf lsl 24) lor (n land 0xffffff)

let decode ~pc w =
  let f lo n = (w lsr lo) land ((1 lsl n) - 1) and bit n = (w lsr n) land 1 = 1 in
  let shifted () =
    let rm = f 0 4 and sh = shifts.(f 5 2) in
    if bit 4 then Regsh (rm, sh, f 8 4)
    else
      let n = f 7 5 in
      Reg (rm, sh, (match sh, n with (LSR | ASR), 0 -> 32 | _ -> n)) in
  if f 28 4 = 15 then None
  else
    let cond = conds.(f 28 4) and rn = f 16 4 and rd = f 12 4 in
    match f 25 3 with
    | 0 when f 4 4 = 9 && f 22 6 = 0 ->
        Some (Mul (cond, bit 20, rn, f 0 4, f 8 4, if bit 21 then Some rd else None))
    | 0 when w land 0x0ffffff0 = 0x012fff10 -> Some (Bx (cond, false, f 0 4))
    | 0 when w land 0x0ffffff0 = 0x012fff30 -> Some (Bx (cond, true, f 0 4))
    | 0 when (bit 7 && bit 4) || (f 23 2 = 2 && not (bit 20)) -> None
    | 0 -> Some (Dp (cond, ops.(f 21 4), bit 20, rd, rn, shifted ()))
    | 1 when f 23 2 = 2 && not (bit 20) -> None
    | 1 -> Some (Dp (cond, ops.(f 21 4), bit 20, rd, rn, Imm (ror (f 0 8) (2 * f 8 4))))
    | (2 | 3) as k when k = 2 || not (bit 4) ->
        let up = bit 23 in
        let off =
          if k = 2 then Ioff (if up then f 0 12 else - (f 0 12))
          else match shifted () with Reg (rm, sh, n) -> Roff (not up, rm, sh, n) | _ -> assert false in
        let index = if not (bit 24) then (if bit 21 then None else Some Post) else Some (if bit 21 then Pre else Offset) in
        Option.map (fun index -> Mem (cond, bit 20, bit 22, rd, rn, off, index)) index
    | 4 when not (bit 22) ->
        let mode = match bit 24, bit 23 with false, true -> IA | true, true -> IB | false, false -> DA | true, false -> DB in
        Some (Block (cond, bit 20, rn, bit 21, mode, f 0 16))
    | 5 -> Some (Branch (cond, bit 24, pc + 8 + (((f 0 24) lxor 0x800000) - 0x800000) * 4))
    | 7 when bit 24 -> Some (Svc (cond, f 0 24))
    | _ -> None

(*****************************************************************************)
(* Printing, as objdump does *)
(*****************************************************************************)

let reglist regs =
  "{" ^ String.concat ", " (List.filter_map (fun r -> if regs land (1 lsl r) <> 0 then Some reg_names.(r) else None) (List.init 16 Fun.id)) ^ "}"

let shift_text sh n = match sh, n with LSL, 0 -> "" | ROR, 0 -> ", rrx" | _ -> Printf.sprintf ", %s #%d" shift_names.(index_of shifts sh) n

let print i =
  let m name args = name ^ "\t" ^ String.concat ", " args in
  let cn c = cond_names.(index_of conds c) in
  let r x = reg_names.(x) in
  let sfx s c = (if s then "s" else "") ^ cn c in
  let operand = function
    | Imm v -> Printf.sprintf "#%d" (signed v)
    | Reg (rm, sh, n) -> r rm ^ shift_text sh n
    | Regsh (rm, sh, rs) -> Printf.sprintf "%s, %s %s" (r rm) shift_names.(index_of shifts sh) (r rs) in
  match i with
  (* a shifted mov is its shift's own mnemonic *)
  | Dp (c, MOV, s, rd, _, Reg (rm, ROR, 0)) -> m ("rrx" ^ sfx s c) [ r rd; r rm ]
  | Dp (c, MOV, s, rd, _, Reg (rm, sh, n)) when n <> 0 ->
      m (shift_names.(index_of shifts sh) ^ sfx s c) [ r rd; r rm; Printf.sprintf "#%d" n ]
  | Dp (c, MOV, s, rd, _, Regsh (rm, sh, rs)) -> m (shift_names.(index_of shifts sh) ^ sfx s c) [ r rd; r rm; r rs ]
  | Dp (c, ((TST | TEQ | CMP | CMN) as op), _, _, rn, o) -> m (op_names.(index_of ops op) ^ cn c) [ r rn; operand o ]
  | Dp (c, ((MOV | MVN) as op), s, rd, _, o) -> m (op_names.(index_of ops op) ^ sfx s c) [ r rd; operand o ]
  | Dp (c, op, s, rd, rn, o) -> m (op_names.(index_of ops op) ^ sfx s c) [ r rd; r rn; operand o ]
  | Mul (c, s, rd, rm, rs, None) -> m ("mul" ^ sfx s c) [ r rd; r rm; r rs ]
  | Mul (c, s, rd, rm, rs, Some ra) -> m ("mla" ^ sfx s c) [ r rd; r rm; r rs; r ra ]
  | Mem (c, false, false, rd, 13, Ioff (-4), Pre) -> m ("push" ^ cn c) [ "{" ^ r rd ^ "}" ]
  | Mem (c, true, false, rd, 13, Ioff 4, Post) -> m ("pop" ^ cn c) [ "{" ^ r rd ^ "}" ]
  | Mem (c, load, byte, rd, rn, off, index) ->
      let name = (if load then "ldr" else "str") ^ (if byte then "b" else "") ^ cn c in
      let off_text = match off with
        | Ioff 0 when index = Offset -> None     (* written back, objdump shows #0 *)
        | Ioff n -> Some (Printf.sprintf "#%d" n)
        | Roff (sub, rm, sh, n) -> Some ((if sub then "-" else "") ^ r rm ^ shift_text sh n) in
      let a = match index, off_text with
        | Post, o -> Printf.sprintf "[%s], %s" (r rn) (Option.value o ~default:"#0")
        | _, None -> Printf.sprintf "[%s]%s" (r rn) (if index = Pre then "!" else "")
        | _, Some o -> Printf.sprintf "[%s, %s]%s" (r rn) o (if index = Pre then "!" else "") in
      m name [ r rd; a ]
  | Block (c, true, 13, true, IA, regs) when regs land (regs - 1) <> 0 -> m ("pop" ^ cn c) [ reglist regs ]
  | Block (c, false, 13, true, DB, regs) when regs land (regs - 1) <> 0 -> m ("push" ^ cn c) [ reglist regs ]
  | Block (c, load, rn, wb, mode, regs) ->
      let single_sp = rn = 13 && wb && regs land (regs - 1) = 0 in
      let suffix = match mode, load with
        | IA, true when single_sp -> "fd" | DB, false when single_sp -> "fd"
        | IA, false when wb -> "ia" | IA, _ -> "" | IB, _ -> "ib" | DA, _ -> "da" | DB, _ -> "db" in
      m ((if load then "ldm" else "stm") ^ suffix ^ cn c) [ r rn ^ (if wb then "!" else ""); reglist regs ]
  | Branch (c, link, t) -> m ((if link then "bl" else "b") ^ cn c) [ Printf.sprintf "0x%x" t ]
  | Bx (c, link, rm) -> m ((if link then "blx" else "bx") ^ cn c) [ r rm ]
  | Svc (c, n) -> m ("svc" ^ cn c) [ Printf.sprintf "0x%08x" n ]

(*****************************************************************************)
(* The machine *)
(*****************************************************************************)

type machine = {
  r : int array;
  mutable n : bool; mutable z : bool; mutable c : bool; mutable v : bool;
  mem : Bytes.t;
}

let size = 1 lsl 24                      (* memory: 16MB from address 0 *)

let check m a n = if a < 0 || a + n > Bytes.length m.mem then error "segmentation fault at 0x%x" a
let load32 m a = check m a 4; Int32.to_int (Bytes.get_int32_le m.mem a) land 0xffffffff
let store32 m a v = check m a 4; Bytes.set_int32_le m.mem a (Int32.of_int v)
let load8 m a = check m a 1; Char.code (Bytes.get m.mem a)
let store8 m a v = check m a 1; Bytes.set m.mem a (Char.chr (v land 0xff))

let passed m = function
  | EQ -> m.z | NE -> not m.z | CS -> m.c | CC -> not m.c | MI -> m.n | PL -> not m.n | VS -> m.v | VC -> not m.v
  | HI -> m.c && not m.z | LS -> (not m.c) || m.z | GE -> m.n = m.v | LT -> m.n <> m.v
  | GT -> (not m.z) && m.n = m.v | LE -> m.z || m.n <> m.v | AL -> true

(* the barrel shifter: the value and its carry out *)
let shift m v sh n =
  let bitc k = (v lsr k) land 1 = 1 in
  match sh with
  | _ when n = 0 -> v, m.c
  | LSL -> if n < 32 then m32 (v lsl n), bitc (32 - n) else 0, n = 32 && bitc 0
  | LSR -> if n < 32 then v lsr n, bitc (n - 1) else 0, n = 32 && bitc 31
  | ASR -> if n < 32 then m32 (signed v asr n), bitc (n - 1) else m32 (signed v asr 31), bitc 31
  | ROR -> let k = n land 31 in if k = 0 then v, bitc 31 else ror v k, bitc (k - 1)

let operand m = function
  | Imm v -> v, m.c                     (* the rotation's carry: bit 31 when rotated *)
  | Reg (rm, ROR, 0) -> m32 ((if m.c then 1 lsl 31 else 0) lor (m.r.(rm) lsr 1)), m.r.(rm) land 1 = 1
  | Reg (rm, sh, n) -> shift m m.r.(rm) sh n
  | Regsh (rm, sh, rs) -> shift m m.r.(rm) sh (m.r.(rs) land 0xff)

(* what the program that runs the CPU decides *)
type env = {
  load : machine -> bool -> int -> int;              (* byte? address *)
  store : machine -> bool -> int -> int -> unit;
  svc : machine -> int -> unit;    (* the svc's number; r15 the return address, the hook may change it *)
  undefined : machine -> int -> unit;                (* the word, r15 still on it *)
}

(* memory alone, and an unknown word an error *)
let plain ~svc = {
  load = (fun m byte a -> if byte then load8 m a else load32 m a);
  store = (fun m byte a v -> if byte then store8 m a v else store32 m a v);
  svc;
  undefined = (fun m w -> error "unimplemented instruction %08x at 0x%x" w m.r.(15));
}

let create () = { r = Array.make 16 0; n = false; z = false; c = false; v = false; mem = Bytes.make size '\000' }

let set_nz m v = m.n <- v land 0x80000000 <> 0; m.z <- v = 0

(* a + b + carry, and the flags when [s] *)
let add m s a b cin =
  let r = a + b + cin in
  if s then begin
    set_nz m (m32 r); m.c <- r > 0xffffffff;
    m.v <- (a lxor r) land (b lxor r) land 0x80000000 <> 0
  end;
  m32 r

(* one step: the word at pc decoded and run; the fetch is from memory,
 * whatever env's load: code is never a device's *)
let step env m =
  let pc = m.r.(15) in
  let w = load32 m pc in
  match decode ~pc w with
  | None -> env.undefined m w
  | Some i ->
      let next = ref (pc + 4) in
      let set rd v = if rd = 15 then next := v land lnot 3 else m.r.(rd) <- v in
      m.r.(15) <- pc + 8;                     (* pc reads 8 ahead *)
      (match i with
       | Dp (c, op, s, rd, rn, o) when passed m c ->
           let rot_carry = match o with Imm v -> (match rotated v with Some (r, _) when r <> 0 -> Some (v land 0x80000000 <> 0) | _ -> None) | _ -> None in
           let b, sc = operand m o in
           let sc = Option.value rot_carry ~default:sc in
           let a = m.r.(rn) and cin = if m.c then 1 else 0 in
           let logic v = (if s then (set_nz m v; m.c <- sc)); v in
           let nb = m32 (lnot b) and na = m32 (lnot a) in
           (match op with
            | AND -> set rd (logic (a land b)) | EOR -> set rd (logic (a lxor b)) | ORR -> set rd (logic (a lor b))
            | BIC -> set rd (logic (a land nb)) | MOV -> set rd (logic b) | MVN -> set rd (logic nb)
            | ADD -> set rd (add m s a b 0) | ADC -> set rd (add m s a b cin)
            | SUB -> set rd (add m s a nb 1) | SBC -> set rd (add m s a nb cin)
            | RSB -> set rd (add m s b na 1) | RSC -> set rd (add m s b na cin)
            | TST -> ignore (logic (a land b)) | TEQ -> ignore (logic (a lxor b))
            | CMP -> ignore (add m true a nb 1) | CMN -> ignore (add m true a b 0))
       | Mul (c, s, rd, rm, rs, acc) when passed m c ->
           let v = m32 ((m.r.(rm) * m.r.(rs)) + match acc with Some ra -> m.r.(ra) | None -> 0) in
           if s then set_nz m v;
           set rd v
       | Mem (c, load, byte, rd, rn, off, index) when passed m c ->
           let d = match off with Ioff n -> n | Roff (sub, rm, sh, n) -> let v, _ = shift m m.r.(rm) sh n in if sub then - v else v in
           let base = m.r.(rn) in
           let moved = m32 (base + d) in
           let a = if index = Post then base else moved in
           if index <> Offset && rn <> 15 then m.r.(rn) <- moved;
           if load then set rd (env.load m byte a) else env.store m byte a m.r.(rd)
       | Block (c, load, rn, wb, mode, regs) when passed m c ->
           let count = List.length (List.filter (fun k -> regs land (1 lsl k) <> 0) (List.init 16 Fun.id)) in
           let base = m.r.(rn) in
           let start = match mode with IA -> base | IB -> base + 4 | DA -> base - (4 * count) + 4 | DB -> base - (4 * count) in
           let loaded = ref [] and a = ref start in
           for k = 0 to 15 do
             if regs land (1 lsl k) <> 0 then begin
               if load then loaded := (k, env.load m false !a) :: !loaded else env.store m false !a m.r.(k);
               a := !a + 4
             end
           done;
           if wb then m.r.(rn) <- m32 (match mode with IA | IB -> base + (4 * count) | DA | DB -> base - (4 * count));
           List.iter (fun (k, v) -> set k v) (List.rev !loaded)
       | Branch (c, link, t) when passed m c -> if link then m.r.(14) <- pc + 4; next := t
       | Bx (c, link, rm) when passed m c ->
           let t = m.r.(rm) in
           if t land 1 <> 0 then error "Thumb at 0x%x" t;
           if link then m.r.(14) <- pc + 4;
           next := t
       | Svc (c, n) when passed m c -> m.r.(15) <- pc + 4; env.svc m n; next := m.r.(15)
       | _ -> ());
      m.r.(15) <- !next

(*****************************************************************************)
(* The assembler: parsing *)
(*****************************************************************************)

(* an expression: a number, or a label plus a number *)
type expr = Num of int | Sym of string * int

type item =
  | Label of string
  | Ins of (int -> (expr -> int) -> (expr -> int) -> instr)   (* its pc, the resolver, the literal pool's *)
  | Data of int * (int -> (expr -> int) -> string)            (* its size, the bytes *)
  | Align of int

let trim = String.trim

(* the operands, split at the commas outside brackets and braces *)
let split_operands s =
  let parts = ref [] and depth = ref 0 and cur = Buffer.create 16 in
  String.iter (fun ch ->
    match ch with
    | '[' | '{' -> incr depth; Buffer.add_char cur ch
    | ']' | '}' -> decr depth; Buffer.add_char cur ch
    | ',' when !depth = 0 -> parts := trim (Buffer.contents cur) :: !parts; Buffer.clear cur
    | ch -> Buffer.add_char cur ch) s;
  if trim (Buffer.contents cur) <> "" then parts := trim (Buffer.contents cur) :: !parts;
  List.rev !parts

let reg_of s =
  match s with
  | "sl" -> Some 10 | "fp" -> Some 11 | "ip" -> Some 12 | "sp" -> Some 13 | "lr" -> Some 14 | "pc" -> Some 15
  | _ when String.length s >= 2 && s.[0] = 'r' ->
      (match int_of_string_opt (String.sub s 1 (String.length s - 1)) with Some n when n >= 0 && n < 16 -> Some n | _ -> None)
  | _ -> None

let reg s = match reg_of (trim s) with Some r -> r | None -> error "not a register: %s" s

let expr s =
  let s = trim s in
  match int_of_string_opt s with
  | Some n -> Num n
  | None ->
      (* label, label+n, label-n *)
      let cut = try Some (String.rindex_from s (String.length s - 1) '+') with Not_found -> (try Some (String.rindex s '-') with Not_found -> None) in
      match cut with
      | Some i when i > 0 ->
          let n = int_of_string (trim (String.sub s (i + 1) (String.length s - i - 1))) in
          Sym (trim (String.sub s 0 i), if s.[i] = '-' then - n else n)
      | _ -> Sym (s, 0)

let imm s = let s = trim s in if s <> "" && s.[0] = '#' then expr (String.sub s 1 (String.length s - 1)) else error "not an immediate: %s" s

let shift_of s = match s with "lsl" | "asl" -> Some LSL | "lsr" -> Some LSR | "asr" -> Some ASR | "ror" -> Some ROR | _ -> None

(* "lsl #3", "lsr r2", "rrx": a shift applied to [rm] *)
let shifted_operand rm s ~resolve =
  let s = trim s in
  if s = "rrx" then Reg (rm, ROR, 0)
  else
    match String.index_opt s ' ' with
    | Some i ->
        let sh = match shift_of (String.sub s 0 i) with Some sh -> sh | None -> error "not a shift: %s" s in
        let arg = trim (String.sub s i (String.length s - i)) in
        if arg.[0] = '#' then
          let n = resolve (imm arg) in
          if n < 0 || n > 32 || (n = 32 && (sh = LSL || sh = ROR)) || (n = 0 && sh <> LSL) then error "shift amount %d" n;
          Reg (rm, sh, n)
        else Regsh (rm, sh, reg arg)
    | None -> error "not a shift: %s" s

let reglist s =
  let s = trim s in
  if String.length s < 2 || s.[0] <> '{' then error "not a register list: %s" s;
  List.fold_left (fun acc part ->
    match String.index_opt part '-' with
    | Some i -> let a = reg (String.sub part 0 i) and b = reg (String.sub part (i + 1) (String.length part - i - 1)) in
        List.fold_left (fun acc k -> acc lor (1 lsl k)) acc (List.init (b - a + 1) (fun k -> a + k))
    | None -> acc lor (1 lsl reg part)) 0 (String.split_on_char ',' (String.sub s 1 (String.length s - 2)))

(* the mnemonic: its base, the s flag, the condition, and what is left
 * (ldm's mode, ldr's b) *)
let cond_of = function
  | "hs" -> Some CS | "lo" -> Some CC                          (* the unsigned names *)
  | s -> match index_of cond_names s with i -> Some conds.(i) | exception _ -> None

let bases = [
  "and"; "eor"; "sub"; "rsb"; "add"; "adc"; "sbc"; "rsc"; "tst"; "teq"; "cmp"; "cmn"; "orr"; "mov"; "bic"; "mvn";
  "lsl"; "lsr"; "asr"; "ror"; "rrx"; "mul"; "mla"; "ldrb"; "strb"; "ldr"; "str"; "push"; "pop";
  "ldmia"; "ldmib"; "ldmda"; "ldmdb"; "ldmfd"; "ldmed"; "ldmfa"; "ldmea"; "stmia"; "stmib"; "stmda"; "stmdb";
  "stmfd"; "stmed"; "stmfa"; "stmea"; "ldm"; "stm"; "blx"; "bx"; "bl"; "b"; "svc"; "swi"; "adr" ]

let sets_flags = [ "and"; "eor"; "sub"; "rsb"; "add"; "adc"; "sbc"; "rsc"; "orr"; "mov"; "bic"; "mvn";
                   "lsl"; "lsr"; "asr"; "ror"; "rrx"; "mul"; "mla" ]

let mnemonic w =
  let candidates = List.sort (fun a b -> compare (String.length b) (String.length a)) bases in
  let parse base =
    let rest = String.sub w (String.length base) (String.length w - String.length base) in
    let s, rest = if List.mem base sets_flags && String.length rest >= 1 && rest.[0] = 's' then true, String.sub rest 1 (String.length rest - 1) else false, rest in
    match cond_of rest with Some c -> Some (base, s, c) | None -> None in
  match List.find_map (fun b -> if String.length w >= String.length b && String.sub w 0 (String.length b) = b then parse b else None) candidates with
  | Some x -> x
  | None -> error "unknown instruction: %s" w

(* a value as an operand 2, or the complementary instruction's (GNU as's
 * substitutions) *)
let dp_imm op v =
  let fits v = rotated v <> None in
  if fits v then op, m32 v
  else match op with
    | MOV when fits (lnot v) -> MVN, m32 (lnot v) | MVN when fits (lnot v) -> MOV, m32 (lnot v)
    | ADD when fits (- v) -> SUB, m32 (- v) | SUB when fits (- v) -> ADD, m32 (- v)
    | CMP when fits (- v) -> CMN, m32 (- v) | CMN when fits (- v) -> CMP, m32 (- v)
    | AND when fits (lnot v) -> BIC, m32 (lnot v) | BIC when fits (lnot v) -> AND, m32 (lnot v)
    | ADC when fits (lnot v) -> SBC, m32 (lnot v) | SBC when fits (lnot v) -> ADC, m32 (lnot v)
    | _ -> error "immediate 0x%x cannot be encoded" (m32 v)

(* an address operand: "[rn]", "[rn, #n]", "[rn, rm, lsl #2]" with "!",
 * or "[rn]" and a post-increment *)
let address args ~resolve =
  match args with
  | [ a ] | [ a; _ ] when a.[String.length a - 1] = '!' || String.ends_with ~suffix:"]" a ->
      let wb = a.[String.length a - 1] = '!' in
      let inner = String.sub a 1 (String.index a ']' - 1) in
      let parts = split_operands inner in
      let rn = reg (List.hd parts) in
      let off rest = match rest with
        | [] -> Ioff 0
        | o :: sh when o.[0] <> '#' ->
            let sub = o.[0] = '-' in
            let rm = reg (if sub || o.[0] = '+' then String.sub o 1 (String.length o - 1) else o) in
            (match sh with [] -> Roff (sub, rm, LSL, 0)
                         | [ s ] -> (match shifted_operand rm s ~resolve with Reg (_, sh, n) -> Roff (sub, rm, sh, n) | _ -> error "register shift in an address")
                         | _ -> error "bad address: %s" a)
        | [ o ] -> Ioff (resolve (imm o))
        | _ -> error "bad address: %s" a in
      (match args with
       | [ _ ] -> rn, off (List.tl parts), (if wb then Pre else Offset)
       | [ _; post ] -> if List.length parts <> 1 || wb then error "bad address: %s" a else rn, off [ post ], Post
       | _ -> assert false)
  | _ -> error "bad address: %s" (String.concat ", " args)

(* an instruction line's item *)
let instruction w operands : item =
  let base, s, c = mnemonic w in
  let xs = split_operands operands in
  let dp_op = List.assoc_opt base (List.combine (Array.to_list op_names) (Array.to_list ops)) in
  let second resolve rest =
    match rest with
    | [ x ] when x.[0] = '#' -> `Imm (resolve (imm x))
    | [ x ] -> `Op (Reg (reg x, LSL, 0))
    | [ x; sh ] -> `Op (shifted_operand (reg x) sh ~resolve)
    | _ -> error "bad operands: %s" operands in
  let dp ?(s = s) op rd rn rest resolve =
    match second resolve rest with
    | `Imm v -> let op, v = dp_imm op v in Dp (c, op, s, rd, rn, Imm v)
    | `Op o -> Dp (c, op, s, rd, rn, o) in
  match base, dp_op, xs with
  (* the comparisons always set the flags (the S bit clear is another
   * instruction class) *)
  | _, Some ((TST | TEQ | CMP | CMN) as op), rn :: rest -> Ins (fun _ res _ -> dp ~s:true op 0 (reg rn) rest res)
  | _, Some ((MOV | MVN) as op), rd :: rest -> Ins (fun _ res _ -> dp op (reg rd) 0 rest res)
  | _, Some op, rd :: rn :: rest -> Ins (fun _ res _ -> dp op (reg rd) (reg rn) rest res)
  | ("lsl" | "lsr" | "asr" | "ror"), _, [ rd; rm; amount ] ->
      Ins (fun _ res _ -> Dp (c, MOV, s, reg rd, 0, shifted_operand (reg rm) (base ^ " " ^ amount) ~resolve:res))
  | "rrx", _, [ rd; rm ] -> Ins (fun _ _ _ -> Dp (c, MOV, s, reg rd, 0, Reg (reg rm, ROR, 0)))
  | "mul", _, [ rd; rm; rs ] -> Ins (fun _ _ _ -> Mul (c, s, reg rd, reg rm, reg rs, None))
  | "mla", _, [ rd; rm; rs; ra ] -> Ins (fun _ _ _ -> Mul (c, s, reg rd, reg rm, reg rs, Some (reg ra)))
  | ("ldr" | "str" | "ldrb" | "strb"), _, rd :: rest ->
      let load = base.[0] = 'l' and byte = String.length base = 4 in
      (match rest with
       | [ x ] when x.[0] = '=' && load && not byte ->
           (* a constant: a mov or mvn if it fits one, else the pool's *)
           Ins (fun pc res lit ->
             let e = expr (String.sub x 1 (String.length x - 1)) in
             let v = res e in
             match e with
             | Num _ when rotated v <> None -> Dp (c, MOV, false, reg rd, 0, Imm (m32 v))
             | Num _ when rotated (lnot v) <> None -> Dp (c, MVN, false, reg rd, 0, Imm (m32 (lnot v)))
             | _ -> Mem (c, true, false, reg rd, 15, Ioff (lit e - (pc + 8)), Offset))
       | [ x ] when x.[0] <> '[' ->
           (* a label: pc-relative *)
           Ins (fun pc res _ -> Mem (c, load, byte, reg rd, 15, Ioff (res (expr x) - (pc + 8)), Offset))
       | _ -> Ins (fun _ res _ -> let rn, off, index = address rest ~resolve:res in Mem (c, load, byte, reg rd, rn, off, index)))
  | ("push" | "pop"), _, [ l ] ->
      Ins (fun _ _ _ ->
        let regs = reglist l in
        let push = base = "push" in
        if regs land (regs - 1) = 0 && not (push && regs = 1 lsl 13) then
          (* one register: a transfer, as GNU as writes it (but pushing
           * sp, whose store would write back the register it stores) *)
          let rd = index_of (Array.init 16 (fun k -> 1 lsl k)) regs in
          if push then Mem (c, false, false, rd, 13, Ioff (-4), Pre) else Mem (c, true, false, rd, 13, Ioff 4, Post)
        else Block (c, not push, 13, true, (if push then DB else IA), regs))
  | _, _, [ rn; l ] when String.length base >= 3 && (String.sub base 0 3 = "ldm" || String.sub base 0 3 = "stm") ->
      let load = base.[0] = 'l' in
      let mode = match String.sub base 3 (String.length base - 3), load with
        | ("" | "ia"), _ | "fd", true | "ea", false -> IA
        | "ib", _ | "ed", true | "fa", false -> IB
        | "da", _ | "fa", true | "ed", false -> DA
        | _ -> DB in
      let wb = rn.[String.length rn - 1] = '!' in
      let rn = if wb then String.sub rn 0 (String.length rn - 1) else rn in
      Ins (fun _ _ _ -> Block (c, load, reg rn, wb, mode, reglist l))
  | ("b" | "bl"), _, [ t ] -> Ins (fun _ res _ -> Branch (c, base = "bl", res (expr t)))
  | ("bx" | "blx"), _, [ rm ] -> Ins (fun _ _ _ -> Bx (c, base = "blx", reg rm))
  | ("svc" | "swi"), _, [ n ] -> Ins (fun _ res _ -> Svc (c, res (imm n)))
  | "adr", _, [ rd; t ] ->
      Ins (fun pc res _ ->
        let d = res (expr t) - (pc + 8) in
        if d >= 0 then Dp (c, ADD, false, reg rd, 15, Imm d) else Dp (c, SUB, false, reg rd, 15, Imm (- d)))
  | _ -> error "bad operands for %s: %s" w operands

(* a string's escapes: a backslash and n, t or 0; before another
 * character, that character *)
let unescape s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i < String.length s then
      if s.[i] = '\\' && i + 1 < String.length s then begin
        Buffer.add_char b (match s.[i + 1] with 'n' -> '\n' | 't' -> '\t' | '0' -> '\000' | c -> c);
        go (i + 2)
      end
      else (Buffer.add_char b s.[i]; go (i + 1)) in
  go 0;
  Buffer.contents b

let string_arg s =
  let s = trim s in
  if String.length s < 2 || s.[0] <> '"' || s.[String.length s - 1] <> '"' then error "not a string: %s" s;
  unescape (String.sub s 1 (String.length s - 2))

let le32 v = let b = Bytes.create 4 in Bytes.set_int32_le b 0 (Int32.of_int v); Bytes.to_string b

let directive d args : item list =
  match d with
  | ".text" | ".data" | ".global" | ".globl" | ".syntax" | ".arch" | ".arm" | ".type" | ".section" -> []
  | ".align" -> [ Align (1 lsl int_of_string (trim args)) ]
  | ".word" ->
      let es = List.map expr (split_operands args) in
      [ Data (4 * List.length es, fun _ res -> String.concat "" (List.map (fun e -> le32 (res e)) es)) ]
  | ".byte" ->
      let es = List.map expr (split_operands args) in
      [ Data (List.length es, fun _ res -> String.concat "" (List.map (fun e -> String.make 1 (Char.chr (res e land 0xff))) es)) ]
  | ".ascii" | ".asciz" ->
      let s = string_arg args ^ if d = ".asciz" then "\000" else "" in
      [ Data (String.length s, fun _ _ -> s) ]
  | ".space" | ".skip" -> let n = int_of_string (trim args) in [ Data (n, fun _ _ -> String.make n '\000') ]
  | _ -> error "unknown directive %s" d

(* a line: labels, then a directive or an instruction; @ starts a comment *)
let parse_line line : item list =
  let line = match String.index_opt line '@' with
    | Some i when not (String.contains (String.sub line 0 i) '"') -> String.sub line 0 i
    | _ -> line in
  let rec go s acc =
    let s = trim s in
    if s = "" then List.rev acc
    else
      let word_end = try String.index_from s 0 ' ' with Not_found -> String.length s in
      let word_end = min word_end (try String.index s '\t' with Not_found -> String.length s) in
      let word = String.sub s 0 word_end and rest = String.sub s word_end (String.length s - word_end) in
      match String.index_opt word ':' with
      | Some i when i = String.length word - 1 -> go rest (Label (String.sub word 0 i) :: acc)
      | Some i -> go (String.sub s (i + 1) (String.length s - i - 1)) (Label (String.sub word 0 i) :: acc)
      | None when word.[0] = '.' -> List.rev acc @ directive word (trim rest)
      | None -> List.rev acc @ [ instruction (String.lowercase_ascii word) (trim rest) ] in
  go line []

(*****************************************************************************)
(* The assembler: the two passes *)
(*****************************************************************************)

(* the program's bytes from [origin], its labels, and where its
 * instructions are (for the listing) *)
let assemble ~origin (lines : string list) =
  let items = List.concat (List.mapi (fun n l -> try parse_line l with Error e -> error "line %d: %s" (n + 1) e) lines) in
  let labels = Hashtbl.create 64 in
  (* the first pass: the addresses *)
  let placed = ref [] and pc = ref origin in
  List.iter (fun it ->
    (match it with
     | Label l -> if Hashtbl.mem labels l then error "label %s defined twice" l; Hashtbl.replace labels l !pc
     | Align n -> let a = (!pc + n - 1) / n * n in placed := (!pc, Data (a - !pc, fun _ _ -> String.make (a - !pc) '\000')) :: !placed; pc := a
     | Ins _ -> placed := (!pc, it) :: !placed; pc := !pc + 4
     | Data (n, _) -> placed := (!pc, it) :: !placed; pc := !pc + n)) items;
  let resolve = function
    | Num n -> n
    | Sym (l, n) -> (match Hashtbl.find_opt labels l with Some a -> a + n | None -> error "undefined label %s" l) in
  (* the literal pool: after everything, word-aligned; a value once *)
  let pool_base = (!pc + 3) / 4 * 4 in
  let pool = ref [] in
  let literal e =
    let rec find i = function
      | [] -> pool := !pool @ [ e ]; pool_base + (4 * i)
      | e' :: rest -> if e' = e then pool_base + (4 * i) else find (i + 1) rest in
    find 0 !pool in
  (* the second pass: the bytes *)
  let buf = Buffer.create 4096 and code = ref [] in
  List.iter (fun (a, it) ->
    match it with
    | Ins f ->
        let i = f a resolve literal in
        code := (a, i) :: !code;
        Buffer.add_string buf (le32 (encode ~pc:a i))
    | Data (_, f) -> Buffer.add_string buf (f a resolve)
    | Label _ | Align _ -> ()) (List.rev !placed);
  if !pool <> [] then begin
    Buffer.add_string buf (String.make (pool_base - !pc) '\000');
    List.iter (fun e -> Buffer.add_string buf (le32 (resolve e))) !pool
  end;
  Buffer.contents buf, labels, List.rev !code

(* the listing: each instruction encoded, then decoded back, so that
 * objdump's text checks both directions *)
let listing code =
  List.map (fun (a, i) ->
    let w = encode ~pc:a i in
    let text = match decode ~pc:a w with Some i' -> print i' | None -> "(not decoded)" in
    Printf.sprintf "%x:\t%08x\t%s\n" a w text) code
  |> String.concat ""
