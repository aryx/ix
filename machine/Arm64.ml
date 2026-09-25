(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Arm64.mli *)

type reg = int
type sf = W | X
type cond = EQ | NE | CS | CC | MI | PL | VS | VC | HI | LS | GE | LT | GT | LE | AL | NV
type shift = LSL | LSR | ASR | ROR
type extend = UXTB | UXTH | UXTW | UXTX | SXTB | SXTH | SXTW | SXTX
type logic = AND | ORR | EOR | ANDS
type size = Byte | Half | Word | Dword
type mode = Offset | Unscaled | Unpriv | Pre | Post

type addr =
  | Base of { rn : reg; offset : int; mode : mode }
  | Index of { rn : reg; rm : reg; extend : extend; s : bool }
  | Literal of int

type pair_mode = P_offset | P_pre | P_post | P_nontemporal

type hint = Yield | Wfe | Wfi | Sev | Sevl

type pstate_field = Spsel | Daifset | Daifclr

type barrier = Dsb | Dmb | Isb | Clrex

type t =
  | Add_imm of { sf : sf; sub : bool; s : bool; rd : reg; rn : reg; imm : int; lsl12 : bool }
  | Add_reg of { sf : sf; sub : bool; s : bool; rd : reg; rn : reg; rm : reg; shift : shift; amount : int }
  | Add_ext of { sf : sf; sub : bool; s : bool; rd : reg; rn : reg; rm : reg; extend : extend; amount : int }
  | Adc of { sf : sf; sub : bool; s : bool; rd : reg; rn : reg; rm : reg }
  | Logic_imm of { sf : sf; op : logic; rd : reg; rn : reg; imm : int64 }
  | Logic_reg of { sf : sf; op : logic; invert : bool; rd : reg; rn : reg; rm : reg; shift : shift; amount : int }
  | Movn of { sf : sf; rd : reg; imm16 : int; hw : int }
  | Movz of { sf : sf; rd : reg; imm16 : int; hw : int }
  | Movk of { sf : sf; rd : reg; imm16 : int; hw : int }
  | Sbfm of { sf : sf; rd : reg; rn : reg; immr : int; imms : int }
  | Bfm of { sf : sf; rd : reg; rn : reg; immr : int; imms : int }
  | Ubfm of { sf : sf; rd : reg; rn : reg; immr : int; imms : int }
  | Extr of { sf : sf; rd : reg; rn : reg; rm : reg; lsb : int }
  | Adr of { page : bool; rd : reg; offset : int }
  | Csel of { sf : sf; inc : bool; inv : bool; rd : reg; rn : reg; rm : reg; cond : cond }
  | Ccmp of { sf : sf; neg : bool; rn : reg; imm : bool; rm : reg; nzcv : int; cond : cond }
  | Rbit of { sf : sf; rd : reg; rn : reg }
  | Rev of { sf : sf; bytes : int; rd : reg; rn : reg }
  | Clz of { sf : sf; cls : bool; rd : reg; rn : reg }
  | Div of { sf : sf; signed : bool; rd : reg; rn : reg; rm : reg }
  | Shiftv of { sf : sf; shift : shift; rd : reg; rn : reg; rm : reg }
  | Madd of { sf : sf; sub : bool; rd : reg; rn : reg; rm : reg; ra : reg }
  | Maddl of { signed : bool; sub : bool; rd : reg; rn : reg; rm : reg; ra : reg }
  | Mulh of { signed : bool; rd : reg; rn : reg; rm : reg }
  | B of { link : bool; offset : int }
  | Bcond of { cond : cond; offset : int }
  | Cbz of { sf : sf; nz : bool; rt : reg; offset : int }
  | Tbz of { nz : bool; rt : reg; bit : int; offset : int }
  | Br of { link : bool; rn : reg }
  | Ret of reg
  | Mem of { load : bool; size : size; signed : sf option; rt : reg; addr : addr }
  | Pair of { load : bool; sf : sf; signed : bool; rt : reg; rt2 : reg; rn : reg; offset : int; mode : pair_mode }
  | Svc of int
  | Hvc of int
  | Smc of int
  | Brk of int
  | Nop
  | Hint of hint
  (* the system registers, by their 16-bit encoding (op0, op1, CRn,
   * CRm, op2: [sysreg]); only those of the table, the rest Undefined *)
  | Mrs of { rt : reg; sr : int }
  | Msr of { rt : reg; sr : int }
  | Msr_imm of { field : pstate_field; imm : int }
  (* dc, ic, tlbi, at: the operations of the table, by op1:CRn:CRm:op2 *)
  | Sys of { op : int; rt : reg }
  | Barrier of { kind : barrier; option : int }
  | Eret
  (* ldxr, ldaxr, stxr, stlxr ([exclusive]); ldar, stlr, ldlar, stllr;
   * [ordered]: acquire for a load, release for a store; [rs] the
   * status register of an exclusive store *)
  | Excl of { load : bool; size : size; ordered : bool; exclusive : bool; rs : reg; rt : reg; rn : reg }
  | Undefined of int

let field = Bits.field
let bit = Bits.bit

let conds = [| EQ; NE; CS; CC; MI; PL; VS; VC; HI; LS; GE; LT; GT; LE; AL; NV |]
let shifts = [| LSL; LSR; ASR; ROR |]
let extends = [| UXTB; UXTH; UXTW; UXTX; SXTB; SXTH; SXTW; SXTX |]
let logics = [| AND; ORR; EOR; ANDS |]
let width = function W -> 32 | X -> 64

(*****************************************************************************)
(* Logical immediates *)
(*****************************************************************************)

let ones n = if n >= 64 then (-1L) else Int64.pred (Int64.shift_left 1L n)

(* DecodeBitMasks: an element of [esize] bits (a power of 2), its low
 * S+1 bits set, rotated right by R, repeated across the register *)
let bitmask sf n immr imms =
  let v = (n lsl 6) lor (lnot imms land 0x3f) in
  let rec high k = if k < 0 then -1 else if (v lsr k) land 1 = 1 then k else high (k - 1) in
  let len = high 6 in
  if len < 1 || (sf = W && n = 1) then None
  else
    let levels = (1 lsl len) - 1 in
    if imms land levels = levels then None
    else
      let s = imms land levels and r = immr land levels and esize = 1 lsl len in
      let welem = ones (s + 1) in
      let elem =
        if r = 0 then welem
        else Int64.logand (ones esize) (Int64.logor (Int64.shift_right_logical welem r) (Int64.shift_left welem (esize - r))) in
      let rec rep acc k = if k >= width sf then acc else rep (Int64.logor acc (Int64.shift_left elem k)) (k + esize) in
      Some (rep 0L 0)

(*****************************************************************************)
(* Decoding *)
(*****************************************************************************)

let sf_of w = if bit w 31 then X else W

(* data processing with an immediate: bits 28-23 *)
let dp_imm w =
  let sf = sf_of w and rd = field w 0 5 and rn = field w 5 5 in
  match field w 23 3 with
  | 0 | 1 ->
      let imm = Bits.sign_extend 21 ((field w 5 19 lsl 2) lor field w 29 2) in
      let page = bit w 31 in
      Adr { page; rd; offset = imm }
  | 2 -> Add_imm { sf; sub = bit w 30; s = bit w 29; rd; rn; imm = field w 10 12; lsl12 = bit w 22 }
  | 4 ->
      (match bitmask sf (field w 22 1) (field w 16 6) (field w 10 6) with
       | None -> Undefined w
       | Some imm -> Logic_imm { sf; op = logics.(field w 29 2); rd; rn; imm })
  | 5 ->
      let hw = field w 21 2 and imm16 = field w 5 16 in
      if sf = W && hw >= 2 then Undefined w
      else (match field w 29 2 with
        | 0 -> Movn { sf; rd; imm16; hw }
        | 2 -> Movz { sf; rd; imm16; hw }
        | 3 -> Movk { sf; rd; imm16; hw }
        | _ -> Undefined w)
  | 6 ->
      let immr = field w 16 6 and imms = field w 10 6 in
      if field w 22 1 <> (if sf = X then 1 else 0) || (sf = W && (immr >= 32 || imms >= 32)) then Undefined w
      else (match field w 29 2 with
        | 0 -> Sbfm { sf; rd; rn; immr; imms }
        | 1 -> Bfm { sf; rd; rn; immr; imms }
        | 2 -> Ubfm { sf; rd; rn; immr; imms }
        | _ -> Undefined w)
  | 7 ->
      let lsb = field w 10 6 in
      if field w 29 2 <> 0 || bit w 21 || field w 22 1 <> (if sf = X then 1 else 0) || (sf = W && lsb >= 32) then Undefined w
      else Extr { sf; rd; rn; rm = field w 16 5; lsb }
  | _ -> Undefined w

