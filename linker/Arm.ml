(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Arm.mli *)

open Link
module A = Asm

(*****************************************************************************)
(* Registers, conditions, suffixes (5l's l.h, 5.out.h; 5a's lex.c) *)
(*****************************************************************************)

let reg_tmp = 11 and reg_sb = 12 and reg_sp = 13 and reg_link = 14 and reg_pc = 15
let big = 4092        (* R12 is the data's start + BIG: 5l's setR12 *)

let c_sbit = 1 lsl 4 and c_pbit = 1 lsl 5 and c_wbit = 1 lsl 6 and c_ubit = 1 lsl 7
let always = 14

let conditions = [ "EQ"; "NE"; "HS"; "LO"; "MI"; "PL"; "VS"; "VC"; "HI"; "LS"; "GE"; "LT"; "GT"; "LE"; "AL" ]
let condition s = match s with "CS" -> Some 2 | "CC" -> Some 3 | _ ->
  let rec find i = function [] -> None | c :: _ when c = s -> Some i | _ :: rest -> find (i + 1) rest in
  find 0 conditions

(* 5a's suffixes: a condition replaces the low 4 bits, the rest are ORed *)
let scond (p : prog) =
  List.fold_left (fun sc s ->
    match condition s with
    | Some c -> (sc land lnot 15) lor c
    | None ->
        sc lor (match s with
          | "S" -> c_sbit | "P" -> c_pbit | "W" -> c_wbit | "U" -> c_ubit
          | "IB" -> c_pbit lor c_ubit | "IA" -> c_ubit | "DB" -> c_pbit | "DA" -> 0
          | "PW" | "WP" | "DBW" -> c_wbit lor c_pbit | "IBW" -> c_wbit lor c_pbit lor c_ubit
          | "IAW" -> c_wbit lor c_ubit | "DAW" -> c_wbit
          | _ -> let f, l = p.where in error "%s:%d: unknown suffix .%s" f l s)) always p.suffixes

let branches = [ "B"; "BL"; "BEQ"; "BNE"; "BHS"; "BLO"; "BMI"; "BPL"; "BVS"; "BVC"; "BHI"; "BLS"; "BGE"; "BLT"; "BGT"; "BLE"; "BCASE" ]

(* an instruction as 5l sees it: opcode, condition, from, middle register, to *)
type view = { as_ : string; sc : int; from : A.operand option; reg : int option; to_ : A.operand option }

let view (p : prog) : view =
  let as_ = p.op in
  let sc = scond p in
  (* a branch to a name is to its TEXT (resolved), a C_BRANCH *)
  let args = List.map (function A.Mem { base = SB; _ } when List.mem as_ branches && p.target <> None -> A.Target 0 | a -> a) p.args in
  let v from reg to_ = { as_; sc; from; reg; to_ } in
  match as_, args with
  | ("CMP" | "CMN" | "TST" | "TEQ"), [ a; A.Reg r ] | ("CMPF" | "CMPD"), [ a; A.FReg r ] -> v (Some a) (Some r) None
  | "CASE", [ a ] -> v (Some a) None None
  | _, [ a ] -> v None None (Some a)
  | _, [ a; b ] -> v (Some a) None (Some b)
  | _, [ a; (A.Reg r | A.FReg r); c ] -> v (Some a) (Some r) (Some c)
  | _, [] -> v None None None
  | _ -> let f, l = p.where in error "%s:%d: %s: bad operands" f l as_

(*****************************************************************************)
(* Operand classes (5l's m.h C_xxx, span.c's aclass, cmp) *)
(*****************************************************************************)

(* in 5l's order, which decides which rule matches first *)
type cls = NONE | REG | BRANCH | RCON | NCON | LCON | HOREG | FOREG | HFOREG | SOREG | LOREG | ROREG | SROREG
  | HEXT | FEXT | HFEXT | SEXT | LEXT | HAUTO | FAUTO | HFAUTO | SAUTO | LAUTO | RECON | RACON | LACON
  | SHIFT | ADDR | FREG | FCON | FCR | REGREG | PSR | GOK
[@@warning "-37"]

(* 5l's cmp: may a rule's class [a] take an operand of class [b] *)
let rec cmp a b =
  a = b
  || match a with
     | LCON -> b = RCON || b = NCON
     | SROREG -> cmp SOREG b || cmp ROREG b
     | SOREG | ROREG -> b = SROREG || cmp HFOREG b
     | LOREG -> cmp SROREG b
     | SEXT -> cmp HFEXT b
     | LEXT -> cmp SEXT b
     | SAUTO -> cmp HFAUTO b
     | LAUTO -> cmp SAUTO b
     | LACON -> b = RACON
     | HFEXT -> b = HEXT || b = FEXT
     | FEXT | HEXT -> b = HFEXT
     | HFAUTO -> b = HAUTO || b = FAUTO
     | FAUTO | HAUTO -> b = HFAUTO
     | HFOREG -> b = HOREG || b = FOREG
     | FOREG | HOREG -> b = HFOREG
     | _ -> false

(* 5l's immrot: v as an 8-bit value rotated by an even amount. goken
 * computes it in a 64-bit ulong on today's hosts, where the rotation
 * never comes back to 32 bits: only 0..255 fit (checked: 5l puts 0x400
 * in a literal pool). TinyLd does the same, to be byte-identical; with
 * [rotate], it does the real 32-bit rotation, as ARM can *)
let rotate = ref false

let immrot v =
  if !rotate then begin
    let v = ref (v land 0xffffffff) and r = ref None in
    for i = 0 to 15 do
      if !r = None && !v land lnot 0xff = 0 then r := Some ((1 lsl 25) lor (i lsl 8) lor !v);
      v := ((!v lsl 2) lor (!v lsr 30)) land 0xffffffff
    done;
    !r
  end
  else if v >= 0 && v <= 0xff then Some ((1 lsl 25) lor v)
  else None

(* FPA's immediates, by their bits: -0 is none (5l's chipfloat) *)
let chip_float x =
  let rec find i = function
    | [] -> None
    | c :: rest -> if Int64.bits_of_float c = Int64.bits_of_float x then Some i else find (i + 1) rest
  in
  find 0 [ 0.; 1.; 2.; 3.; 4.; 5.; 0.5; 10. ]

let immaddr v =
  if v >= 0 && v <= 0xfff then (v land 0xfff) lor (1 lsl 24) lor (1 lsl 23)
  else if v < 0 && v >= -0xfff then (- v land 0xfff) lor (1 lsl 24)
  else 0

let immhalf v = (v >= 0 && v <= 0xff) || (v >= -0xff && v < 0)
let immfloat t = t land 0xc03 = 0

(* 5a keeps constants in 32 bits, sign-extended *)
let sx32 n = let v = Int64.to_int n land 0xffffffff in if v land 0x80000000 <> 0 then v - 0x100000000 else v

type ctx = { t : Link.t; mutable autosize : int }

let sym ctx (p : prog) n = let s = sym_of ctx.t p.version n in
  if s.kind = Undefined then (let f, l = p.where in error "%s:%d: undefined: %s" f l n.A.sym);
  s

(* an offset from a register: the classes by what fits *)
let oreg_class v hext fext hfext sext lext =
  let t = immaddr v in
  if t <> 0 then (if immfloat t then (if immhalf v then hfext else fext) else if immhalf v then hext else sext) else lext

(* 5l's aclass: the class, and the value (instoffset) *)
let aclass ctx (p : prog) (a : A.operand option) : cls * int =
  match a with
  | None -> NONE, 0
  | Some (A.Reg _) -> REG, 0
  | Some (A.Target _) -> BRANCH, 0
  | Some (A.Imm n) ->
      let v = sx32 n in
      (if immrot v <> None then RCON else if immrot (lnot v) <> None then NCON else LCON), v
  | Some (A.Regs rs) -> let v = List.fold_left (fun m r -> m lor (1 lsl r)) 0 rs in (if immrot v <> None then RCON else if immrot (lnot v) <> None then NCON else LCON), v
  | Some (A.Mem { base = R _; name = None; off; index = None }) ->
      let v = sx32 off in
      let t = immaddr v in
      (if t <> 0 then (if immfloat t then (if immhalf v then HFOREG else FOREG) else if immhalf v then HOREG else if immrot v <> None then SROREG else SOREG)
       else if immrot v <> None then ROREG else LOREG), v
  | Some (A.Mem { base = SB; name = Some n; off; _ }) ->
      let s = sym ctx p n in
      let v = s.value + sx32 off - big in
      oreg_class v HEXT FEXT HFEXT SEXT LEXT, v
  | Some (A.Mem { base = (SP | FP) as b; off; _ }) ->
      let v = ctx.autosize + sx32 off + (if b = FP then 4 else 0) in
      oreg_class v HAUTO FAUTO HFAUTO SAUTO LAUTO, v
  | Some (A.Addr { base = SB; name = Some n; off; _ }) -> (
      let s = sym ctx p n in
      match s.kind with
      | Text -> LCON, s.value + sx32 off
      | _ ->
          let v = s.value + sx32 off - big in
          if immrot v <> None && v <> 0 then RECON, v else LCON, s.value + sx32 off + ctx.t.data_start)
  | Some (A.Addr { base = (SP | FP) as b; off; _ }) ->
      let v = ctx.autosize + sx32 off + (if b = FP then 4 else 0) in
      (if immrot v <> None then RACON else LACON), v
  | Some (A.Addr { base = R _; off; _ }) -> let v = sx32 off in (if immrot v <> None then RACON else LACON), v
  | Some (A.Shifted _) | Some (A.Mem { index = Some _; _ }) -> SHIFT, 0
  | Some (A.Pair _) -> REGREG, 0
  | Some (A.FReg _) -> FREG, 0
  | Some (A.Fimm _) -> FCON, 0
  | Some (A.Special ("CPSR" | "SPSR")) -> PSR, 0
  | Some (A.Special _) -> FCR, 0
  | _ -> GOK, 0

(*****************************************************************************)
(* The rules (5l's optab.c, oplook; xix's Codegen5 patterns) *)
(*****************************************************************************)

let lfrom = 1 and lto = 2 and lpool = 4 and v4 = 8

type rule = { op : string; a1 : cls; a2 : cls; a3 : cls; case : int; size : int; param : int; flag : int }

(* the rules of the subset; floating point, the PSR, SWP and RFE, and
 * dynamic modules (C_ADDR) are out *)
let rules =
  let r op a1 a2 a3 case size ?(param = 0) ?(flag = 0) () = { op; a1; a2; a3; case; size; param; flag } in
  let sb = reg_sb and sp = reg_sp in
  let mem_rules = List.concat_map (fun op ->
      [ r op SEXT NONE REG 21 4 ~param:sb (); r op SAUTO NONE REG 21 4 ~param:sp (); r op SOREG NONE REG 21 4 ();
        r op LEXT NONE REG 31 8 ~param:sb ~flag:lfrom (); r op LAUTO NONE REG 31 8 ~param:sp ~flag:lfrom ();
        r op LOREG NONE REG 31 8 ~flag:lfrom () ]) [ "MOVW"; "MOVBU" ]
    @ List.concat_map (fun op ->
      [ r op REG NONE SEXT 20 4 ~param:sb (); r op REG NONE SAUTO 20 4 ~param:sp (); r op REG NONE SOREG 20 4 ();
        r op REG NONE LEXT 30 8 ~param:sb ~flag:lto (); r op REG NONE LAUTO 30 8 ~param:sp ~flag:lto ();
        r op REG NONE LOREG 30 8 ~flag:lto () ]) [ "MOVW"; "MOVBU"; "MOVB" ]
    @ List.concat_map (fun op ->
      [ r op SEXT NONE REG 22 12 ~param:sb (); r op SAUTO NONE REG 22 12 ~param:sp (); r op SOREG NONE REG 22 12 ();
        r op LEXT NONE REG 32 16 ~param:sb ~flag:lfrom (); r op LAUTO NONE REG 32 16 ~param:sp ~flag:lfrom ();
        r op LOREG NONE REG 32 16 ~flag:lfrom ();
        r op HEXT NONE REG 71 4 ~param:sb ~flag:v4 (); r op HAUTO NONE REG 71 4 ~param:sp ~flag:v4 ();
        r op HOREG NONE REG 71 4 ~flag:v4 ();
        r op LEXT NONE REG 73 8 ~param:sb ~flag:(lfrom lor v4) (); r op LAUTO NONE REG 73 8 ~param:sp ~flag:(lfrom lor v4) ();
        r op LOREG NONE REG 73 8 ~flag:(lfrom lor v4) () ]) [ "MOVH"; "MOVHU"; "MOVB" ]
    @ List.concat_map (fun op ->
      [ r op REG NONE SEXT 23 12 ~param:sb (); r op REG NONE SAUTO 23 12 ~param:sp (); r op REG NONE SOREG 23 12 ();
        r op REG NONE LEXT 33 24 ~param:sb ~flag:lto (); r op REG NONE LAUTO 33 24 ~param:sp ~flag:lto ();
        r op REG NONE LOREG 33 24 ~flag:lto ();
        r op REG NONE HEXT 70 4 ~param:sb ~flag:v4 (); r op REG NONE HAUTO 70 4 ~param:sp ~flag:v4 ();
        r op REG NONE HOREG 70 4 ~flag:v4 ();
        r op REG NONE LEXT 72 8 ~param:sb ~flag:(lto lor v4) (); r op REG NONE LAUTO 72 8 ~param:sp ~flag:(lto lor v4) ();
        r op REG NONE LOREG 72 8 ~flag:(lto lor v4) () ]) [ "MOVH"; "MOVHU" ]
  in
  (* FPA's: 5c's floating point, which goken's libc has (though no
   * machine runs it now) *)
  let float_rules =
    [ r "MOVF" FREG NONE FEXT 50 4 ~param:sb (); r "MOVF" FREG NONE FAUTO 50 4 ~param:sp (); r "MOVF" FREG NONE FOREG 50 4 ();
      r "MOVF" FEXT NONE FREG 51 4 ~param:sb (); r "MOVF" FAUTO NONE FREG 51 4 ~param:sp (); r "MOVF" FOREG NONE FREG 51 4 ();
      r "MOVF" FREG NONE LEXT 52 12 ~param:sb ~flag:lto (); r "MOVF" FREG NONE LAUTO 52 12 ~param:sp ~flag:lto ();
      r "MOVF" FREG NONE LOREG 52 12 ~flag:lto ();
      r "MOVF" LEXT NONE FREG 53 12 ~param:sb ~flag:lfrom (); r "MOVF" LAUTO NONE FREG 53 12 ~param:sp ~flag:lfrom ();
      r "MOVF" LOREG NONE FREG 53 12 ~flag:lfrom ();
      r "ADDF" FREG NONE FREG 54 4 (); r "ADDF" FREG REG FREG 54 4 (); r "ADDF" FCON NONE FREG 54 4 ();
      r "ADDF" FCON REG FREG 54 4 (); r "MOVF" FCON NONE FREG 54 4 (); r "MOVF" FREG NONE FREG 54 4 ();
      r "CMPF" FREG REG NONE 54 4 (); r "CMPF" FCON REG NONE 54 4 ();
      r "MOVFW" FREG NONE REG 55 4 (); r "MOVFW" REG NONE FREG 55 4 () ]
  in
  [ r "WORD" NONE NONE LCON 11 4 (); r "WORD" NONE NONE LEXT 11 4 ();
    r "ADD" REG REG REG 1 4 (); r "ADD" REG NONE REG 1 4 (); r "MOVW" REG NONE REG 1 4 (); r "MVN" REG NONE REG 1 4 ();
    r "CMP" REG REG NONE 1 4 ();
    r "ADD" RCON REG REG 2 4 (); r "ADD" RCON NONE REG 2 4 (); r "MOVW" RCON NONE REG 2 4 (); r "MVN" RCON NONE REG 2 4 ();
    r "CMP" RCON REG NONE 2 4 ();
    r "ADD" SHIFT REG REG 3 4 (); r "ADD" SHIFT NONE REG 3 4 (); r "MVN" SHIFT NONE REG 3 4 (); r "CMP" SHIFT REG NONE 3 4 ();
    r "SLL" RCON REG REG 8 4 (); r "SLL" RCON NONE REG 8 4 (); r "SLL" REG NONE REG 9 4 (); r "SLL" REG REG REG 9 4 ();
    r "MOVB" REG NONE REG 14 8 (); r "MOVBU" REG NONE REG 58 4 (); r "MOVH" REG NONE REG 14 8 (); r "MOVHU" REG NONE REG 14 8 ();
    r "MUL" REG REG REG 15 4 (); r "MUL" REG NONE REG 15 4 ();
    r "ADD" NCON REG REG 13 8 (); r "ADD" NCON NONE REG 13 8 (); r "MVN" NCON NONE REG 13 8 (); r "CMP" NCON REG NONE 13 8 ();
    r "ADD" LCON REG REG 13 8 ~flag:lfrom (); r "ADD" LCON NONE REG 13 8 ~flag:lfrom ();
    r "MVN" LCON NONE REG 13 8 ~flag:lfrom (); r "CMP" LCON REG NONE 13 8 ~flag:lfrom ();
    r "MOVW" NCON NONE REG 12 4 (); r "MOVW" LCON NONE REG 12 4 ~flag:lfrom ();
    r "B" NONE NONE BRANCH 5 4 ~flag:lpool (); r "BL" NONE NONE BRANCH 5 4 (); r "BEQ" NONE NONE BRANCH 5 4 ();
    r "B" NONE NONE ROREG 6 4 ~flag:lpool (); r "BL" NONE NONE ROREG 7 8 ();
    r "MOVW" RECON NONE REG 4 4 ~param:reg_sb (); r "MOVW" RACON NONE REG 4 4 ~param:reg_sp ();
    r "MOVW" LACON NONE REG 34 8 ~param:reg_sp ~flag:lfrom ();
    r "SWI" NONE NONE NONE 10 4 (); r "SWI" NONE NONE LCON 10 4 (); r "SWI" NONE NONE LOREG 10 4 ();
    r "DIV" REG REG REG 16 4 (); r "DIV" REG NONE REG 16 4 ();
    r "MULL" REG REG REGREG 17 4 ();
    r "MOVM" LCON NONE SOREG 38 4 (); r "MOVM" SOREG NONE LCON 39 4 ();
    r "MOVW" SHIFT NONE REG 59 4 (); r "MOVBU" SHIFT NONE REG 59 4 (); r "MOVB" SHIFT NONE REG 60 4 ();
    r "MOVW" REG NONE SHIFT 61 4 (); r "MOVB" REG NONE SHIFT 61 4 (); r "MOVBU" REG NONE SHIFT 61 4 ();
    r "CASE" REG NONE NONE 62 4 (); r "BCASE" NONE NONE BRANCH 63 4 () ]
  @ mem_rules @ float_rules

(* the opcodes that share a representative's rules (5l's buildop) *)
let representative = function
  | "SUB" | "AND" | "EOR" | "ORR" | "ADC" | "SBC" | "RSC" | "RSB" | "BIC" -> "ADD"
  | "TST" | "TEQ" | "CMN" -> "CMP"
  | "SRL" | "SRA" -> "SLL"
  | "MULU" -> "MUL"
  | "BNE" | "BHS" | "BLO" | "BMI" | "BPL" | "BVS" | "BVC" | "BHI" | "BLS" | "BGE" | "BLT" | "BGT" | "BLE" -> "BEQ"
  | "MOD" | "MODU" | "DIVU" -> "DIV"
  | "MULA" | "MULAL" | "MULLU" | "MULALU" -> "MULL"
  | "ADDD" | "SUBF" | "SUBD" | "MULF" | "MULD" | "DIVF" | "DIVD" | "MOVFD" | "MOVDF" -> "ADDF"
  | "CMPD" -> "CMPF"
  | "MOVD" -> "MOVF"
  | "MOVWF" | "MOVWD" | "MOVDW" -> "MOVFW"
  | op -> op

