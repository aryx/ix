(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Arm32.mli *)

type reg = int
type cond = EQ | NE | CS | CC | MI | PL | VS | VC | HI | LS | GE | LT | GT | LE | AL
type dp_op = AND | EOR | SUB | RSB | ADD | ADC | SBC | RSC | TST | TEQ | CMP | CMN | ORR | MOV | BIC | MVN
type shift = LSL | LSR | ASR | ROR
type shifted = No_shift | By_imm of shift * int | By_reg of shift * reg | Rrx
type operand = Imm of { imm8 : int; rot : int } | Sreg of reg * shifted
type size = Word | Byte | Half | Sbyte | Shalf | Dword
type offset = Off_imm of int | Off_reg of reg * shifted
type index = Pre | Post
type mode = IA | IB | DA | DB

type t =
  | Dp of { cond : cond; op : dp_op; s : bool; rd : reg; rn : reg; op2 : operand }
  | Mul of { cond : cond; s : bool; rd : reg; rm : reg; rs : reg; acc : reg option }
  | Mull of { cond : cond; s : bool; signed : bool; acc : bool; rdlo : reg; rdhi : reg; rm : reg; rs : reg }
  | Mem of { cond : cond; load : bool; size : size; rd : reg; rn : reg; offset : offset; up : bool; index : index; writeback : bool; user : bool }
  | Block of { cond : cond; load : bool; rn : reg; writeback : bool; mode : mode; regs : int; psr : bool }
  | Branch of { cond : cond; link : bool; offset : int }
  | Bx of { cond : cond; link : bool; rm : reg }
  | Clz of { cond : cond; rd : reg; rm : reg }
  | Svc of { cond : cond; imm : int }
  | Undefined of int

let field = Bits.field
let bit = Bits.bit

let conds = [| EQ; NE; CS; CC; MI; PL; VS; VC; HI; LS; GE; LT; GT; LE; AL |]
let dp_ops = [| AND; EOR; SUB; RSB; ADD; ADC; SBC; RSC; TST; TEQ; CMP; CMN; ORR; MOV; BIC; MVN |]
let shifts = [| LSL; LSR; ASR; ROR |]

(*****************************************************************************)
(* Decoding *)
(*****************************************************************************)

(* a register shifted by an immediate (bit 4 = 0) or by a register *)
let shifted w =
  let rm = field w 0 4 and sh = shifts.(field w 5 2) in
  if bit w 4 then Sreg (rm, By_reg (sh, field w 8 4))
  else
    let n = field w 7 5 in
    Sreg (rm, match sh, n with
      | LSL, 0 -> No_shift
      | (LSR | ASR), 0 -> By_imm (sh, 32)
      | ROR, 0 -> Rrx
      | _ -> By_imm (sh, n))

let offset_of = function Sreg (rm, s) -> Off_reg (rm, s) | Imm _ -> assert false

let decode w =
  let cond_bits = field w 28 4 in
  if cond_bits = 15 then Undefined w
  else
    let cond = conds.(cond_bits) in
    let rn = field w 16 4 and rd = field w 12 4 in
    match field w 25 3 with
    | 0 when field w 4 4 = 0b1001 && field w 22 3 = 0 ->
        Mul { cond; s = bit w 20; rd = rn; rm = field w 0 4; rs = field w 8 4; acc = (if bit w 21 then Some rd else None) }
    | 0 when field w 4 4 = 0b1001 && field w 23 2 = 1 ->
        Mull { cond; s = bit w 20; signed = bit w 22; acc = bit w 21; rdhi = rn; rdlo = rd; rm = field w 0 4; rs = field w 8 4 }
    | 0 when field w 4 4 = 0b1001 -> Undefined w
    | 0 when bit w 7 && bit w 4 ->
        (* halfwords, signed bytes, doublewords *)
        let load = bit w 20 in
        let size = match field w 5 2, load with
          | 1, _ -> Some Half
          | 2, true -> Some Sbyte
          | 3, true -> Some Shalf
          | (2 | 3), false -> Some Dword
          | _ -> None in
        (match size with
         | None -> Undefined w
         (* a register offset leaves bits 11-8 zero *)
         | Some _ when (not (bit w 22)) && field w 8 4 <> 0 -> Undefined w
         | Some size ->
             let offset = if bit w 22 then Off_imm ((field w 8 4 lsl 4) lor field w 0 4) else Off_reg (field w 0 4, No_shift) in
             (* ldrd and strd: bit 5 says which (strd when set) *)
             let load = if size = Dword then not (bit w 5) else load in
             Mem { cond; load; size; rd; rn; offset; up = bit w 23; index = (if bit w 24 then Pre else Post);
                   writeback = bit w 24 && bit w 21; user = (not (bit w 24)) && bit w 21 && size <> Dword })
    | 0 when field w 23 2 = 2 && not (bit w 20) ->
        (* miscellaneous: bx, blx, clz (TST..CMN without S) *)
        if field w 4 4 = 1 && field w 21 2 = 1 && field w 8 12 = 0xfff then Bx { cond; link = false; rm = field w 0 4 }
        else if field w 4 4 = 3 && field w 21 2 = 1 && field w 8 12 = 0xfff then Bx { cond; link = true; rm = field w 0 4 }
        else if field w 4 4 = 1 && field w 21 2 = 3 && field w 16 4 = 15 && field w 8 4 = 15 then Clz { cond; rd; rm = field w 0 4 }
        else Undefined w
    | 0 -> Dp { cond; op = dp_ops.(field w 21 4); s = bit w 20; rd; rn; op2 = shifted w }
    | 1 when field w 23 2 = 2 && not (bit w 20) -> Undefined w
    | 1 -> Dp { cond; op = dp_ops.(field w 21 4); s = bit w 20; rd; rn; op2 = Imm { imm8 = field w 0 8; rot = field w 8 4 * 2 } }
    | (2 | 3) as c ->
        if c = 3 && bit w 4 then Undefined w
        else
          let offset = if c = 2 then Off_imm (field w 0 12) else offset_of (shifted w) in
          let pre = bit w 24 in
          Mem { cond; load = bit w 20; size = (if bit w 22 then Byte else Word); rd; rn; offset; up = bit w 23;
                index = (if pre then Pre else Post); writeback = pre && bit w 21; user = (not pre) && bit w 21 }
    | 4 ->
        let mode = match bit w 24, bit w 23 with false, true -> IA | true, true -> IB | false, false -> DA | true, false -> DB in
        Block { cond; load = bit w 20; rn; writeback = bit w 21; mode; regs = field w 0 16; psr = bit w 22 }
    | 5 -> Branch { cond; link = bit w 24; offset = Bits.sign_extend 24 (field w 0 24) * 4 }
    | 7 when bit w 24 -> Svc { cond; imm = field w 0 24 }
    | _ -> Undefined w