(* the system registers the kernels use (xv6 arm64-pi4's, QEMU's
 * cortex-a72's identification, the generic timer's), by name, as
 * objdump names them, and op0, op1, CRn, CRm, op2 *)
let sysregs = [
  "nzcv", 3, 3, 4, 2, 0; "daif", 3, 3, 4, 2, 1; "currentel", 3, 0, 4, 2, 2; "spsel", 3, 0, 4, 2, 0;
  "fpcr", 3, 3, 4, 4, 0; "fpsr", 3, 3, 4, 4, 1;
  "sp_el0", 3, 0, 4, 1, 0; "sp_el1", 3, 4, 4, 1, 0; "sp_el2", 3, 6, 4, 1, 0;
  "spsr_el1", 3, 0, 4, 0, 0; "elr_el1", 3, 0, 4, 0, 1; "spsr_el2", 3, 4, 4, 0, 0; "elr_el2", 3, 4, 4, 0, 1;
  "spsr_el3", 3, 6, 4, 0, 0; "elr_el3", 3, 6, 4, 0, 1;
  "sctlr_el1", 3, 0, 1, 0, 0; "actlr_el1", 3, 0, 1, 0, 1; "cpacr_el1", 3, 0, 1, 0, 2;
  "sctlr_el2", 3, 4, 1, 0, 0; "hcr_el2", 3, 4, 1, 1, 0; "cptr_el2", 3, 4, 1, 1, 2;
  "sctlr_el3", 3, 6, 1, 0, 0; "scr_el3", 3, 6, 1, 1, 0; "cptr_el3", 3, 6, 1, 1, 2;
  "ttbr0_el1", 3, 0, 2, 0, 0; "ttbr1_el1", 3, 0, 2, 0, 1; "tcr_el1", 3, 0, 2, 0, 2;
  "esr_el1", 3, 0, 5, 2, 0; "esr_el2", 3, 4, 5, 2, 0; "esr_el3", 3, 6, 5, 2, 0;
  "far_el1", 3, 0, 6, 0, 0; "far_el2", 3, 4, 6, 0, 0; "far_el3", 3, 6, 6, 0, 0;
  "par_el1", 3, 0, 7, 4, 0; "mair_el1", 3, 0, 10, 2, 0;
  "vbar_el1", 3, 0, 12, 0, 0; "vbar_el2", 3, 4, 12, 0, 0; "vbar_el3", 3, 6, 12, 0, 0;
  "contextidr_el1", 3, 0, 13, 0, 1; "tpidr_el0", 3, 3, 13, 0, 2; "tpidrro_el0", 3, 3, 13, 0, 3;
  "tpidr_el1", 3, 0, 13, 0, 4;
  "midr_el1", 3, 0, 0, 0, 0; "mpidr_el1", 3, 0, 0, 0, 5; "revidr_el1", 3, 0, 0, 0, 6;
  "ctr_el0", 3, 3, 0, 0, 1; "dczid_el0", 3, 3, 0, 0, 7;
  "id_aa64pfr0_el1", 3, 0, 0, 4, 0; "id_aa64isar0_el1", 3, 0, 0, 6, 0; "id_aa64mmfr0_el1", 3, 0, 0, 7, 0;
  "cntfrq_el0", 3, 3, 14, 0, 0; "cntpct_el0", 3, 3, 14, 0, 1; "cntvct_el0", 3, 3, 14, 0, 2;
  "cntp_tval_el0", 3, 3, 14, 2, 0; "cntp_ctl_el0", 3, 3, 14, 2, 1; "cntp_cval_el0", 3, 3, 14, 2, 2;
  "cntv_tval_el0", 3, 3, 14, 3, 0; "cntv_ctl_el0", 3, 3, 14, 3, 1; "cntv_cval_el0", 3, 3, 14, 3, 2;
  "cntkctl_el1", 3, 0, 14, 1, 0; "cnthctl_el2", 3, 4, 14, 1, 0; "cntvoff_el2", 3, 4, 14, 0, 3 ]

let encode op0 op1 crn crm op2 = (op0 lsl 14) lor (op1 lsl 11) lor (crn lsl 7) lor (crm lsl 3) lor op2
let sysreg_names = Hashtbl.create 64
let () = List.iter (fun (n, a, b, c, d, e) -> Hashtbl.replace sysreg_names (encode a b c d e) n) sysregs
let sysreg name =
  match List.find_opt (fun (n, _, _, _, _, _) -> n = name) sysregs with
  | Some (_, a, b, c, d, e) -> encode a b c d e
  | None -> invalid_arg ("Arm64.sysreg: " ^ name)
let sysreg_name sr = Hashtbl.find sysreg_names sr

(* the system operations (SYS), by op1:CRn:CRm:op2; [reg]: whether
 * objdump prints the register (the whole-cache and whole-TLB ones
 * take none) *)
let sysops = [
  "ic", "ialluis", 0, 7, 1, 0, false; "ic", "iallu", 0, 7, 5, 0, false; "ic", "ivau", 3, 7, 5, 1, true;
  "dc", "ivac", 0, 7, 6, 1, true; "dc", "isw", 0, 7, 6, 2, true; "dc", "csw", 0, 7, 10, 2, true;
  "dc", "cisw", 0, 7, 14, 2, true; "dc", "zva", 3, 7, 4, 1, true; "dc", "cvac", 3, 7, 10, 1, true;
  "dc", "cvau", 3, 7, 11, 1, true; "dc", "civac", 3, 7, 14, 1, true; "dc", "cvap", 3, 7, 12, 1, true;
  "at", "s1e1r", 0, 7, 8, 0, true; "at", "s1e1w", 0, 7, 8, 1, true; "at", "s1e0r", 0, 7, 8, 2, true;
  "at", "s1e0w", 0, 7, 8, 3, true;
  "tlbi", "vmalle1is", 0, 8, 3, 0, false; "tlbi", "vmalle1", 0, 8, 7, 0, false;
  "tlbi", "vae1is", 0, 8, 3, 1, true; "tlbi", "vae1", 0, 8, 7, 1, true;
  "tlbi", "aside1is", 0, 8, 3, 2, true; "tlbi", "aside1", 0, 8, 7, 2, true;
  "tlbi", "vaae1is", 0, 8, 3, 3, true; "tlbi", "vaae1", 0, 8, 7, 3, true;
  "tlbi", "vale1is", 0, 8, 3, 5, true; "tlbi", "vale1", 0, 8, 7, 5, true;
  "tlbi", "vaale1is", 0, 8, 3, 7, true; "tlbi", "vaale1", 0, 8, 7, 7, true;
  "tlbi", "alle1is", 4, 8, 3, 4, false; "tlbi", "alle1", 4, 8, 7, 4, false;
  "tlbi", "alle2", 4, 8, 7, 0, false; "tlbi", "alle3", 6, 8, 7, 0, false ]

let sysop_names = Hashtbl.create 64
let () = List.iter (fun (k, n, a, b, c, d, r) -> Hashtbl.replace sysop_names (encode 0 a b c d) (k, n, r)) sysops
let sysop op = Hashtbl.find sysop_names op

(* the system instructions: bits 31-22 = 1101010100 *)
let system w =
  let l = bit w 21 and op0 = field w 19 2 and op1 = field w 16 3 and crn = field w 12 4 in
  let crm = field w 8 4 and op2 = field w 5 3 and rt = field w 0 5 in
  let sr = field w 5 16 in
  match op0, l with
  | (2 | 3), _ when Hashtbl.mem sysreg_names sr -> if l then Mrs { rt; sr } else Msr { rt; sr }
  | 1, false when Hashtbl.mem sysop_names (field w 5 14) -> Sys { op = field w 5 14; rt }
  | 0, false when rt = 31 && crn = 2 && op1 = 3 ->
      (match (crm lsl 3) lor op2 with
       | 0 -> Nop | 1 -> Hint Yield | 2 -> Hint Wfe | 3 -> Hint Wfi | 4 -> Hint Sev | 5 -> Hint Sevl
       | _ -> Undefined w)
  | 0, false when rt = 31 && crn = 3 && op1 = 3 ->
      (match op2 with
       | 2 -> Barrier { kind = Clrex; option = crm }
       | 4 -> Barrier { kind = Dsb; option = crm }
       | 5 -> Barrier { kind = Dmb; option = crm }
       | 6 -> Barrier { kind = Isb; option = crm }
       | _ -> Undefined w)
  | 0, false when rt = 31 && crn = 4 ->
      (match op1, op2 with
       | 0, 5 -> Msr_imm { field = Spsel; imm = crm }
       | 3, 6 -> Msr_imm { field = Daifset; imm = crm }
       | 3, 7 -> Msr_imm { field = Daifclr; imm = crm }
       | _ -> Undefined w)
  | _ -> Undefined w

