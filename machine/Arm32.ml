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
  | Mrs of { cond : cond; rd : reg; spsr : bool }
  | Msr of { cond : cond; spsr : bool; fields : int; src : operand }
  | Coproc of { cond : cond; load : bool; cp : int; opc1 : int; crn : int; crm : int; opc2 : int; rd : reg }
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
        (* the status register: CPSR only, SPSR (bit 22) is privileged *)
        else if (not (bit w 21)) && field w 16 4 = 15 && field w 0 12 = 0 then Mrs { cond; rd; spsr = bit w 22 }
        else if bit w 21 && rd = 15 && field w 4 8 = 0 then Msr { cond; spsr = bit w 22; fields = rn; src = Sreg (field w 0 4, No_shift) }
        else Undefined w
    | 0 -> Dp { cond; op = dp_ops.(field w 21 4); s = bit w 20; rd; rn; op2 = shifted w }
    | 1 when field w 23 2 = 2 && field w 20 2 = 2 && rd = 15 && rn <> 0 ->
        Msr { cond; spsr = bit w 22; fields = rn; src = Imm { imm8 = field w 0 8; rot = field w 8 4 * 2 } }
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
    (* mcr, mrc to the system's coprocessors, 14 and 15 (10 and 11 are
     * VFP's; the others the Pi's cores lack) *)
    | 7 when bit w 4 && field w 9 3 = 7 ->
        Coproc { cond; load = bit w 20; cp = field w 8 4; opc1 = field w 21 3; crn = rn; crm = field w 0 4; opc2 = field w 5 3; rd }
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
      (* and it shows a zero offset when writing back *)
      let off = match off, offset with None, Off_imm 0 when writeback -> Some "#0" | o, _ -> o in
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
  | Mrs { cond; rd; spsr } -> m ("mrs" ^ cond_name cond) (reg_name rd ^ if spsr then ", SPSR" else ", CPSR")
  | Coproc { cond; load; cp; opc1; crn; crm; opc2; rd } ->
      m ((if load then "mrc" else "mcr") ^ cond_name cond)
        (Printf.sprintf "%d, %d, %s, cr%d, cr%d, {%d}" cp opc1 (if load && rd = 15 then "APSR_nzcv" else reg_name rd) crn crm opc2)
  | Msr { cond; spsr; fields; src } ->
      let names = String.concat "" (List.filter_map (fun (b, c) -> if fields land b <> 0 then Some c else None)
                                      [ 8, "f"; 4, "s"; 2, "x"; 1, "c" ]) in
      m ("msr" ^ cond_name cond) ((if spsr then "SPSR_" else "CPSR_") ^ names ^ ", " ^ operand_text src)
  | Svc { cond; imm } -> m ("svc" ^ cond_name cond) (Printf.sprintf "0x%08x" imm)
  | Undefined w -> Printf.sprintf ".word\t0x%08x" (Bits.unsigned32 w)

(*****************************************************************************)
(* Execution *)
(*****************************************************************************)