(*****************************************************************************)
(* Printing, as objdump does *)
(*****************************************************************************)

let reg_name = function
  | 10 -> "sl" | 11 -> "fp" | 12 -> "ip" | 13 -> "sp" | 14 -> "lr" | 15 -> "pc"
  | r -> "r" ^ string_of_int r

let cond_name = function
  | EQ -> "eq" | NE -> "ne" | CS -> "cs" | CC -> "cc" | MI -> "mi" | PL -> "pl" | VS -> "vs" | VC -> "vc"
  | HI -> "hi" | LS -> "ls" | GE -> "ge" | LT -> "lt" | GT -> "gt" | LE -> "le" | AL -> ""

let op_name = function
  | AND -> "and" | EOR -> "eor" | SUB -> "sub" | RSB -> "rsb" | ADD -> "add" | ADC -> "adc" | SBC -> "sbc" | RSC -> "rsc"
  | TST -> "tst" | TEQ -> "teq" | CMP -> "cmp" | CMN -> "cmn" | ORR -> "orr" | MOV -> "mov" | BIC -> "bic" | MVN -> "mvn"

let shift_name = function LSL -> "lsl" | LSR -> "lsr" | ASR -> "asr" | ROR -> "ror"

let imm_value ~imm8 ~rot = Bits.ror32 imm8 rot

let shifted_text = function
  | No_shift -> ""
  | By_imm (s, n) -> Printf.sprintf ", %s #%d" (shift_name s) n
  | By_reg (s, r) -> Printf.sprintf ", %s %s" (shift_name s) (reg_name r)
  | Rrx -> ", rrx"