(* branches, exceptions, system: bits 28-26 = 101 *)
let branch w =
  if field w 26 5 = 0b00101 then B { link = bit w 31; offset = Bits.sign_extend 26 (field w 0 26) * 4 }
  else if field w 24 8 = 0b01010100 && not (bit w 4) then
    Bcond { cond = conds.(field w 0 4); offset = Bits.sign_extend 19 (field w 5 19) * 4 }
  else if field w 25 6 = 0b011010 then
    Cbz { sf = sf_of w; nz = bit w 24; rt = field w 0 5; offset = Bits.sign_extend 19 (field w 5 19) * 4 }
  else if field w 25 6 = 0b011011 then
    Tbz { nz = bit w 24; rt = field w 0 5; bit = (field w 31 1 lsl 5) lor field w 19 5;
          offset = Bits.sign_extend 14 (field w 5 14) * 4 }
  else if field w 24 8 = 0xd4 && field w 2 3 = 0 then
    (* the exception generating instructions *)
    let imm = field w 5 16 in
    (match field w 21 3, field w 0 2 with
     | 0, 1 -> Svc imm | 0, 2 -> Hvc imm | 0, 3 -> Smc imm | 1, 0 -> Brk imm
     | _ -> Undefined w)
  else if field w 22 10 = 0b1101010100 then system w
  else if field w 16 16 = 0xd69f && field w 0 16 = 0x03e0 then Eret
  else if field w 25 7 = 0b1101011 && field w 10 11 = 0b11111000000 && field w 0 5 = 0 then
    (match field w 21 4 with
     | 0 -> Br { link = false; rn = field w 5 5 }
     | 1 -> Br { link = true; rn = field w 5 5 }
     | 2 -> Ret (field w 5 5)
     | _ -> Undefined w)
  else Undefined w

let sizes = [| Byte; Half; Word; Dword |]

(* a load or store's kind from size and opc: None for prefetches and
 * the unallocated *)
let transfer size opc =
  match size, opc with
  | _, 0 -> Some (false, None)
  | _, 1 -> Some (true, None)
  | (0 | 1), 2 -> Some (true, Some X)
  | (0 | 1), 3 -> Some (true, Some W)
  | 2, 2 -> Some (true, Some X)
  | _ -> None

(* loads and stores: bits 27 = 1, 25 = 0; SIMD (bit 26) undecoded *)
let loadstore w =
  let rt = field w 0 5 and rn = field w 5 5 in
  if bit w 26 then Undefined w
  else
    match field w 28 2 with
    | 1 when field w 24 2 = 0 ->
        let offset = Bits.sign_extend 19 (field w 5 19) * 4 in
        (match field w 30 2 with
         | 0 -> Mem { load = true; size = Word; signed = None; rt; addr = Literal offset }
         | 1 -> Mem { load = true; size = Dword; signed = None; rt; addr = Literal offset }
         | 2 -> Mem { load = true; size = Word; signed = Some X; rt; addr = Literal offset }
         | _ -> Undefined w)
    | 2 ->
        let opc = field w 30 2 and load = bit w 22 in
        let mode = [| P_nontemporal; P_post; P_offset; P_pre |].(field w 23 2) in
        let pair sf signed =
          let scale = if sf = X && not signed then 8 else 4 in
          Pair { load; sf; signed; rt; rt2 = field w 10 5; rn; offset = Bits.sign_extend 7 (field w 15 7) * scale; mode } in
        (match opc with
         | 0 -> pair W false
         | 1 when load && mode <> P_nontemporal -> pair X true
         | 2 -> pair X false
         | _ -> Undefined w)
    | 3 ->
        let size = field w 30 2 in
        (match transfer size (field w 22 2) with
         | None -> Undefined w
         | Some (load, signed) ->
             let mem addr = Mem { load; size = sizes.(size); signed; rt; addr } in
             if bit w 24 then mem (Base { rn; offset = field w 10 12 lsl size; mode = Offset })
             else if not (bit w 21) then
               let offset = Bits.sign_extend 9 (field w 12 9) in
               let mode = [| Unscaled; Post; Unpriv; Pre |].(field w 10 2) in
               mem (Base { rn; offset; mode })
             else if field w 10 2 = 2 && bit w 14 then
               mem (Index { rn; rm = field w 16 5; extend = extends.(field w 13 3); s = bit w 12 })
             else Undefined w)
    | 0 when field w 24 2 = 0 ->
        (* the exclusive and ordered loads and stores: pairs (o1) and
         * compare-and-swap left undefined *)
        let load = bit w 22 and exclusive = not (bit w 23) and rs = field w 16 5 in
        if bit w 21 || field w 10 5 <> 31 || ((load || not exclusive) && rs <> 31) then Undefined w
        else Excl { load; size = sizes.(field w 30 2); ordered = bit w 15; exclusive; rs; rt; rn }
    | _ -> Undefined w

(* data processing on registers: bits 27-25 = 101 *)
let dp_reg w =
  let sf = sf_of w and rd = field w 0 5 and rn = field w 5 5 and rm = field w 16 5 in
  let wide_ok amount = sf = X || amount < 32 in
  match field w 24 5 with
  | 0b01010 ->
      let amount = field w 10 6 in
      if not (wide_ok amount) then Undefined w
      else Logic_reg { sf; op = logics.(field w 29 2); invert = bit w 21; rd; rn; rm; shift = shifts.(field w 22 2); amount }
  | 0b01011 when not (bit w 21) ->
      let amount = field w 10 6 and sh = field w 22 2 in
      if sh = 3 || not (wide_ok amount) then Undefined w
      else Add_reg { sf; sub = bit w 30; s = bit w 29; rd; rn; rm; shift = shifts.(sh); amount }
  | 0b01011 ->
      let amount = field w 10 3 in
      if amount > 4 || field w 22 2 <> 0 then Undefined w
      else Add_ext { sf; sub = bit w 30; s = bit w 29; rd; rn; rm; extend = extends.(field w 13 3); amount }
  | 0b11010 when field w 21 3 = 0 && field w 10 6 = 0 -> Adc { sf; sub = bit w 30; s = bit w 29; rd; rn; rm }
  | 0b11010 when field w 21 3 = 2 && bit w 29 && not (bit w 10) && not (bit w 4) ->
      Ccmp { sf; neg = not (bit w 30); rn; imm = bit w 11; rm; nzcv = field w 0 4; cond = conds.(field w 12 4) }
  | 0b11010 when field w 21 3 = 4 && not (bit w 29) && not (bit w 11) ->
      Csel { sf; inc = bit w 10; inv = bit w 30; rd; rn; rm; cond = conds.(field w 12 4) }
  | 0b11010 when field w 21 3 = 6 && not (bit w 29) && bit w 30 && rm = 0 ->
      (match field w 10 6, sf with
       | 0, _ -> Rbit { sf; rd; rn }
       | 1, _ -> Rev { sf; bytes = 2; rd; rn }
       | 2, W -> Rev { sf; bytes = 4; rd; rn }
       | 2, X -> Rev { sf; bytes = 4; rd; rn }
       | 3, X -> Rev { sf; bytes = 8; rd; rn }
       | 4, _ -> Clz { sf; cls = false; rd; rn }
       | 5, _ -> Clz { sf; cls = true; rd; rn }
       | _ -> Undefined w)
  | 0b11010 when field w 21 3 = 6 && not (bit w 29) && not (bit w 30) ->
      (match field w 10 6 with
       | 2 -> Div { sf; signed = false; rd; rn; rm }
       | 3 -> Div { sf; signed = true; rd; rn; rm }
       | 8 | 9 | 10 | 11 as k -> Shiftv { sf; shift = shifts.(k - 8); rd; rn; rm }
       | _ -> Undefined w)
  | 0b11011 when field w 29 2 = 0 ->
      let ra = field w 10 5 and o0 = bit w 15 in
      (match field w 21 3, sf with
       | 0, _ -> Madd { sf; sub = o0; rd; rn; rm; ra }
       | 1, X -> Maddl { signed = true; sub = o0; rd; rn; rm; ra }
       | 5, X -> Maddl { signed = false; sub = o0; rd; rn; rm; ra }
       | 2, X when not o0 -> Mulh { signed = true; rd; rn; rm }
       | 6, X when not o0 -> Mulh { signed = false; rd; rn; rm }
       | _ -> Undefined w)
  | _ -> Undefined w

let decode w =
  match field w 25 4 with
  | 0b1000 | 0b1001 -> dp_imm w
  | 0b1010 | 0b1011 -> branch w
  | 0b0100 | 0b0110 | 0b1100 | 0b1110 -> loadstore w
  | 0b0101 | 0b1101 -> dp_reg w
  | _ -> Undefined w

(*****************************************************************************)
(* Printing, as objdump does *)
(*****************************************************************************)