type state = {
  r : int array;
  mutable n : bool;
  mutable z : bool;
  mutable c : bool;
  mutable v : bool;
  mutable next : int;
  mem : Memory.t;
  (* the privileged state (a system's; user mode keeps usr and no MMU) *)
  mutable mode : int;
  mutable a_off : bool;
  mutable i_off : bool;
  mutable f_off : bool;
  banked : int array;
  fiq_banked : int array;
  spsr : int array;
  mutable mmu : bool;
  mutable translate : int -> int -> int;
  mutable coproc : state -> t -> unit;
  mutable vectors : int;
}

exception Unimplemented of int * int
exception Abort of int * int

let create mem =
  { r = Array.make 16 0; n = false; z = false; c = false; v = false; next = 0; mem;
    mode = 0x10; a_off = false; i_off = false; f_off = false;
    banked = Array.make 12 0; fiq_banked = Array.make 10 0; spsr = Array.make 6 0;
    mmu = false; translate = (fun a _ -> a); coproc = (fun st _ -> raise (Unimplemented (0, st.r.(15) - 8))); vectors = 0 }

(*****************************************************************************)
(* The privileged state: modes, banks, the CPSR, exceptions *)
(*****************************************************************************)

(* the modes' banks of r13 and r14: usr and sys share the first *)
let bank_of = function 0x13 -> 1 | 0x17 -> 2 | 0x1b -> 3 | 0x12 -> 4 | 0x11 -> 5 | _ -> 0

(* a mode change: the outgoing mode's r13, r14 (and r8-r12, for FIQ)
 * saved, the incoming one's put in their place *)
let set_mode st m =
  let old_b = bank_of st.mode and new_b = bank_of m in
  if old_b <> new_b then begin
    st.banked.(2 * old_b) <- st.r.(13); st.banked.((2 * old_b) + 1) <- st.r.(14);
    st.r.(13) <- st.banked.(2 * new_b); st.r.(14) <- st.banked.((2 * new_b) + 1);
    if (old_b = 5) <> (new_b = 5) then begin
      let save, load = if new_b = 5 then 0, 5 else 5, 0 in
      for k = 0 to 4 do st.fiq_banked.(save + k) <- st.r.(8 + k); st.r.(8 + k) <- st.fiq_banked.(load + k) done
    end
  end;
  st.mode <- m

let cpsr st =
  let b f k = if f then 1 lsl k else 0 in
  b st.n 31 lor b st.z 30 lor b st.c 29 lor b st.v 28 lor b st.a_off 8 lor b st.i_off 7 lor b st.f_off 6 lor st.mode

(* the CPSR written, its fields f s x c as masked: the flags always; the
 * masks and the mode only when privileged *)
let write_cpsr st v fields =
  if fields land 8 <> 0 then begin
    st.n <- (v lsr 31) land 1 = 1; st.z <- (v lsr 30) land 1 = 1;
    st.c <- (v lsr 29) land 1 = 1; st.v <- (v lsr 28) land 1 = 1
  end;
  if st.mode <> 0x10 then begin
    if fields land 2 <> 0 then st.a_off <- (v lsr 8) land 1 = 1;
    if fields land 1 <> 0 then begin
      st.i_off <- (v lsr 7) land 1 = 1; st.f_off <- (v lsr 6) land 1 = 1;
      set_mode st (v land 0x1f)
    end
  end

(* an exception return: the CPSR from the mode's SPSR *)
let restore_spsr st = let b = bank_of st.mode in if b <> 0 then write_cpsr st st.spsr.(b) 0xf

type exn_kind = Reset | Undefined_instruction | Supervisor_call | Prefetch_abort | Data_abort | Irq | Fiq

(* an exception taken: the CPSR into the new mode's SPSR, the return
 * address into its lr, interrupts masked, the vector *)
let take st kind ~ret =
  let m, off = match kind with
    | Reset -> 0x13, 0 | Undefined_instruction -> 0x1b, 4 | Supervisor_call -> 0x13, 8
    | Prefetch_abort -> 0x17, 0xc | Data_abort -> 0x17, 0x10 | Irq -> 0x12, 0x18 | Fiq -> 0x11, 0x1c in
  let saved = cpsr st in
  set_mode st m;
  st.spsr.(bank_of m) <- saved;
  st.r.(14) <- Bits.mask32 ret;
  st.i_off <- true;
  (match kind with Reset | Fiq -> st.f_off <- true | _ -> ());
  (match kind with Undefined_instruction | Supervisor_call -> () | _ -> st.a_off <- true);
  st.next <- Bits.mask32 (st.vectors + off)

(* an address through the MMU, when on: bit 0 of [w] a write, bit 1 as
 * user (ldrt) *)
let[@inline] phys st a w = if st.mmu then st.translate a w else a

(* the user mode's registers, from a privileged mode (ldm and stm with ^) *)
let get_user st k =
  if (k = 13 || k = 14) && bank_of st.mode <> 0 then st.banked.(k - 13)
  else if k >= 8 && k <= 12 && st.mode = 0x11 then st.fiq_banked.(k - 8)
  else st.r.(k)

let set_user st k v =
  if (k = 13 || k = 14) && bank_of st.mode <> 0 then st.banked.(k - 13) <- v
  else if k >= 8 && k <= 12 && st.mode = 0x11 then st.fiq_banked.(k - 8) <- v
  else st.r.(k) <- v

let cond_passed st = function
  | EQ -> st.z | NE -> not st.z | CS -> st.c | CC -> not st.c | MI -> st.n | PL -> not st.n
  | VS -> st.v | VC -> not st.v | HI -> st.c && not st.z | LS -> (not st.c) || st.z
  | GE -> st.n = st.v | LT -> st.n <> st.v | GT -> (not st.z) && st.n = st.v | LE -> st.z || st.n <> st.v | AL -> true

(* a register written; pc: a jump (ARM state only: bit 0 would be Thumb) *)
let[@inline] set st rd v =
  if rd = 15 then begin
    if v land 1 <> 0 then raise (Unimplemented (v, st.r.(15) - 8)) (* Thumb *)
    else st.next <- Bits.mask32 (v land lnot 3)
  end
  else st.r.(rd) <- v

(* the shifter's carry out, left here by [shift], [shifted_value] and
 * [operand] (returning a pair allocated one per instruction) *)
let carry_out = ref false

(* the shifter: a value, its carry out in [carry_out] *)
let shift st v sh n =
  let bitc k = (v lsr k) land 1 = 1 in
  match sh with
  | LSL ->
      if n = 0 then (carry_out := st.c; v)
      else if n < 32 then (carry_out := bitc (32 - n); Bits.lsl32 v n)
      else (carry_out := (n = 32 && bitc 0); 0)
  | LSR ->
      if n = 0 then (carry_out := st.c; v)
      else if n < 32 then (carry_out := bitc (n - 1); Bits.lsr32 v n)
      else (carry_out := (n = 32 && bitc 31); 0)
  | ASR ->
      if n = 0 then (carry_out := st.c; v)
      else if n < 32 then (carry_out := bitc (n - 1); Bits.asr32 v n)
      else (carry_out := bitc 31; Bits.asr32 v 31)
  | ROR ->
      if n = 0 then (carry_out := st.c; v)
      else
        let k = n land 31 in
        if k = 0 then (carry_out := bitc 31; v) else (carry_out := bitc (k - 1); Bits.ror32 v k)

let shifted_value st rm = function
  | No_shift -> carry_out := st.c; st.r.(rm)
  | By_imm (sh, n) -> shift st st.r.(rm) sh n
  | By_reg (sh, rs) -> shift st st.r.(rm) sh (st.r.(rs) land 0xff)
  | Rrx ->
      let v = st.r.(rm) in
      let r = Bits.mask32 ((if st.c then 1 lsl 31 else 0) lor Bits.lsr32 v 1) in
      carry_out := v land 1 = 1; r

let operand st = function
  | Imm { imm8; rot } ->
      let v = imm_value ~imm8 ~rot in
      carry_out := (if rot = 0 then st.c else (v lsr 31) land 1 = 1); v
  | Sreg (rm, sh) -> shifted_value st rm sh

let set_nz st r = st.n <- (r lsr 31) land 1 = 1; st.z <- r = 0

(* a + b + cin, the flags set when [s] *)
let add_flags st a b cin =
  let r = Bits.add32 a b cin in
  set_nz st r; st.c <- Bits.carry32 a r cin; st.v <- Bits.overflow32 a b r

let not32 b = Bits.mask32 (lnot b)

let execute st ~addr ~svc i =
  st.r.(15) <- Bits.mask32 (addr + 8);
  st.next <- Bits.mask32 (addr + 4);
  match i with
  | Undefined w -> raise (Unimplemented (w, addr))
  | Dp { cond; op; s; rd; rn; op2 } ->
      if cond_passed st cond then begin
        let b = operand st op2 in
        let a = st.r.(rn) in
        (* movs pc, subs pc: a result into pc and the CPSR from the SPSR,
         * the flags not set *)
        let return = s && rd = 15 && (match op with TST | TEQ | CMP | CMN -> false | _ -> true) in
        let s = s && not return in
        let logical r = if s then (set_nz st r; st.c <- !carry_out); set st rd r in
        let arith a b cin = (if s then add_flags st a b cin); set st rd (Bits.add32 a b cin) in
        let cin = if st.c then 1 else 0 in
        (match op with
        | AND -> logical (a land b)
        | EOR -> logical (a lxor b)
        | ORR -> logical (a lor b)
        | BIC -> logical (a land not32 b)
        | MOV -> logical b
        | MVN -> logical (not32 b)
        | ADD -> arith a b 0
        | ADC -> arith a b cin
        | SUB -> arith a (not32 b) 1
        | SBC -> arith a (not32 b) cin
        | RSB -> arith b (not32 a) 1
        | RSC -> arith b (not32 a) cin
        | TST -> set_nz st (a land b); st.c <- !carry_out
        | TEQ -> set_nz st (a lxor b); st.c <- !carry_out
        | CMP -> add_flags st a (not32 b) 1
        | CMN -> add_flags st a b 0);
        if return then restore_spsr st
      end
  | Mul { cond; s; rd; rm; rs; acc } ->
      if cond_passed st cond then begin
        let lo = Bits.mul32 st.r.(rm) st.r.(rs) in
        let r = match acc with Some ra -> Bits.mask32 (lo + st.r.(ra)) | None -> lo in
        if s then set_nz st r;
        set st rd r
      end
  | Mull { cond; s; signed; acc; rdlo; rdhi; rm; rs } ->
      if cond_passed st cond then begin
        let lo, hi = Bits.mul64 ~signed st.r.(rm) st.r.(rs) in
        let lo, hi =
          if acc then
            let l, c, _ = Bits.add_carry lo st.r.(rdlo) 0 in
            l, Bits.mask32 (hi + st.r.(rdhi) + if c then 1 else 0)
          else lo, hi in
        if s then (st.n <- (hi lsr 31) land 1 = 1; st.z <- lo = 0 && hi = 0);
        set st rdlo lo;
        set st rdhi hi
      end
  | Mem { cond; load; size; rd; rn; offset; up; index; writeback; user } ->
      if cond_passed st cond then begin
        let off = match offset with Off_imm n -> n | Off_reg (rm, sh) -> shifted_value st rm sh in
        let base = st.r.(rn) in
        let moved = Bits.mask32 (if up then base + off else base - off) in
        let a = match index with Pre -> moved | Post -> base in
        let m = st.mem in
        (* the accesses first (through the MMU when on), then the base
         * written back, then the register loaded (it wins over the
         * base): an abort leaves the registers as they were *)
        let u = if user then 2 else 0 in
        if load then begin
          let p = phys st a u in
          let v = match size with
            | Word -> Memory.load32 m p
            | Byte -> Memory.load8 m p
            | Half -> Memory.load16 m p
            | Sbyte -> Bits.mask32 (Bits.sign_extend 8 (Memory.load8 m p))
            | Shalf -> Bits.mask32 (Bits.sign_extend 16 (Memory.load16 m p))
            | Dword -> Memory.load32 m p in
          let v2 = if size = Dword then Memory.load32 m (phys st (Bits.mask32 (a + 4)) u) else 0 in
          if (index = Post || writeback) && rn <> 15 then st.r.(rn) <- moved;
          set st rd v;
          if size = Dword then set st (rd + 1) v2
        end
        else begin
          let p = phys st a (1 lor u) in
          let v = if rd = 15 then Bits.mask32 (addr + 8) else st.r.(rd) in
          (match size with
           | Word -> Memory.store32 m p v
           | Byte -> Memory.store8 m p v
           | Half | Sbyte | Shalf -> Memory.store16 m p v
           | Dword -> Memory.store32 m p v; Memory.store32 m (phys st (Bits.mask32 (a + 4)) (1 lor u)) st.r.(rd + 1));
          if (index = Post || writeback) && rn <> 15 then st.r.(rn) <- moved
        end
      end
  | Block { cond; load; rn; writeback; mode; regs; psr } ->
      if cond_passed st cond then begin
        (* with ^: the user mode's registers, or with pc loaded, an
         * exception return *)
        let returning = psr && load && regs land 0x8000 <> 0 in
        let user = psr && not returning in
        let count = let rec go k acc = if k = 16 then acc else go (k + 1) (acc + ((regs lsr k) land 1)) in go 0 0 in
        let base = st.r.(rn) in
        let start = match mode with
          | IA -> base | IB -> base + 4 | DA -> base - (4 * count) + 4 | DB -> base - (4 * count) in
        let final = match mode with IA | IB -> base + (4 * count) | DA | DB -> base - (4 * count) in
        let a = ref (Bits.mask32 start) in
        let loaded = ref [] in
        for k = 0 to 15 do
          if (regs lsr k) land 1 = 1 then begin
            if load then loaded := (k, Memory.load32 st.mem (phys st !a 0)) :: !loaded
            else Memory.store32 st.mem (phys st !a 1) (if user then get_user st k else st.r.(k));
            a := Bits.mask32 (!a + 4)
          end
        done;
        if writeback then st.r.(rn) <- Bits.mask32 final;
        List.iter (fun (k, v) -> if user then set_user st k v else set st k v) (List.rev !loaded);
        if returning then restore_spsr st
      end
  | Branch { cond; link; offset } ->
      if cond_passed st cond then begin
        if link then st.r.(14) <- Bits.mask32 (addr + 4);
        st.next <- Bits.mask32 (addr + 8 + offset)
      end
  | Bx { cond; link; rm } ->
      if cond_passed st cond then begin
        let target = st.r.(rm) in
        if link then st.r.(14) <- Bits.mask32 (addr + 4);
        set st 15 target
      end
  | Clz { cond; rd; rm } ->
      if cond_passed st cond then begin
        let v = st.r.(rm) in
        let rec go k = if k < 0 then 32 else if (v lsr k) land 1 = 1 then 31 - k else go (k - 1) in
        set st rd (go 31)
      end
  (* user mode sees N, Z, C, V and the mode (0x10, usr); it writes
   * only the flags *)
  | Mrs { cond; rd; spsr } ->
      if cond_passed st cond then set st rd (if spsr then st.spsr.(bank_of st.mode) else cpsr st)
  | Msr { cond; spsr; fields; src } ->
      if cond_passed st cond then begin
        let v = operand st src in
        if spsr then begin
          let b = bank_of st.mode in
          let mask = List.fold_left (fun acc (bit, m) -> if fields land bit <> 0 then acc lor m else acc) 0
                       [ 8, 0xff lsl 24; 4, 0xff lsl 16; 2, 0xff lsl 8; 1, 0xff ] in
          if b <> 0 then st.spsr.(b) <- Bits.mask32 ((st.spsr.(b) land lnot mask) lor (v land mask))
        end
        else write_cpsr st v fields
      end
  | Coproc { cond; _ } -> if cond_passed st cond then st.coproc st i
  | Svc { cond; imm } -> if cond_passed st cond then svc st imm