(* the value, unless a smaller rotation encodes it: then objdump shows
 * the encoding, "#imm8, rot" (binutils' arm-dis.c) *)
let operand_text = function
  | Imm { imm8; rot } ->
      let a = imm_value ~imm8 ~rot in
      let rec smallest i = if i >= 32 || Bits.ule32 (Bits.ror32 a (32 - i)) 0xff then i else smallest (i + 2) in
      if smallest 0 <> rot then Printf.sprintf "#%d, %d" imm8 rot
      else Printf.sprintf "#%d" (Bits.signed32 a)
  | Sreg (rm, s) -> reg_name rm ^ shifted_text s

let reglist regs =
  "{" ^ String.concat ", " (List.filter_map (fun r -> if regs land (1 lsl r) <> 0 then Some (reg_name r) else None) (List.init 16 Fun.id)) ^ "}"

let print ~addr (i : t) =
  let m name args = if args = "" then name else name ^ "\t" ^ args in
  match i with
  | Dp { cond; op = MOV; s; rd; op2 = Sreg (rm, ((By_imm _ | By_reg _ | Rrx) as sh)); _ } ->
      (* a shifted move is its shift's own mnemonic *)
      let name, rest = match sh with
        | By_imm (sh, n) -> shift_name sh, Printf.sprintf "#%d" n
        | By_reg (sh, r) -> shift_name sh, reg_name r
        | Rrx -> "rrx", ""
        | No_shift -> assert false in
      m (name ^ (if s then "s" else "") ^ cond_name cond)
        (reg_name rd ^ ", " ^ reg_name rm ^ (if rest = "" then "" else ", " ^ rest))
  | Dp { cond; op; s; rd; rn; op2 } ->
      let name = op_name op in
      (match op with
       | TST | TEQ | CMP | CMN -> m (name ^ cond_name cond) (reg_name rn ^ ", " ^ operand_text op2)
       | MOV | MVN -> m (name ^ (if s then "s" else "") ^ cond_name cond) (reg_name rd ^ ", " ^ operand_text op2)
       | _ -> m (name ^ (if s then "s" else "") ^ cond_name cond) (reg_name rd ^ ", " ^ reg_name rn ^ ", " ^ operand_text op2))
  | Mul { cond; s; rd; rm; rs; acc } ->
      let name = (match acc with Some _ -> "mla" | None -> "mul") ^ (if s then "s" else "") ^ cond_name cond in
      m name (String.concat ", " (List.map reg_name ([ rd; rm; rs ] @ Option.to_list acc)))
  | Mull { cond; s; signed; acc; rdlo; rdhi; rm; rs } ->
      let name = (if signed then "s" else "u") ^ (if acc then "mlal" else "mull") ^ (if s then "s" else "") ^ cond_name cond in
      m name (String.concat ", " (List.map reg_name [ rdlo; rdhi; rm; rs ]))
  | Mem { cond; load = false; size = Word; rd; rn = 13; offset = Off_imm 4; up = false; index = Pre; writeback = true; _ } ->
      m ("push" ^ cond_name cond) (reglist (1 lsl rd))
  | Mem { cond; load = true; size = Word; rd; rn = 13; offset = Off_imm 4; up = true; index = Post; user = false; _ } ->
      m ("pop" ^ cond_name cond) (reglist (1 lsl rd))
  | Mem { cond; load; size; rd; rn; offset; up; index; writeback; user } ->
      let name = (if load then "ldr" else "str")
                 ^ (match size with Word -> "" | Byte -> "b" | Half -> "h" | Sbyte -> "sb" | Shalf -> "sh" | Dword -> "d")
                 ^ (if user then "t" else "")
                 ^ cond_name cond in
      let sign = if up then "" else "-" in
      let off = match offset with
        | Off_imm 0 when up -> None
        | Off_imm n -> Some (Printf.sprintf "#%s%d" sign n)
        | Off_reg (rm, s) -> Some (sign ^ reg_name rm ^ shifted_text s) in
      (* objdump names ldrd's first register only *)
      let rds = reg_name rd in
      (* objdump drops the "!" of a halfword or doubleword transfer based
       * on pc (writing back to pc is unpredictable) *)
      let extra = size <> Word && size <> Byte in
      let writeback = writeback && not (rn = 15 && extra && (match offset with Off_imm _ -> true | Off_reg _ -> false)) in
      (* and it shows a halfword's zero offset when writing back *)
      let off = match off, offset with None, Off_imm 0 when extra && writeback -> Some "#0" | o, _ -> o in
      let addr_text = match index, off with
        | Pre, None -> Printf.sprintf "[%s]%s" (reg_name rn) (if writeback then "!" else "")
        | Pre, Some o -> Printf.sprintf "[%s, %s]%s" (reg_name rn) o (if writeback then "!" else "")
        | Post, None -> Printf.sprintf "[%s], #0" (reg_name rn)
        | Post, Some o -> Printf.sprintf "[%s], %s" (reg_name rn) o in
      m name (rds ^ ", " ^ addr_text)
  | Block { cond; load = true; rn = 13; writeback = true; mode = IA; regs; psr = false } when regs land (regs - 1) <> 0 ->
      m ("pop" ^ cond_name cond) (reglist regs)
  | Block { cond; load = false; rn = 13; writeback = true; mode = DB; regs; psr = false } when regs land (regs - 1) <> 0 ->
      m ("push" ^ cond_name cond) (reglist regs)
  | Block { cond; load; rn; writeback; mode; regs; psr } ->
      (* objdump's older names in two cases: a single register from sp!
       * (ldmfd, stmfd), and a store incrementing after with writeback
       * (stmia) *)
      let single_sp = rn = 13 && writeback && not psr && regs land (regs - 1) = 0 in
      let suffix = match mode, load with
        | IA, true when single_sp -> "fd"
        | DB, false when single_sp -> "fd"
        | IA, false when writeback || psr -> "ia"
        | IA, _ -> "" | IB, _ -> "ib" | DA, _ -> "da" | DB, _ -> "db" in
      let name = (if load then "ldm" else "stm") ^ suffix ^ cond_name cond in
      m name (reg_name rn ^ (if writeback then "!" else "") ^ ", " ^ reglist regs ^ (if psr then "^" else ""))
  | Branch { cond; link; offset } ->
      m ((if link then "bl" else "b") ^ cond_name cond) (Bits.to_hex32 (addr + 8 + offset))
  | Bx { cond; link; rm } -> m ((if link then "blx" else "bx") ^ cond_name cond) (reg_name rm)
  | Clz { cond; rd; rm } -> m ("clz" ^ cond_name cond) (reg_name rd ^ ", " ^ reg_name rm)
  | Svc { cond; imm } -> m ("svc" ^ cond_name cond) (Printf.sprintf "0x%08x" imm)
  | Undefined w -> Printf.sprintf ".word\t0x%08x" (Bits.unsigned32 w)