let reg_name sf ~sp r =
  match sf, r with
  | X, 31 -> if sp then "sp" else "xzr"
  | W, 31 -> if sp then "wsp" else "wzr"
  | X, r -> "x" ^ string_of_int r
  | W, r -> "w" ^ string_of_int r

let x r = reg_name X ~sp:false r
let xsp r = reg_name X ~sp:true r

let cond_name = function
  | EQ -> "eq" | NE -> "ne" | CS -> "cs" | CC -> "cc" | MI -> "mi" | PL -> "pl" | VS -> "vs" | VC -> "vc"
  | HI -> "hi" | LS -> "ls" | GE -> "ge" | LT -> "lt" | GT -> "gt" | LE -> "le" | AL -> "al" | NV -> "nv"

let invert c = conds.(let rec idx i = if conds.(i) = c then i else idx (i + 1) in idx 0 lxor 1)

let shift_name = function LSL -> "lsl" | LSR -> "lsr" | ASR -> "asr" | ROR -> "ror"

let extend_name = function
  | UXTB -> "uxtb" | UXTH -> "uxth" | UXTW -> "uxtw" | UXTX -> "uxtx"
  | SXTB -> "sxtb" | SXTH -> "sxth" | SXTW -> "sxtw" | SXTX -> "sxtx"

let logic_name invert = function
  | AND -> if invert then "bic" else "and"
  | ORR -> if invert then "orn" else "orr"
  | EOR -> if invert then "eon" else "eor"
  | ANDS -> if invert then "bics" else "ands"

(* a 64-bit address: objdump prints negative targets in 64 bits *)
let target a = Printf.sprintf "0x%Lx" (Int64.of_int a)

let hex v = Printf.sprintf "#0x%x" v
let hex64 v = Printf.sprintf "#0x%Lx" v
let dec v = Printf.sprintf "#%d" v

let shifted shift amount = if amount = 0 && shift = LSL then "" else Printf.sprintf ", %s #%d" (shift_name shift) amount

(* a value MOVZ or MOVN can load: the mov alias of ORR yields to them *)
let move_wide sf v =
  let v = Int64.logand v (ones (width sf)) in
  let one_chunk v = List.length (List.filter (fun k -> Int64.logand (Int64.shift_right_logical v (16 * k)) 0xffffL <> 0L)
                                   (List.init (width sf / 16) Fun.id)) <= 1 in
  one_chunk v || one_chunk (Int64.logand (Int64.lognot v) (ones (width sf)))