(* sorted as 5l's ocmp: by opcode, the ARMv4 rules first, then by classes *)
let table =
  let rank c = Obj.magic c in
  let a = Array.of_list rules in
  Array.stable_sort (fun x y -> compare (x.op, - (x.flag land v4), rank x.a1, rank x.a2, rank x.a3) (y.op, - (y.flag land v4), rank y.a1, rank y.a2, rank y.a3)) a;
  a

(* 5l's oplook: the first rule that takes the operands; cached *)
let rule ctx (p : prog) : rule =
  if p.rule < 0 then begin
    let v = view p in
    let a1 = fst (aclass ctx p v.from) and a3 = fst (aclass ctx p v.to_) in
    let a2 = if v.reg <> None then REG else NONE in
    let r = representative v.as_ in
    let rec find i =
      if i >= Array.length table then (let f, l = p.where in error "%s:%d: illegal combination: %s" f l (A.show_item (Ins { op = p.op; suffixes = p.suffixes; args = p.args })))
      else let o = table.(i) in if o.op = r && o.a2 = a2 && cmp o.a1 a1 && cmp o.a3 a3 then i else find (i + 1)
    in
    p.rule <- find 0
  end;
  table.(p.rule)

(*****************************************************************************)
(* Following the flow (5l's follow and xfol; not in xix) *)
(*****************************************************************************)

(* after loading (5a's outcode, 5l's ldobj): B.NE is BNE, and always,
 * BCS is BHS; not so the B that a conditional RET becomes, later. A
 * float constant that is no FPA immediate is in the data, in a symbol
 * named by its bits *)
let prepare (t : Link.t) =
  List.iter (fun (p : prog) ->
    match p.op, p.args with
    | "TEXT", _ -> p.frame <- rnd p.frame 4
    | ("MOVF" | "MOVD"), A.Fimm x :: rest when chip_float x = None ->
        p.args <- float_constant t x ~single:(p.op = "MOVF") :: rest
    | _ -> ()) t.progs;
  List.iter (fun (p : prog) ->
    match p.op, List.partition (fun s -> condition s <> None) p.suffixes with
    | "B", (c :: _, rest) ->
        p.op <- (match Option.get (condition c) with 14 -> "B" | c -> "B" ^ List.nth conditions c);
        p.suffixes <- rest
    | ("BCS" | "BCC"), _ -> p.op <- (if p.op = "BCS" then "BHS" else "BLO")
    | _ -> ()) t.progs

let invert = function
  | "BEQ" -> "BNE" | "BNE" -> "BEQ" | "BHS" -> "BLO" | "BLO" -> "BHS" | "BMI" -> "BPL" | "BPL" -> "BMI"
  | "BVS" -> "BVC" | "BVC" -> "BVS" | "BHI" -> "BLS" | "BLS" -> "BHI" | "BGE" -> "BLT" | "BLT" -> "BGE"
  | "BGT" -> "BLE" | "BLE" -> "BGT" | op -> error "unknown relation: %s" op

(* 5l's follow: B and an unconditional RET end the flow *)
let follow (t : Link.t) =
  Link.follow t ~ends:(fun p -> p.op = "B" || (p.op = "RET" && not (List.exists (fun s -> condition s <> None) p.suffixes))) ~invert

(*****************************************************************************)
(* Rewriting: frames, RET, DIV and MOD (5l's noops; xix's Rewrite5) *)
(*****************************************************************************)

let mem ?(off = 0) b = A.Mem { base = A.R b; name = None; off = Int64.of_int off; index = None }
let imm n = A.Imm (Int64.of_int n)
let prog_like (p : prog) op suffixes args = { p with op; suffixes; args; target = None; rule = -1; frame = 0; leaf = false }
let become (p : prog) op suffixes args = p.op <- op; p.suffixes <- suffixes; p.args <- args; p.target <- None; p.rule <- -1

let divisions = [ "DIV"; "DIVU"; "MOD"; "MODU" ]

(* the names a program needs besides its own: arm divides by calls *)
let needs (progs : prog list) =
  if List.exists (fun (p : prog) -> List.mem p.op divisions) progs then [ "_div"; "_divu"; "_mod"; "_modu" ] else []

let rewrite (t : Link.t) =
  let texts = Hashtbl.create 64 in
  let cur = ref None in
  List.iter (fun (p : prog) ->
    match p.op with
    | "TEXT" ->
        p.leaf <- true;
        cur := Some p;
        (match p.args with A.Mem { name = Some n; _ } :: _ -> Hashtbl.replace texts (sym_of t p.version n).name p | _ -> ())
    | op when op = "BL" || List.mem op divisions -> Option.iter (fun c -> c.leaf <- false) !cur
    | _ -> ()) t.progs;
  let autosize = ref 0 and leaf = ref true in
  t.progs <- List.concat_map (fun (p : prog) ->
    match p.op with
    | "TEXT" ->
        if p.frame <= 0 && p.leaf then p.frame <- -4;
        autosize := p.frame + 4;
        if !autosize = 0 && not p.leaf then p.leaf <- true;
        leaf := p.leaf;
        if p.leaf && !autosize = 0 then [ p ]
        else [ p; prog_like p "MOVW" [ "W" ] [ A.Reg reg_link; mem reg_sp ~off:(- !autosize) ] ]
    (* in place, as the branches to it stay *)
    | "RET" ->
        let conds = List.filter (fun s -> condition s <> None) p.suffixes in
        if !leaf && !autosize = 0 then become p "B" conds [ mem reg_link ]
        else become p "MOVW" (conds @ [ "P" ]) [ mem reg_sp ~off:!autosize; A.Reg reg_pc ];
        [ p ]
    | op when List.mem op divisions -> (
        match p.args with
        | [ A.Reg a; A.Reg _; A.Reg d ] | [ A.Reg a; A.Reg d ] ->
            (* the dividend: the middle register, else the destination *)
            let b' = match p.args with [ _; A.Reg m; _ ] -> m | _ -> d in
            let callee = match Hashtbl.find_opt texts ("_" ^ String.lowercase_ascii op) with
              | Some q -> q | None -> let f, l = p.where in error "%s:%d: no _%s to call" f l (String.lowercase_ascii op) in
            let bl = prog_like p "BL" [] [ A.Target 0 ] in
            bl.target <- Some callee;
            let rest =
              [ prog_like p "MOVW" [] [ A.Reg a; mem reg_sp ~off:4 ];
              prog_like p "MOVW" [] [ A.Reg b'; A.Reg reg_tmp ];
              bl;
              prog_like p "MOVW" [] [ A.Reg reg_tmp; A.Reg d ];
              prog_like p "ADD" [] [ imm 8; A.Reg reg_sp ] ] in
            become p "SUB" [] [ imm 8; A.Reg reg_sp ];
            p :: rest
        | _ -> [ p ])
    (* 5l's ldobj: an ADD or SUB of a negative constant is the other *)
    | ("ADD" | "SUB") as op -> (
        match p.args with
        | A.Imm n :: rest when sx32 n < 0 ->
            p.op <- (if op = "ADD" then "SUB" else "ADD");
            p.args <- imm (- (sx32 n)) :: rest;
            [ p ]
        | _ -> [ p ])
    | _ -> [ p ]) t.progs

(*****************************************************************************)
(* Layout: pcs and literal pools (5l's dotext, addpool, flushpool,
 * checkpool; xix's Layout5) *)
(*****************************************************************************)

let layout (t : Link.t) =
  let ctx = { t; autosize = 0 } in
  let pool = ref [] (* (key, word), newest first *) and pool_start = ref 0 in
  let pool_size () = 4 * List.length !pool in
  let out = ref [] in
  (* the pool after p, behind a branch around it when [skip] (to what
   * follows, or to itself at the very end, as 5l) *)
  let flush (p : prog) rest skip =
    if !pool = [] then rest
    else if (not skip) && p.pc + pool_size () - !pool_start < 2048 then rest
    else begin
      let words = List.rev_map snd !pool in
      pool := [];
      pool_start := 0;
      if skip then begin
        let b = prog_like p "B" [] [ A.Target 0 ] in
        b.target <- (match rest with q :: _ -> Some q | [] -> Some b);
        if rest = [] then b.target <- Some b;
        b.args <- [ A.Target 0 ];
        (b :: words) @ rest
      end
      else words @ rest
    end
  in
  let add_pool (p : prog) (a : A.operand option) =
    let c, v = aclass ctx p a in
    let key = match c with
      | SROREG | LOREG | ROREG | FOREG | SOREG | FAUTO | SAUTO | LAUTO | LACON -> A.Imm (Int64.of_int v), 0
      (* the operand, as 5l's memcmp of it: a name<> is its object's *)
      | _ ->
          let a = Option.get a in
          a, (match a with A.Mem { name = Some { static = true; _ }; _ } | A.Addr { name = Some { static = true; _ }; _ } -> p.version | _ -> 0)
    in
    match List.assoc_opt key !pool with
    | Some w -> p.target <- Some w
    | None ->
        let w = prog_like p "WORD" [] [ fst key ] in
        if !pool = [] then pool_start := p.pc;
        pool := (key, w) :: !pool;
        p.target <- Some w
  in
  let pc = ref t.text_start in
  let rec go = function
    | [] -> ()
    | (p : prog) :: rest ->
        p.pc <- !pc;
        out := p :: !out;
        if p.op = "TEXT" then begin
          ctx.autosize <- p.frame + 4;
          (match p.args with A.Mem { name = Some n; _ } :: _ -> (sym_of t p.version n).value <- !pc | _ -> ());
          go rest
        end
        else begin
          let r = rule ctx p in
          pc := !pc + r.size;
          let v = view p in
          if r.flag land (lfrom lor lto lor lpool) = lfrom then add_pool p v.from
          else if r.flag land (lfrom lor lto lor lpool) = lto then add_pool p v.to_;
          let rest = if r.flag land lpool <> 0 && v.sc land 15 = always then flush p rest false else rest in
          let rest =
            if v.as_ = "MOVW" && v.to_ = Some (A.Reg reg_pc) && v.sc land 15 = always then flush p rest false else rest
          in
          let rest =
            if !pool <> [] && (rest = [] || pool_size () >= 0xffc || immaddr (p.pc + 4 + 4 + pool_size () - !pool_start + 8) = 0)
            then flush p rest true
            else rest
          in
          go rest
        end
  in
  go t.progs;
  t.progs <- List.rev !out;
  let c = rnd !pc 8 in
  t.text_size <- c - t.text_start;
  (lookup t "etext" 0).value <- c;
  t.data_start <- rnd c t.data_round

(*****************************************************************************)
(* Encoding (5l's asmout and its helpers, codegen.c; xix's Codegen5) *)
(*****************************************************************************)

(* the data-processing opcodes, bits 21-24 (5l's oprrr) *)
let oprrr as_ sc =
  let o = ((sc land 15) lsl 28) lor (if sc land c_sbit <> 0 then 1 lsl 20 else 0) in
  o lor (match as_ with
    | "AND" -> 0x0 lsl 21 | "EOR" -> 0x1 lsl 21 | "SUB" -> 0x2 lsl 21 | "RSB" -> 0x3 lsl 21
    | "ADD" -> 0x4 lsl 21 | "ADC" -> 0x5 lsl 21 | "SBC" -> 0x6 lsl 21 | "RSC" -> 0x7 lsl 21
    | "TST" -> (0x8 lsl 21) lor (1 lsl 20) | "TEQ" -> (0x9 lsl 21) lor (1 lsl 20)
    | "CMP" -> (0xa lsl 21) lor (1 lsl 20) | "CMN" -> (0xb lsl 21) lor (1 lsl 20)
    | "ORR" -> 0xc lsl 21 | "MOVW" -> 0xd lsl 21 | "BIC" -> 0xe lsl 21 | "MVN" -> 0xf lsl 21
    | "SLL" -> 0xd lsl 21 | "SRL" -> (0xd lsl 21) lor (1 lsl 5) | "SRA" -> (0xd lsl 21) lor (2 lsl 5)
    | "MUL" | "MULU" -> 0x9 lsl 4
    | "SWI" -> 0xf lsl 24
    | "MULA" -> (0x1 lsl 21) lor (0x9 lsl 4) | "MULLU" -> (0x4 lsl 21) lor (0x9 lsl 4)
    | "MULL" -> (0x6 lsl 21) lor (0x9 lsl 4) | "MULALU" -> (0x5 lsl 21) lor (0x9 lsl 4)
    | "MULAL" -> (0x7 lsl 21) lor (0x9 lsl 4)
    | "ADDD" | "ADDF" | "MULD" | "MULF" | "SUBD" | "SUBF" | "DIVD" | "DIVF" as op ->
        let n = match op.[0] with 'A' -> 0 | 'M' -> 1 | 'S' -> 2 | _ -> 4 in
        (0xe lsl 24) lor (n lsl 20) lor (1 lsl 8) lor (if op.[3] = 'D' then 1 lsl 7 else 0)
    | "CMPD" | "CMPF" -> (0xe lsl 24) lor (0x9 lsl 20) lor (0xf lsl 12) lor (1 lsl 8) lor (1 lsl 4)
    | "MOVF" | "MOVDF" -> (0xe lsl 24) lor (1 lsl 15) lor (1 lsl 8)
    | "MOVD" | "MOVFD" -> (0xe lsl 24) lor (1 lsl 15) lor (1 lsl 8) lor (1 lsl 7)
    | "MOVWF" -> (0xe lsl 24) lor (1 lsl 8) lor (1 lsl 4)
    | "MOVWD" -> (0xe lsl 24) lor (1 lsl 8) lor (1 lsl 4) lor (1 lsl 7)
    | "MOVFW" -> (0xe lsl 24) lor (1 lsl 20) lor (1 lsl 8) lor (1 lsl 4)
    | "MOVDW" -> (0xe lsl 24) lor (1 lsl 20) lor (1 lsl 8) lor (1 lsl 4) lor (1 lsl 7)
    | op -> error "bad data-processing op %s" op)

(* branches (5l's opbra) *)
let opbra as_ sc =
  if as_ = "BL" then ((sc land 15) lsl 28) lor (0x5 lsl 25) lor (1 lsl 24)
  else
    let c = match as_ with "B" -> 14 | _ -> Option.get (condition (String.sub as_ 1 2)) in
    (c lsl 28) lor (0x5 lsl 25)

(* loads and stores of words and bytes (5l's olr, osr, olrr, osrr) *)
let olr as_ sc v b rt =
  let o = ((sc land 15) lsl 28) lor (if sc land c_pbit = 0 then 1 lsl 24 else 0) lor (if sc land c_wbit <> 0 then 1 lsl 21 else 0)
          lor (1 lsl 26) lor (1 lsl 20) in
  let o, v = if v >= 0 then o lor (1 lsl 23), v else o, - v in
  if v >= 1 lsl 12 then error "literal span too large: %d" v;
  o lor (if as_ = "MOVB" || as_ = "MOVBU" then 1 lsl 22 else 0) lor (b lsl 16) lor (rt lsl 12) lor v

let osr as_ sc r v b = olr as_ sc v b r lxor (1 lsl 20)
let olrr as_ sc i b r = olr as_ sc i b r lor (1 lsl 25)
let osrr as_ sc r i b = olrr as_ sc i b r lxor (1 lsl 20)

(* halves and signed bytes, ARMv4 (5l's olhr, oshr, olhrr, oshrr) *)
let olhr v b r sc =
  let o = ((sc land 15) lsl 28) lor (if sc land c_pbit = 0 then 1 lsl 24 else 0) lor (if sc land c_wbit <> 0 then 1 lsl 21 else 0)
          lor (1 lsl 23) lor (1 lsl 20) lor (0xb lsl 4) in
  let o, v = if v < 0 then o lxor (1 lsl 23), - v else o, v in
  if v >= 1 lsl 8 then error "literal span too large: %d" v;
  o lor (v land 0xf) lor ((v lsr 4) lsl 8) lor (1 lsl 22) lor (b lsl 16) lor (r lsl 12)

let oshr r v b sc = olhr v b r sc lxor (1 lsl 20)
let olhrr i b r sc = olhr i b r sc lxor (1 lsl 22)
let oshrr r i b sc = olhr i b r sc lxor ((1 lsl 22) lor (1 lsl 20))

(* FPA's loads and stores (5l's ofsr) *)
let ofsr as_ r v b sc =
  let o = ((sc land 15) lsl 28) lor (if sc land c_pbit = 0 then 1 lsl 24 else 0) lor (if sc land c_wbit <> 0 then 1 lsl 21 else 0)
          lor (6 lsl 25) lor (1 lsl 24) lor (1 lsl 23) in
  let o, v = if v < 0 then o lxor (1 lsl 23), - v else o, v in
  if v land 3 <> 0 then error "odd offset for floating point op: %d" v;
  if v >= 1 lsl 10 then error "literal span too large: %d" v;
  o lor ((v lsr 2) land 0xff) lor (b lsl 16) lor (r lsl 12) lor (1 lsl 8) lor (if as_ = "MOVD" then 1 lsl 15 else 0)

let fregof = function Some (A.FReg r) -> r | _ -> -1

let regof = function Some (A.Reg r) -> r | Some (A.Mem { base = R r; _ }) -> r | Some (A.Addr { base = R r; _ }) -> r | _ -> -1

(* a shift operand as 5a encodes it: reg | amount or reg<<8|1<<4 | kind<<5 *)
let shift_bits (s : A.shift) =
  s.reg lor (s.kind lsl 5) lor (match s.by with `Imm n -> (n land 31) lsl 7 | `Reg r -> (r lsl 8) lor (1 lsl 4))

let shift_of = function Some (A.Shifted s) -> s | Some (A.Mem { index = Some s; _ }) -> s | _ -> error "not a shift"

let encode_prog ctx (p : prog) : int list =
  let o = rule ctx p in
  let v = view p in
  let sc = v.sc in
  let off a = snd (aclass ctx p a) in
  let rt = regof v.to_ and rf = regof v.from in
  let mid ~is_mov rt = if is_mov then 0 else match v.reg with Some r -> r | None -> rt in
  let is_mov = v.as_ = "MOVW" || v.as_ = "MVN" in
  let base a = match regof a with -1 -> o.param | r -> r in
  (* a constant from the pool, or an MVN of its complement (5l's omvl) *)
  let omvl a dr =
    match p.target with
    | Some w -> olr "MOVW" (sc land 15) (w.pc - p.pc - 8) reg_pc dr
    | None -> (
        match immrot (lnot (off a)) with
        | Some i -> oprrr "MVN" (sc land 15) lor (dr lsl 12) lor i
        | None -> error "missing literal")
  in
  let target_pc () = match p.target with Some q -> q.pc | None -> p.pc in
  match o.case with
  | 0 -> []
  | 11 -> [ off v.to_ land 0xffffffff ]
  | 1 ->
      let rt = if v.to_ = None then 0 else rt in
      [ oprrr v.as_ sc lor (mid ~is_mov rt lsl 16) lor (rt lsl 12) lor rf ]
  | 2 ->
      let rt = if v.to_ = None then 0 else rt in
      [ oprrr v.as_ sc lor Option.get (immrot (off v.from)) lor (mid ~is_mov rt lsl 16) lor (rt lsl 12) ]
  | 3 ->
      let rt = if v.to_ = None then 0 else rt in
      [ oprrr v.as_ sc lor shift_bits (shift_of v.from) lor (mid ~is_mov rt lsl 16) lor (rt lsl 12) ]
  | 8 -> let r = mid ~is_mov:false rt in [ oprrr v.as_ sc lor (rt lsl 12) lor ((off v.from land 31) lsl 7) lor r ]
  | 9 -> let r = mid ~is_mov:false rt in [ oprrr v.as_ sc lor (rt lsl 12) lor (rf lsl 8) lor (1 lsl 4) lor r ]
  | 14 ->
      let n = if v.as_ = "MOVB" || v.as_ = "MOVBU" then 24 else 16 in
      [ oprrr "SLL" sc lor (rt lsl 12) lor (n lsl 7) lor rf;
        oprrr (if v.as_ = "MOVBU" || v.as_ = "MOVHU" then "SRL" else "SRA") sc lor (rt lsl 12) lor (n lsl 7) lor rt ]
  | 58 -> let r = if rf < 0 then rt else rf in [ oprrr "AND" sc lor Option.get (immrot 0xff) lor (r lsl 16) lor (rt lsl 12) ]
  | 15 ->
      let r = mid ~is_mov:false rt in
      let r, rf = if rt = r then rf, rt else r, rf in
      [ oprrr v.as_ sc lor (rt lsl 16) lor (rf lsl 8) lor r ]
  | 13 ->
      let o1 = omvl v.from reg_tmp in
      let o2 = oprrr v.as_ sc lor (mid ~is_mov rt lsl 16) lor reg_tmp lor (if v.to_ <> None then rt lsl 12 else 0) in
      [ o1; o2 ]
  | 12 -> [ omvl v.from rt ]
  | 5 -> [ opbra v.as_ sc lor (((target_pc () - p.pc - 8) asr 2) land 0xffffff) ]
  | 6 -> [ oprrr "ADD" sc lor Option.get (immrot (off v.to_)) lor (regof v.to_ lsl 16) lor (reg_pc lsl 12) ]
  | 7 ->
      [ oprrr "ADD" sc lor (reg_pc lsl 16) lor (reg_link lsl 12) lor Option.get (immrot 0);
        oprrr "ADD" sc lor (regof v.to_ lsl 16) lor (reg_pc lsl 12) lor Option.get (immrot (off v.to_)) ]
  | 21 -> [ olr v.as_ sc (off v.from) (base v.from) rt ]
  | 31 -> [ omvl v.from reg_tmp; olrr v.as_ sc reg_tmp (base v.from) rt ]
  | 20 -> [ osr v.as_ sc rf (off v.to_) (base v.to_) ]
  | 30 -> [ omvl v.to_ reg_tmp; osrr v.as_ sc rf reg_tmp (base v.to_) ]
  | 4 -> [ oprrr "ADD" sc lor (base v.from lsl 16) lor (rt lsl 12) lor Option.get (immrot (off v.from)) ]
  | 34 -> [ omvl v.from reg_tmp; oprrr "ADD" sc lor (base v.from lsl 16) lor (rt lsl 12) lor reg_tmp ]
  | 22 ->
      let n = if v.as_ = "MOVB" then 24 else 16 in
      [ olr "MOVW" sc (off v.from) (base v.from) rt;
        oprrr "SLL" sc lor (rt lsl 12) lor (n lsl 7) lor rt;
        oprrr (if v.as_ = "MOVHU" then "SRL" else "SRA") sc lor (rt lsl 12) lor (n lsl 7) lor rt ]
  | 32 ->
      let n = if v.as_ = "MOVB" then 24 else 16 in
      [ omvl v.from reg_tmp; olrr v.as_ sc reg_tmp (base v.from) rt;
        oprrr "SLL" sc lor (rt lsl 12) lor (n lsl 7) lor rt;
        oprrr (if v.as_ = "MOVHU" then "SRL" else "SRA") sc lor (rt lsl 12) lor (n lsl 7) lor rt ]
  | 23 ->
      let b = base v.to_ and x = off v.to_ in
      [ osr "MOVBU" sc rf x b; oprrr "SRL" sc lor (reg_tmp lsl 12) lor (8 lsl 7) lor rf; osr "MOVBU" sc reg_tmp (x + 1) b ]
  | 33 ->
      let b = base v.to_ in
      [ omvl v.to_ reg_tmp; osrr "MOVBU" sc rf reg_tmp b;
        oprrr "SRL" sc lor (rf lsl 12) lor (8 lsl 7) lor rf lor (1 lsl 6);
        oprrr "ADD" sc lor (reg_tmp lsl 16) lor (reg_tmp lsl 12) lor Option.get (immrot 1);
        osrr "MOVBU" sc rf reg_tmp b;
        oprrr "SRL" sc lor (rf lsl 12) lor (24 lsl 7) lor rf lor (1 lsl 6) ]
  | 10 -> [ oprrr v.as_ sc lor (if v.to_ <> None then off v.to_ land 0xffffff else 0) ]
  | 16 -> [ 0xf lsl 28 ]
  | 17 ->
      let rt, rt2 = match v.to_ with Some (A.Pair (a, b)) -> a, b | _ -> 0, 0 in
      [ oprrr v.as_ sc lor (rf lsl 8) lor Option.get v.reg lor (rt lsl 16) lor (rt2 lsl 12) ]
  | 38 | 39 ->
      let store = o.case = 38 in
      let mask = if store then off v.from else off v.to_ in
      let b = if store then regof v.to_ else rf in
      if (if store then off v.to_ else off v.from) <> 0 then error "offset must be zero in MOVM";
      [ (0x4 lsl 25) lor (if store then 0 else 1 lsl 20) lor (mask land 0xffff) lor (b lsl 16)
        lor ((sc land 15) lsl 28) lor (if sc land c_pbit <> 0 then 1 lsl 24 else 0)
        lor (if sc land c_ubit <> 0 then 1 lsl 23 else 0) lor (if sc land c_sbit <> 0 then 1 lsl 22 else 0)
        lor (if sc land c_wbit <> 0 then 1 lsl 21 else 0) ]
  | 70 -> [ oshr rf (off v.to_) (base v.to_) sc ]
  | 71 ->
      let o1 = olhr (off v.from) (base v.from) rt sc in
      [ (if v.as_ = "MOVB" then o1 lxor ((1 lsl 5) lor (1 lsl 6)) else if v.as_ = "MOVH" then o1 lxor (1 lsl 6) else o1) ]
  | 72 -> [ omvl v.to_ reg_tmp; oshrr rf reg_tmp (base v.to_) sc ]
  | 73 ->
      let o2 = olhrr reg_tmp (base v.from) rt sc in
      [ omvl v.from reg_tmp;
        (if v.as_ = "MOVB" then o2 lxor ((1 lsl 5) lor (1 lsl 6)) else if v.as_ = "MOVH" then o2 lxor (1 lsl 6) else o2) ]
  | 59 -> (
      match v.from with
      | Some (A.Mem { base = R b; index = Some s; _ }) -> [ olrr v.as_ sc (shift_bits s) b rt ]
      | _ -> [ oprrr v.as_ sc lor shift_bits (shift_of v.from) lor (rt lsl 12) ])
  | 60 -> (
      match v.from with
      | Some (A.Mem { base = R b; index = Some s; _ }) -> [ olhrr (shift_bits s) b rt sc lxor ((1 lsl 5) lor (1 lsl 6)) ]
      | _ -> error "byte MOV from shifter operand")
  | 61 -> (
      match v.to_ with
      | Some (A.Mem { base = R b; index = Some s; _ }) -> [ osrr v.as_ sc rf (shift_bits s) b ]
      | _ -> error "MOV to shifter operand")
  | 62 -> [ olrr "MOVW" sc rf reg_pc reg_pc lor (2 lsl 7) ]
  | 63 -> [ target_pc () ]
  | 50 -> [ ofsr v.as_ (fregof v.from) (off v.to_) (base v.to_) sc ]
  | 51 -> [ ofsr v.as_ (fregof v.to_) (off v.from) (base v.from) sc lor (1 lsl 20) ]
  | 52 -> [ omvl v.to_ reg_tmp; oprrr "ADD" sc lor (reg_tmp lsl 12) lor (reg_tmp lsl 16) lor base v.to_;
            ofsr v.as_ (fregof v.from) 0 reg_tmp sc ]
  | 53 -> [ omvl v.from reg_tmp; oprrr "ADD" sc lor (reg_tmp lsl 12) lor (reg_tmp lsl 16) lor base v.from;
            ofsr v.as_ (fregof v.to_) 0 reg_tmp sc lor (1 lsl 20) ]
  | 54 ->
      let o1 = oprrr v.as_ sc in
      let rf = match v.from with
        | Some (A.Fimm x) -> (match chip_float x with Some i -> i lor 8 | None -> error "invalid floating-point immediate")
        | a -> fregof a in
      let rt = fregof v.to_ in
      let r = if v.to_ = None then Option.get v.reg else if o1 land (1 lsl 15) <> 0 then 0 else Option.value v.reg ~default:rt in
      let rt = if v.to_ = None then 0 else rt in
      [ o1 lor rf lor (r lsl 16) lor (rt lsl 12) ]
  | 55 -> (
      let o1 = oprrr v.as_ sc in
      match v.from, v.to_ with
      | Some (A.Reg rf), Some (A.FReg rt) -> [ o1 lor (rf lsl 12) lor (rt lsl 16) ]
      | Some (A.FReg rf), Some (A.Reg rt) -> [ o1 lor rf lor (rt lsl 12) ]
      | _ -> error "bad float conversion")
  | n -> error "rule %d not in the subset" n

let encode (t : Link.t) : Bytes.t =
  let ctx = { t; autosize = 0 } in
  let b = Bytes.make t.text_size '\000' in
  List.iter (fun (p : prog) ->
    if p.op = "TEXT" then ctx.autosize <- p.frame + 4
    else List.iteri (fun i w -> Link.put32 b (p.pc - t.text_start + (4 * i)) w) (encode_prog ctx p)) t.progs;
  b