let print ~addr (i : t) =
  let m name args = if args = "" then name else name ^ "\t" ^ args in
  let args l = String.concat ", " l in
  match i with
  | Add_imm { sf; sub = false; s = false; rd; rn; imm = 0; lsl12 = false } when rd = 31 || rn = 31 ->
      m "mov" (args [ reg_name sf ~sp:true rd; reg_name sf ~sp:true rn ])
  | Add_imm { sf; sub; s; rd; rn; imm; lsl12 } ->
      let rest = hex imm ^ if lsl12 then ", lsl #12" else "" in
      if s && rd = 31 then m (if sub then "cmp" else "cmn") (args [ reg_name sf ~sp:true rn; rest ])
      else m ((if sub then "sub" else "add") ^ if s then "s" else "") (args [ reg_name sf ~sp:(not s) rd; reg_name sf ~sp:true rn; rest ])
  | Add_reg { sf; sub; s; rd; rn; rm; shift; amount } ->
      let r = reg_name sf ~sp:false in
      let rest = r rm ^ shifted shift amount in
      if s && rd = 31 then m (if sub then "cmp" else "cmn") (args [ r rn; rest ])
      else if sub && rn = 31 then m (if s then "negs" else "neg") (args [ r rd; rest ])
      else m ((if sub then "sub" else "add") ^ if s then "s" else "") (args [ r rd; r rn; rest ])
  | Add_ext { sf; sub; s; rd; rn; rm; extend; amount } ->
      let rm_sf = if sf = X && (extend = UXTX || extend = SXTX) then X else W in
      let as_lsl = (rn = 31 || ((not s) && rd = 31)) && extend = (if sf = X then UXTX else UXTW) in
      let ext =
        if as_lsl then (if amount = 0 then "" else Printf.sprintf ", lsl #%d" amount)
        else ", " ^ extend_name extend ^ if amount = 0 then "" else Printf.sprintf " #%d" amount in
      let rest = reg_name rm_sf ~sp:false rm ^ ext in
      if s && rd = 31 then m (if sub then "cmp" else "cmn") (args [ reg_name sf ~sp:true rn; rest ])
      else m ((if sub then "sub" else "add") ^ if s then "s" else "") (args [ reg_name sf ~sp:(not s) rd; reg_name sf ~sp:true rn; rest ])
  | Adc { sf; sub; s; rd; rn; rm } ->
      let r = reg_name sf ~sp:false in
      if sub && rn = 31 then m (if s then "ngcs" else "ngc") (args [ r rd; r rm ])
      else m ((if sub then "sbc" else "adc") ^ if s then "s" else "") (args [ r rd; r rn; r rm ])
  | Logic_imm { sf; op; rd; rn; imm } ->
      let value = hex64 imm in
      if op = ANDS && rd = 31 then m "tst" (args [ reg_name sf ~sp:false rn; value ])
      (* movz cannot write sp: mov then, whatever the value *)
      else if op = ORR && rn = 31 && (rd = 31 || not (move_wide sf imm)) then m "mov" (args [ reg_name sf ~sp:true rd; value ])
      else m (logic_name false op) (args [ reg_name sf ~sp:(op <> ANDS) rd; reg_name sf ~sp:false rn; value ])
  | Logic_reg { sf; op; invert; rd; rn; rm; shift; amount } ->
      let r = reg_name sf ~sp:false in
      if op = ORR && (not invert) && rn = 31 && amount = 0 && shift = LSL then m "mov" (args [ r rd; r rm ])
      else if op = ORR && invert && rn = 31 then m "mvn" (args [ r rd; r rm ^ shifted shift amount ])
      else if op = ANDS && (not invert) && rd = 31 then m "tst" (args [ r rn; r rm ^ shifted shift amount ])
      else m (logic_name invert op) (args [ r rd; r rn; r rm ^ shifted shift amount ])
  | Movz { sf; rd; imm16; hw } when not (imm16 = 0 && hw <> 0) ->
      m "mov" (args [ reg_name sf ~sp:false rd; hex64 (Int64.shift_left (Int64.of_int imm16) (16 * hw)) ])
  | Movn { sf; rd; imm16; hw } when not (imm16 = 0 && hw <> 0) && not (sf = W && imm16 = 0xffff) ->
      let v = Int64.logand (Int64.lognot (Int64.shift_left (Int64.of_int imm16) (16 * hw))) (ones (width sf)) in
      m "mov" (args [ reg_name sf ~sp:false rd; hex64 v ])
  | Movz { sf; rd; imm16; hw } | Movn { sf; rd; imm16; hw } | Movk { sf; rd; imm16; hw } ->
      let name = match i with Movz _ -> "movz" | Movn _ -> "movn" | _ -> "movk" in
      m name (args [ reg_name sf ~sp:false rd; hex imm16 ^ if hw = 0 then "" else Printf.sprintf ", lsl #%d" (16 * hw) ])
  | Sbfm { sf; rd; rn; immr; imms } | Ubfm { sf; rd; rn; immr; imms } | Bfm { sf; rd; rn; immr; imms } ->
      let r = reg_name sf ~sp:false and bits = width sf in
      let top = bits - 1 in
      let signed = (match i with Sbfm _ -> true | _ -> false) and ins = (match i with Bfm _ -> true | _ -> false) in
      let three name a b = m name (args [ r rd; r rn; dec a; dec b ]) in
      if ins then
        if imms < immr then (if rn = 31 then m "bfc" (args [ r rd; dec ((bits - immr) mod bits); dec (imms + 1) ])
                             else three "bfi" ((bits - immr) mod bits) (imms + 1))
        else three "bfxil" immr (imms - immr + 1)
      else if imms = top then m (if signed then "asr" else "lsr") (args [ r rd; r rn; dec immr ])
      else if (not signed) && imms + 1 = immr then m "lsl" (args [ r rd; r rn; dec (top - imms) ])
      else if immr = 0 && (imms = 7 || imms = 15 || (signed && imms = 31)) && (signed || sf = W) then
        m ((if signed then "sxt" else "uxt") ^ (match imms with 7 -> "b" | 15 -> "h" | _ -> "w")) (args [ r rd; reg_name W ~sp:false rn ])
      else if imms < immr then three (if signed then "sbfiz" else "ubfiz") ((bits - immr) mod bits) (imms + 1)
      else three (if signed then "sbfx" else "ubfx") immr (imms - immr + 1)
  | Extr { sf; rd; rn; rm; lsb } ->
      let r = reg_name sf ~sp:false in
      if rn = rm then m "ror" (args [ r rd; r rn; dec lsb ]) else m "extr" (args [ r rd; r rn; r rm; dec lsb ])
  | Adr { page; rd; offset } ->
      let t = if page then Int64.add (Int64.of_int (addr land lnot 0xfff)) (Int64.shift_left (Int64.of_int offset) 12)
              else Int64.of_int (addr + offset) in
      m (if page then "adrp" else "adr") (args [ x rd; Printf.sprintf "0x%Lx" t ])
  | Csel { sf; inc; inv; rd; rn; rm; cond } ->
      let r = reg_name sf ~sp:false in
      let ok = cond <> AL && cond <> NV in
      let c = cond_name (invert cond) in
      (match inc, inv with
       | true, false when ok && rn = 31 && rm = 31 -> m "cset" (args [ r rd; c ])
       | false, true when ok && rn = 31 && rm = 31 -> m "csetm" (args [ r rd; c ])
       | true, false when ok && rn = rm && rn <> 31 -> m "cinc" (args [ r rd; r rn; c ])
       | false, true when ok && rn = rm && rn <> 31 -> m "cinv" (args [ r rd; r rn; c ])
       | true, true when ok && rn = rm -> m "cneg" (args [ r rd; r rn; c ])
       | _ ->
           let name = match inc, inv with false, false -> "csel" | true, false -> "csinc" | false, true -> "csinv" | true, true -> "csneg" in
           m name (args [ r rd; r rn; r rm; cond_name cond ]))
  | Ccmp { sf; neg; rn; imm; rm; nzcv; cond } ->
      let r = reg_name sf ~sp:false in
      m (if neg then "ccmn" else "ccmp") (args [ r rn; (if imm then hex rm else r rm); hex nzcv; cond_name cond ])
  | Rbit { sf; rd; rn } -> m "rbit" (args [ reg_name sf ~sp:false rd; reg_name sf ~sp:false rn ])
  | Rev { sf; bytes; rd; rn } ->
      let name = if bytes = width sf / 8 then "rev" else "rev" ^ string_of_int (bytes * 8) in
      m name (args [ reg_name sf ~sp:false rd; reg_name sf ~sp:false rn ])
  | Clz { sf; cls; rd; rn } -> m (if cls then "cls" else "clz") (args [ reg_name sf ~sp:false rd; reg_name sf ~sp:false rn ])
  | Div { sf; signed; rd; rn; rm } ->
      let r = reg_name sf ~sp:false in m (if signed then "sdiv" else "udiv") (args [ r rd; r rn; r rm ])
  | Shiftv { sf; shift; rd; rn; rm } -> let r = reg_name sf ~sp:false in m (shift_name shift) (args [ r rd; r rn; r rm ])
  | Madd { sf; sub; rd; rn; rm; ra } ->
      let r = reg_name sf ~sp:false in
      if ra = 31 then m (if sub then "mneg" else "mul") (args [ r rd; r rn; r rm ])
      else m (if sub then "msub" else "madd") (args [ r rd; r rn; r rm; r ra ])
  | Maddl { signed; sub; rd; rn; rm; ra } ->
      let p = if signed then "s" else "u" and w = reg_name W ~sp:false in
      if ra = 31 then m (p ^ if sub then "mnegl" else "mull") (args [ x rd; w rn; w rm ])
      else m (p ^ if sub then "msubl" else "maddl") (args [ x rd; w rn; w rm; x ra ])
  | Mulh { signed; rd; rn; rm } -> m (if signed then "smulh" else "umulh") (args [ x rd; x rn; x rm ])
  | B { link; offset } -> m (if link then "bl" else "b") (target (addr + offset))
  | Bcond { cond; offset } -> m ("b." ^ cond_name cond) (target (addr + offset))
  | Cbz { sf; nz; rt; offset } -> m (if nz then "cbnz" else "cbz") (args [ reg_name sf ~sp:false rt; target (addr + offset) ])
  | Tbz { nz; rt; bit; offset } ->
      m (if nz then "tbnz" else "tbz") (args [ reg_name (if bit < 32 then W else X) ~sp:false rt; dec bit; target (addr + offset) ])
  | Br { link; rn } -> m (if link then "blr" else "br") (x rn)
  | Ret 30 -> "ret"
  | Ret rn -> m "ret" (x rn)
  | Mem { load; size; signed; rt; addr = a } ->
      let kind = match a with Base { mode = Unscaled; _ } -> "ur" | Base { mode = Unpriv; _ } -> "tr" | _ -> "r" in
      let suffix = (if signed <> None then "s" else "") ^ (match size with Byte -> "b" | Half -> "h" | Word when signed <> None -> "w" | _ -> "") in
      let name = (if load then "ld" else "st") ^ kind ^ suffix in
      let rsf = match signed, size with Some sf, _ -> sf | None, Dword -> X | None, _ -> W in
      let rt = reg_name rsf ~sp:false rt in
      let where = match a with
        | Literal off -> target (addr + off)
        | Base { rn; offset; mode = (Offset | Unscaled | Unpriv) } ->
            if offset = 0 then Printf.sprintf "[%s]" (xsp rn) else Printf.sprintf "[%s, #%d]" (xsp rn) offset
        | Base { rn; offset; mode = Pre } -> Printf.sprintf "[%s, #%d]!" (xsp rn) offset
        | Base { rn; offset; mode = Post } -> Printf.sprintf "[%s], #%d" (xsp rn) offset
        | Index { rn; rm; extend; s } ->
            let amount = match size with Byte -> 0 | Half -> 1 | Word -> 2 | Dword -> 3 in
            let rm_sf = if extend = UXTX || extend = SXTX then X else W in
            let ext = match extend, s with
              | UXTX, false -> ""
              | UXTX, true -> Printf.sprintf ", lsl #%d" amount
              | e, false -> ", " ^ extend_name e
              | e, true -> Printf.sprintf ", %s #%d" (extend_name e) amount in
            Printf.sprintf "[%s, %s%s]" (xsp rn) (reg_name rm_sf ~sp:false rm) ext in
      m name (args [ rt; where ])
  | Pair { load; sf; signed; rt; rt2; rn; offset; mode } ->
      let name = (if load then "ld" else "st") ^ (if mode = P_nontemporal then "np" else "p") ^ if signed then "sw" else "" in
      let rsf = if signed then X else sf in
      let where = match mode with
        | P_offset | P_nontemporal -> if offset = 0 then Printf.sprintf "[%s]" (xsp rn) else Printf.sprintf "[%s, #%d]" (xsp rn) offset
        | P_pre -> Printf.sprintf "[%s, #%d]!" (xsp rn) offset
        | P_post -> Printf.sprintf "[%s], #%d" (xsp rn) offset in
      m name (args [ reg_name rsf ~sp:false rt; reg_name rsf ~sp:false rt2; where ])
  | Svc imm -> m "svc" (hex imm)
  | Hvc imm -> m "hvc" (hex imm)
  | Smc imm -> m "smc" (hex imm)
  | Brk imm -> m "brk" (hex imm)
  | Nop -> "nop"
  | Hint h -> (match h with Yield -> "yield" | Wfe -> "wfe" | Wfi -> "wfi" | Sev -> "sev" | Sevl -> "sevl")
  | Mrs { rt; sr } -> m "mrs" (args [ x rt; sysreg_name sr ])
  | Msr { rt; sr } -> m "msr" (args [ sysreg_name sr; x rt ])
  | Msr_imm { field; imm } ->
      m "msr" (args [ (match field with Spsel -> "spsel" | Daifset -> "daifset" | Daifclr -> "daifclr"); hex imm ])
  | Sys { op; rt } ->
      let kind, name, reg = sysop op in
      m kind (if reg then args [ name; x rt ] else name)
  | Barrier { kind = (Dsb | Dmb) as k; option } ->
      let names = [| ""; "oshld"; "oshst"; "osh"; ""; "nshld"; "nshst"; "nsh"; "";
                     "ishld"; "ishst"; "ish"; ""; "ld"; "st"; "sy" |] in
      (match k, option with
       | Dsb, 0 -> "ssbb"
       | Dsb, 4 -> "pssbb"
       | _ ->
           let name = if k = Dsb then "dsb" else "dmb" in
           m name (if names.(option) = "" then hex option else names.(option)))
  | Barrier { kind = (Isb | Clrex) as k; option } ->
      let name = if k = Isb then "isb" else "clrex" in
      if option = 15 then name else m name (hex option)
  | Eret -> "eret"
  | Excl { load; size; ordered; exclusive; rs; rt; rn } ->
      let suffix = match size with Byte -> "b" | Half -> "h" | _ -> "" in
      let name = match load, exclusive, ordered with
        | true, true, _ -> (if ordered then "ldaxr" else "ldxr")
        | false, true, _ -> (if ordered then "stlxr" else "stxr")
        | true, false, true -> "ldar" | true, false, false -> "ldlar"
        | false, false, true -> "stlr" | false, false, false -> "stllr" in
      let r = reg_name (if size = Dword then X else W) ~sp:false rt and where = Printf.sprintf "[%s]" (xsp rn) in
      m (name ^ suffix) (args (if exclusive && not load then [ reg_name W ~sp:false rs; r; where ] else [ r; where ]))
  | Undefined w when w land 0xffff = w -> Printf.sprintf "udf\t#%d" w
  | Undefined w -> Printf.sprintf ".inst\t0x%08x" (Bits.unsigned32 w)

(*****************************************************************************)
(* Execution *)
(*****************************************************************************)

(* x0-x30 and sp (slot 31), boxed Int64 in an array: measured faster
 * than a Bytes read as Int64, whose every read boxes a new value
 * (bench64.py: 24.0 MIPS, against 17.9 with Bytes.get_int64_le and
 * 20.8 with the %caml_bytes_get64u primitive; plan_arm.md, decision 3) *)
type state = {
  x : int64 array;
  mutable n : bool;
  mutable z : bool;
  mutable c : bool;
  mutable v : bool;
  mutable next : int;
  mem : Memory.t;
  (* the privileged state (plan_pi.md, phase G) *)
  mutable el : int;
  mutable spsel : bool;
  sp_el : int64 array;
  mutable daif : int;
  elr : int64 array;
  spsr : int64 array;
  esr : int64 array;
  far : int64 array;
  vbar : int64 array;
  mutable mmu : bool;
  mutable translate : int64 -> int -> int;
  mutable read_sysreg : int -> int64;
  mutable write_sysreg : int -> int64 -> unit;
  mutable system : state -> t -> unit;
  mutable monitor : int;
}

exception Unimplemented of int * int
exception Abort of int64 * int

let create mem =
  let undefined _ = raise (Unimplemented (0, 0)) in
  { x = Array.make 32 0L; n = false; z = false; c = false; v = false; next = 0; mem;
    el = 0; spsel = false; sp_el = Array.make 4 0L; daif = 0;
    elr = Array.make 4 0L; spsr = Array.make 4 0L; esr = Array.make 4 0L; far = Array.make 4 0L; vbar = Array.make 4 0L;
    mmu = false; translate = (fun _ _ -> 0); read_sysreg = undefined; write_sysreg = (fun _ _ -> undefined ());
    system = (fun _ _ -> undefined ()); monitor = -1 }

let m32 = 0xffffffffL
let mask sf v = match sf with X -> v | W -> Int64.logand v m32

(* register 31 as the zero register, and as sp *)
let get st r = if r = 31 then 0L else Array.unsafe_get st.x r
let get_sp st r = Array.unsafe_get st.x r
let set st sf r v = if r <> 31 then Array.unsafe_set st.x r (mask sf v)
let set_sp st sf r v = Array.unsafe_set st.x r (mask sf v)

(* an address: user mode maps nothing at or above 4GB (Memory's
 * addresses are 32-bit, the web's ints too) *)
let address v =
  if Int64.shift_right_logical v 32 <> 0L then raise (Memory.Fault (Bits.mask32 (Int64.to_int v)))
  else Bits.mask32 (Int64.to_int v)

(* a program counter from a register and back: natively the whole
 * address (the kernel runs at 0xffffff80_00000000, a canonical address
 * a 63-bit int holds), under js_of_ocaml its low 32 bits *)
let wide = Sys.int_size > 32
let of_pc a = if wide then Int64.of_int a else Int64.logand (Int64.of_int a) 0xffffffffL
let jump st v = if st.mmu then Int64.to_int v else address v

(* the physical address of an access (bit 0 a write, bit 1 as user):
 * through the MMU at EL1 and EL0 when it is on *)
let[@inline] phys st v access =
  if st.mmu && st.el < 2 then st.translate v (if st.el = 0 then access lor 2 else access) else address v

let int32 v = Bits.mask32 (Int64.to_int v)
(* zero-extended: a word with bit 31 set is a negative int under
 * js_of_ocaml *)
let of32 w = Int64.logand (Int64.of_int w) m32
let of_address = of32
let sext bits v = Int64.shift_right (Int64.shift_left v (64 - bits)) (64 - bits)

let cond_passed st = function
  | EQ -> st.z | NE -> not st.z | CS -> st.c | CC -> not st.c | MI -> st.n | PL -> not st.n
  | VS -> st.v | VC -> not st.v | HI -> st.c && not st.z | LS -> (not st.c) || st.z
  | GE -> st.n = st.v | LT -> st.n <> st.v | GT -> (not st.z) && st.n = st.v | LE -> st.z || st.n <> st.v
  | AL | NV -> true

let set_nz st sf r =
  let r = mask sf r in
  st.n <- Int64.compare (sext (width sf) r) 0L < 0;
  st.z <- r = 0L

(* a + b + cin in the width, and its flags *)
let add_flags st sf a b cin =
  match sf with
  | W ->
      let a = int32 a and b = int32 b in
      let r = Bits.add32 a b cin in
      st.c <- Bits.carry32 a r cin; st.v <- Bits.overflow32 a b r;
      let r = of32 r in
      set_nz st W r; r
  | X ->
      let r = Int64.add (Int64.add a b) (Int64.of_int cin) in
      let u = Int64.unsigned_compare r a in
      set_nz st X r;
      st.c <- (if cin = 0 then u < 0 else u <= 0);
      st.v <- Int64.compare (Int64.logand (Int64.logxor a r) (Int64.logxor b r)) 0L < 0;
      r

let add_sub st sf ~sub ~s a b =
  let b = if sub then mask sf (Int64.lognot b) else b and cin = if sub then 1 else 0 in
  if s then add_flags st sf a b cin else mask sf (Int64.add (Int64.add a b) (Int64.of_int cin))

let shift_value sf v sh n =
  let v = mask sf v in
  match sh with
  | LSL -> mask sf (Int64.shift_left v n)
  | LSR -> Int64.shift_right_logical v n
  | ASR -> mask sf (Int64.shift_right (sext (width sf) v) n)
  | ROR -> if n = 0 then v else mask sf (Int64.logor (Int64.shift_right_logical v n) (Int64.shift_left v (width sf - n)))

let extend_value v e =
  match e with
  | UXTB -> Int64.logand v 0xffL | UXTH -> Int64.logand v 0xffffL | UXTW -> Int64.logand v m32 | UXTX | SXTX -> v
  | SXTB -> sext 8 v | SXTH -> sext 16 v | SXTW -> sext 32 v

(* the bitfield moves: bits S..R of the source (S >= R), or its low S+1
 * bits placed at width - R *)
let bitfield st sf ~rd ~rn ~immr:r ~imms:s ~signed ~keep =
  let w = width sf and src = get st rn in
  let field, len, pos = if s >= r then Int64.shift_right_logical src r, s - r + 1, 0 else src, s + 1, w - r in
  let f = Int64.logand field (ones len) in
  let f = if signed then sext len f else f in
  let bits = mask sf (Int64.shift_left f pos) in
  let result =
    if keep then
      let m = Int64.shift_left (ones len) pos in
      Int64.logor (Int64.logand (get st rd) (Int64.lognot m)) (Int64.logand bits m)
    else bits in
  set st sf rd result

(* the high 64 bits of a 128-bit product, from 32-bit halves *)
let umulh a b =
  let lo v = Int64.logand v m32 and hi v = Int64.shift_right_logical v 32 in
  let p0 = Int64.mul (lo a) (lo b) and p1 = Int64.mul (lo a) (hi b) and p2 = Int64.mul (hi a) (lo b) in
  let mid = Int64.add (Int64.add (hi p0) (lo p1)) (lo p2) in
  Int64.add (Int64.add (Int64.mul (hi a) (hi b)) (Int64.add (hi p1) (hi p2))) (hi mid)

let smulh a b =
  let h = umulh a b in
  let h = if Int64.compare a 0L < 0 then Int64.sub h b else h in
  if Int64.compare b 0L < 0 then Int64.sub h a else h

let count_leading sf v =
  let w = width sf in
  let rec go k = if k < 0 then w else if Int64.logand (Int64.shift_right_logical v k) 1L = 1L then w - 1 - k else go (k - 1) in
  go (w - 1)

let reverse_bytes sf v chunk =
  let w = width sf / 8 in
  let byte k = Int64.logand (Int64.shift_right_logical v (8 * k)) 0xffL in
  let r = ref 0L in
  for k = 0 to w - 1 do
    let base = k / chunk * chunk in
    let k' = base + (chunk - 1 - (k - base)) in
    r := Int64.logor !r (Int64.shift_left (byte k) (8 * k'))
  done;
  !r

let load st size signed a =
  let m = st.mem in
  let v, bits = match size with
    | Byte -> Int64.of_int (Memory.load8 m a), 8
    | Half -> Int64.of_int (Memory.load16 m a), 16
    | Word -> of32 (Memory.load32 m a), 32
    | Dword -> Memory.load64 m a, 64 in
  match signed with None -> v | Some sf -> mask sf (sext bits v)

let store st size a v =
  let m = st.mem in
  match size with
  | Byte -> Memory.store8 m a (Int64.to_int (Int64.logand v 0xffL))
  | Half -> Memory.store16 m a (Int64.to_int (Int64.logand v 0xffffL))
  | Word -> Memory.store32 m a (int32 v)
  | Dword -> Memory.store64 m a v

(*****************************************************************************)
(* Exception levels *)
(*****************************************************************************)

(* PSTATE as SPSR keeps it: N Z C V (31-28), D A I F (9-6), the level
 * (3-2), SP_ELx or SP_EL0 (0) *)
let pstate st =
  let b f k = if f then 1 lsl k else 0 in
  Int64.logor (of32 (b st.n 31 lor b st.z 30 lor b st.c 29 lor b st.v 28))
    (Int64.of_int ((st.daif lsl 6) lor (st.el lsl 2) lor (if st.spsel then 1 else 0)))

let set_flags st v =
  let b k = Int64.logand (Int64.shift_right_logical v k) 1L = 1L in
  st.n <- b 31; st.z <- b 30; st.c <- b 29; st.v <- b 28

(* the stack pointer, slot 31: SP_EL0, or the level's own when SPSel *)
let sp_index st = if st.spsel then st.el else 0

let enter st ~el ~spsel =
  st.sp_el.(sp_index st) <- st.x.(31);
  st.el <- el;
  st.spsel <- spsel && el > 0;
  st.x.(31) <- st.sp_el.(sp_index st)

(* an exception to EL1 (or the level it happens at, above): the vector
 * table's entry by where it comes from (the same level on SP_EL0 0x0,
 * on SP_ELx 0x200, a lower one 0x400) plus [offset] (0 synchronous,
 * 0x80 IRQ); SPSR and ELR keep what is returned to; ESR and FAR for a
 * synchronous one *)
let take st ~offset ~ret ?esr ?far () =
  let target = max 1 st.el in
  let base = if target > st.el then 0x400 else if st.spsel then 0x200 else 0 in
  st.spsr.(target) <- pstate st;
  st.elr.(target) <- of_pc ret;
  Option.iter (fun e -> st.esr.(target) <- e) esr;
  Option.iter (fun f -> st.far.(target) <- f) far;
  enter st ~el:target ~spsel:true;
  st.daif <- 0xf;
  st.monitor <- -1;
  st.next <- Int64.to_int (Int64.add st.vbar.(target) (Int64.of_int (base + offset)))

(* ESR's classes *)
let ec_unknown = 0x00 and ec_svc = 0x15 and ec_hvc = 0x16 and ec_smc = 0x17
and ec_iabort_lower = 0x20 and ec_iabort = 0x21 and ec_dabort_lower = 0x24 and ec_dabort = 0x25 and ec_brk = 0x3c

let syndrome ec iss = Int64.of_int ((ec lsl 26) lor (1 lsl 25) lor iss)

let eret st =
  let v = st.spsr.(st.el) and pc = st.elr.(st.el) in
  (* a return to AArch32 (M[4]): not this core's *)
  if Int64.logand v 0x10L <> 0L then raise (Unimplemented (0, st.next - 4));
  let m = Int64.to_int (Int64.logand v 0x3ffL) in
  set_flags st v;
  st.daif <- (m lsr 6) land 15;
  enter st ~el:((m lsr 2) land 3) ~spsel:(m land 1 = 1);
  st.monitor <- -1;
  st.next <- Int64.to_int pc

(* the registers the core keeps (the rest the board's): an EL1-3 one
 * read or written at a lower level is undefined, as are the EL1
 * registers at EL0 (all but op1 = 3's) *)
let level_of sr = match (sr lsr 11) land 7 with 4 -> 2 | 6 -> 3 | 3 -> 0 | _ -> 1

let read_sysreg st sr =
  if level_of sr > st.el then raise (Unimplemented (0, st.next - 4));
  match sysreg_name sr with
  | "nzcv" -> Int64.logand (pstate st) 0xf0000000L
  | "daif" -> Int64.of_int (st.daif lsl 6)
  | "currentel" -> Int64.of_int (st.el lsl 2)
  | "spsel" -> if st.spsel then 1L else 0L
  | "sp_el0" -> if sp_index st = 0 then st.x.(31) else st.sp_el.(0)
  | "sp_el1" -> st.sp_el.(1)
  | "sp_el2" -> st.sp_el.(2)
  | name ->
      let n = level_of sr in
      (match String.sub name 0 (String.length name - 4) with
       | "elr" -> st.elr.(n) | "spsr" -> st.spsr.(n) | "esr" -> st.esr.(n) | "far" -> st.far.(n) | "vbar" -> st.vbar.(n)
       | _ -> st.read_sysreg sr)

let write_sysreg st sr v =
  if level_of sr > st.el then raise (Unimplemented (0, st.next - 4));
  match sysreg_name sr with
  | "nzcv" -> set_flags st v
  | "daif" -> st.daif <- Int64.to_int (Int64.shift_right_logical v 6) land 15
  | "spsel" -> enter st ~el:st.el ~spsel:(Int64.logand v 1L = 1L)
  | "sp_el0" -> if sp_index st = 0 then st.x.(31) <- v else st.sp_el.(0) <- v
  | "sp_el1" -> st.sp_el.(1) <- v
  | "sp_el2" -> st.sp_el.(2) <- v
  | "currentel" -> raise (Unimplemented (0, st.next - 4))
  | name ->
      let n = level_of sr in
      (match String.sub name 0 (String.length name - 4) with
       | "elr" -> st.elr.(n) <- v | "spsr" -> st.spsr.(n) <- v | "esr" -> st.esr.(n) <- v
       | "far" -> st.far.(n) <- v | "vbar" -> st.vbar.(n) <- v
       | _ -> st.write_sysreg sr v)

let size_shift = function Byte -> 0 | Half -> 1 | Word -> 2 | Dword -> 3

let execute st ~addr ~svc i =
  st.next <- addr + 4;
  match i with
  | Undefined w -> raise (Unimplemented (w, addr))
  | Nop | Barrier _ -> ()
  | Mrs { rt; sr } -> set st X rt (read_sysreg st sr)
  | Msr { rt; sr } -> write_sysreg st sr (get st rt)
  | Msr_imm { field = Spsel; imm } -> if st.el = 0 then raise (Unimplemented (0, addr)) else enter st ~el:st.el ~spsel:(imm land 1 = 1)
  | Msr_imm { field = Daifset; imm } -> st.daif <- st.daif lor imm
  | Msr_imm { field = Daifclr; imm } -> st.daif <- st.daif land lnot imm
  | Eret -> if st.el = 0 then raise (Unimplemented (0, addr)) else eret st
  | Hint _ | Sys _ | Hvc _ | Smc _ | Brk _ -> st.system st i
  | Excl { load = true; size; exclusive; rt; rn; _ } ->
      let pa = phys st (get_sp st rn) 0 in
      if exclusive then st.monitor <- pa;
      set st (if size = Dword then X else W) rt (load st size None pa)
  | Excl { load = false; size; exclusive; rs; rt; rn; _ } ->
      let pa = phys st (get_sp st rn) 1 in
      if not exclusive then store st size pa (get st rt)
      else begin
        (* the monitor: set by the load, cleared by an exception, a
         * return, or this store *)
        let ok = st.monitor = pa in
        st.monitor <- -1;
        if ok then store st size pa (get st rt);
        set st W rs (if ok then 0L else 1L)
      end
  | Add_imm { sf; sub; s; rd; rn; imm; lsl12 } ->
      let b = Int64.of_int (if lsl12 then imm lsl 12 else imm) in
      let r = add_sub st sf ~sub ~s (get_sp st rn) b in
      if s then set st sf rd r else set_sp st sf rd r
  | Add_reg { sf; sub; s; rd; rn; rm; shift; amount } ->
      set st sf rd (add_sub st sf ~sub ~s (get st rn) (shift_value sf (get st rm) shift amount))
  | Add_ext { sf; sub; s; rd; rn; rm; extend; amount } ->
      let b = mask sf (Int64.shift_left (extend_value (get st rm) extend) amount) in
      let r = add_sub st sf ~sub ~s (get_sp st rn) b in
      if s then set st sf rd r else set_sp st sf rd r
  | Adc { sf; sub; s; rd; rn; rm } ->
      let b = if sub then mask sf (Int64.lognot (get st rm)) else get st rm in
      let cin = if st.c then 1 else 0 in
      let a = get st rn in
      set st sf rd (if s then add_flags st sf a b cin else Int64.add (Int64.add a b) (Int64.of_int cin))
  | Logic_imm { sf; op; rd; rn; imm } ->
      let a = get st rn in
      let r = match op with AND | ANDS -> Int64.logand a imm | ORR -> Int64.logor a imm | EOR -> Int64.logxor a imm in
      if op = ANDS then (set_nz st sf r; st.c <- false; st.v <- false; set st sf rd r) else set_sp st sf rd r
  | Logic_reg { sf; op; invert; rd; rn; rm; shift; amount } ->
      let b = shift_value sf (get st rm) shift amount in
      let b = if invert then Int64.lognot b else b in
      let a = get st rn in
      let r = match op with AND | ANDS -> Int64.logand a b | ORR -> Int64.logor a b | EOR -> Int64.logxor a b in
      if op = ANDS then (set_nz st sf r; st.c <- false; st.v <- false);
      set st sf rd r
  | Movz { sf; rd; imm16; hw } -> set st sf rd (Int64.shift_left (Int64.of_int imm16) (16 * hw))
  | Movn { sf; rd; imm16; hw } -> set st sf rd (Int64.lognot (Int64.shift_left (Int64.of_int imm16) (16 * hw)))
  | Movk { sf; rd; imm16; hw } ->
      let m = Int64.shift_left 0xffffL (16 * hw) in
      set st sf rd (Int64.logor (Int64.logand (get st rd) (Int64.lognot m)) (Int64.shift_left (Int64.of_int imm16) (16 * hw)))
  | Sbfm { sf; rd; rn; immr; imms } -> bitfield st sf ~rd ~rn ~immr ~imms ~signed:true ~keep:false
  | Ubfm { sf; rd; rn; immr; imms } -> bitfield st sf ~rd ~rn ~immr ~imms ~signed:false ~keep:false
  | Bfm { sf; rd; rn; immr; imms } -> bitfield st sf ~rd ~rn ~immr ~imms ~signed:false ~keep:true
  | Extr { sf; rd; rn; rm; lsb } ->
      let lo = mask sf (get st rm) and hi = get st rn in
      set st sf rd (if lsb = 0 then lo else Int64.logor (Int64.shift_right_logical lo lsb) (Int64.shift_left hi (width sf - lsb)))
  | Adr { page; rd; offset } ->
      let v = if page then Int64.add (of_pc (addr land lnot 0xfff)) (Int64.shift_left (Int64.of_int offset) 12)
              else Int64.add (of_pc addr) (Int64.of_int offset) in
      set st X rd v
  | Csel { sf; inc; inv; rd; rn; rm; cond } ->
      if cond_passed st cond then set st sf rd (get st rn)
      else
        let b = get st rm in
        let b = if inv then Int64.lognot b else b in
        set st sf rd (if inc then Int64.succ b else b)
  | Ccmp { sf; neg; rn; imm; rm; nzcv; cond } ->
      if cond_passed st cond then
        let b = if imm then Int64.of_int rm else get st rm in
        ignore (add_sub st sf ~sub:(not neg) ~s:true (get st rn) b)
      else begin
        st.n <- nzcv land 8 <> 0; st.z <- nzcv land 4 <> 0; st.c <- nzcv land 2 <> 0; st.v <- nzcv land 1 <> 0
      end
  | Rbit { sf; rd; rn } ->
      let v = get st rn and r = ref 0L in
      for k = 0 to width sf - 1 do
        if Int64.logand (Int64.shift_right_logical v k) 1L = 1L then r := Int64.logor !r (Int64.shift_left 1L (width sf - 1 - k))
      done;
      set st sf rd !r
  | Rev { sf; bytes; rd; rn } -> set st sf rd (reverse_bytes sf (get st rn) bytes)
  | Clz { sf; cls = false; rd; rn } -> set st sf rd (Int64.of_int (count_leading sf (mask sf (get st rn))))
  | Clz { sf; cls = true; rd; rn } ->
      let v = mask sf (get st rn) in
      (* the bits after the top one equal to it: the leading zeros of
       * v xor (v >> 1), less one *)
      let d = mask sf (Int64.logxor v (Int64.shift_right_logical v 1)) in
      let d = Int64.logand d (ones (width sf - 1)) in
      set st sf rd (Int64.of_int (count_leading sf d - 1))
  | Div { sf; signed; rd; rn; rm } ->
      let a = get st rn and b = get st rm in
      let r =
        if mask sf b = 0L then 0L
        else if signed then
          let ext v = if sf = W then sext 32 v else v in
          Int64.div (ext a) (ext b)
        else Int64.unsigned_div (mask sf a) (mask sf b) in
      set st sf rd r
  | Shiftv { sf; shift; rd; rn; rm } ->
      set st sf rd (shift_value sf (get st rn) shift (Int64.to_int (Int64.logand (get st rm) (Int64.of_int (width sf - 1)))))
  | Madd { sf; sub; rd; rn; rm; ra } ->
      let p = Int64.mul (get st rn) (get st rm) in
      set st sf rd (if sub then Int64.sub (get st ra) p else Int64.add (get st ra) p)
  | Maddl { signed; sub; rd; rn; rm; ra } ->
      let ext v = if signed then sext 32 v else Int64.logand v m32 in
      let p = Int64.mul (ext (get st rn)) (ext (get st rm)) in
      set st X rd (if sub then Int64.sub (get st ra) p else Int64.add (get st ra) p)
  | Mulh { signed; rd; rn; rm } -> set st X rd ((if signed then smulh else umulh) (get st rn) (get st rm))
  | B { link; offset } ->
      if link then set st X 30 (of_pc (addr + 4));
      st.next <- addr + offset
  | Bcond { cond; offset } -> if cond_passed st cond then st.next <- addr + offset
  | Cbz { sf; nz; rt; offset } -> if (mask sf (get st rt) <> 0L) = nz then st.next <- addr + offset
  | Tbz { nz; rt; bit; offset } ->
      if (Int64.logand (Int64.shift_right_logical (get st rt) bit) 1L = 1L) = nz then st.next <- addr + offset
  | Br { link; rn } ->
      let target = jump st (get st rn) in
      if link then set st X 30 (of_pc (addr + 4));
      st.next <- target
  | Ret rn -> st.next <- jump st (get st rn)
  | Mem { load = l; size; signed; rt; addr = a } ->
      let base, a', writeback = match a with
        | Literal off -> None, of_pc (addr + off), None
        | Base { rn; offset; mode = (Offset | Unscaled | Unpriv) } -> Some rn, Int64.add (get_sp st rn) (Int64.of_int offset), None
        | Base { rn; offset; mode = Pre } -> let v = Int64.add (get_sp st rn) (Int64.of_int offset) in Some rn, v, Some v
        | Base { rn; offset; mode = Post } -> Some rn, get_sp st rn, Some (Int64.add (get_sp st rn) (Int64.of_int offset))
        | Index { rn; rm; extend; s } ->
            let off = Int64.shift_left (extend_value (get st rm) extend) (if s then size_shift size else 0) in
            Some rn, Int64.add (get_sp st rn) off, None in
      let unpriv = match a with Base { mode = Unpriv; _ } -> 2 | _ -> 0 in
      let ea = phys st a' ((if l then 0 else 1) lor unpriv) in
      if l then begin
        let v = load st size signed ea in
        (match base, writeback with Some rn, Some wb -> set_sp st X rn wb | _ -> ());
        set st (match signed, size with Some sf, _ -> sf | None, Dword -> X | None, _ -> W) rt v
      end
      else begin
        store st size ea (get st rt);
        match base, writeback with Some rn, Some wb -> set_sp st X rn wb | _ -> ()
      end
  | Pair { load = l; sf; signed; rt; rt2; rn; offset; mode } ->
      let b = get_sp st rn in
      let moved = Int64.add b (Int64.of_int offset) in
      let va = match mode with P_post -> b | _ -> moved in
      let size = if sf = X && not signed then Dword else Word in
      let step = if size = Dword then 8L else 4L in
      let a1 = phys st va (if l then 0 else 1) and a2 = phys st (Int64.add va step) (if l then 0 else 1) in
      if l then begin
        let sg = if signed then Some X else None in
        let v1 = load st size sg a1 and v2 = load st size sg a2 in
        set st (if signed then X else sf) rt v1;
        set st (if signed then X else sf) rt2 v2
      end
      else begin
        store st size a1 (get st rt);
        store st size a2 (get st rt2)
      end;
      (match mode with P_pre | P_post -> set_sp st X rn moved | P_offset | P_nontemporal -> ())
  | Svc imm -> svc st imm
