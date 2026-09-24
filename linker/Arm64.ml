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

open Link
module A = Asm

(*****************************************************************************)
(* Opcodes (7.out.h; 7a's lex.c) *)
(*****************************************************************************)

type size = X | W      (* 64 or 32 bits: 7a's W at the end *)
type prec = S | D

(* a load's or store's width; u: zero-extended *)
type width = B8 | B8u | H16 | H16u | W32 | W32u | X64
type mov = Int of width | Float of prec

type arith = Add | Adds | Sub | Subs
type logic = And | Ands | Eor | Orr
type farith = Fadd | Fsub | Fmul | Fnmul | Fdiv
type funary = Fabs | Fneg | Fsqrt

(* bool: CMN, NEGS, the unsigned forms, CBNZ *)
(* old: the mnemonic's string, taken apart where used (a W at the end
 * stripped, but not MOVW's) and matched with catch-alls ending in
 * "bad rrr %s"; 7l's buildop a table from string to string *)
type op =
  | Arith of arith * size | Cmp of bool * size | Neg of bool * size | Logic of logic * size | Mvn of size
  | Shift of A.shift_kind * size
  | Div of bool * size | Rem of bool * size | Mul of size | Mneg of size | Mull of bool | Mulh of bool
  | Mov of mov | Ext of width * size            (* MOVB ... FMOVD; SXTB ... UXTW *)
  | Farith of farith * prec | Funary of funary * prec | Fcmp of prec
  | Fcvt of prec                                (* from: FCVTSD is Fcvt S *)
  | Fcvtz of bool * prec * size | Cvtf of bool * size * prec
  | Cbz of bool * size
  | Ret | Return | Svc | Case | Word | Dword

type prog = op Link.prog

let show op =
  let w = function X -> "" | W -> "W" and p = function S -> "S" | D -> "D" and u b = if b then "U" else "S" in
  let bhw = function B8 | B8u -> "B" | H16 | H16u -> "H" | W32 | W32u -> "W" | X64 -> "" in
  match op with
  | Arith (a, sz) -> (match a with Add -> "ADD" | Adds -> "ADDS" | Sub -> "SUB" | Subs -> "SUBS") ^ w sz
  | Cmp (cmn, sz) -> (if cmn then "CMN" else "CMP") ^ w sz
  | Neg (s, sz) -> (if s then "NEGS" else "NEG") ^ w sz
  | Logic (l, sz) -> (match l with And -> "AND" | Ands -> "ANDS" | Eor -> "EOR" | Orr -> "ORR") ^ w sz
  | Mvn sz -> "MVN" ^ w sz
  | Shift (k, sz) -> (match k with Lsl -> "LSL" | Lsr -> "LSR" | Asr -> "ASR" | Ror -> "ROR") ^ w sz
  | Div (un, sz) -> u un ^ "DIV" ^ w sz
  | Rem (un, sz) -> (if un then "UREM" else "REM") ^ w sz
  | Mul sz -> "MUL" ^ w sz
  | Mneg sz -> "MNEG" ^ w sz
  | Mull un -> u un ^ "MULL"
  | Mulh un -> u un ^ "MULH"
  | Mov (Int wd) -> "MOV" ^ bhw wd ^ (match wd with B8u | H16u | W32u -> "U" | _ -> "")
  | Mov (Float pr) -> "FMOV" ^ p pr
  | Ext (wd, sz) -> (match wd with B8 | H16 | W32 | X64 -> "SXT" | B8u | H16u | W32u -> "UXT") ^ bhw wd ^ w sz
  | Farith (f, pr) -> (match f with Fadd -> "FADD" | Fsub -> "FSUB" | Fmul -> "FMUL" | Fnmul -> "FNMUL" | Fdiv -> "FDIV") ^ p pr
  | Funary (f, pr) -> (match f with Fabs -> "FABS" | Fneg -> "FNEG" | Fsqrt -> "FSQRT") ^ p pr
  | Fcmp pr -> "FCMP" ^ p pr
  | Fcvt S -> "FCVTSD"
  | Fcvt D -> "FCVTDS"
  | Fcvtz (un, pr, sz) -> "FCVTZ" ^ u un ^ p pr ^ w sz
  | Cvtf (un, sz, pr) -> u un ^ "CVTF" ^ w sz ^ p pr
  | Cbz (nz, sz) -> (if nz then "CBNZ" else "CBZ") ^ w sz
  | Ret -> "RET" | Return -> "RETURN" | Svc -> "SVC" | Case -> "CASE" | Word -> "WORD" | Dword -> "DWORD"

(* the opcodes, each once: show's inverse is a table of them *)
let decode =
  let sizes f = [ f X; f W ] and precs f = [ f S; f D ] and bools f = [ f false; f true ] in
  let each l f = List.concat_map f l and both = [ false; true ] in
  let ops = List.concat [
    each [ Add; Adds; Sub; Subs ] (fun a -> sizes (fun sz -> Arith (a, sz)));
    each [ And; Ands; Eor; Orr ] (fun l -> sizes (fun sz -> Logic (l, sz)));
    each [ A.Lsl; Lsr; Asr; Ror ] (fun k -> sizes (fun sz -> Shift (k, sz)));
    each both (fun b -> sizes (fun sz -> Cmp (b, sz))); each both (fun b -> sizes (fun sz -> Neg (b, sz)));
    each both (fun b -> sizes (fun sz -> Div (b, sz))); each both (fun b -> sizes (fun sz -> Rem (b, sz)));
    each both (fun b -> sizes (fun sz -> Cbz (b, sz)));
    sizes (fun sz -> Mvn sz); sizes (fun sz -> Mul sz); sizes (fun sz -> Mneg sz); bools (fun b -> Mull b); bools (fun b -> Mulh b);
    List.map (fun wd -> Mov (Int wd)) [ B8; B8u; H16; H16u; W32; W32u; X64 ];
    each [ B8; B8u; H16; H16u ] (fun wd -> sizes (fun sz -> Ext (wd, sz))); [ Ext (W32, X); Ext (W32u, X) ];
    precs (fun pr -> Mov (Float pr)); precs (fun pr -> Fcmp pr); precs (fun pr -> Fcvt pr);
    each [ Fadd; Fsub; Fmul; Fnmul; Fdiv ] (fun f -> precs (fun pr -> Farith (f, pr)));
    each [ Fabs; Fneg; Fsqrt ] (fun f -> precs (fun pr -> Funary (f, pr)));
    each both (fun b -> each [ S; D ] (fun pr -> sizes (fun sz -> Fcvtz (b, pr, sz))));
    each both (fun b -> each [ X; W ] (fun sz -> precs (fun pr -> Cvtf (b, sz, pr))));
    [ Ret; Return; Svc; Case; Word; Dword ] ] in
  let t = Hashtbl.create 256 in
  List.iter (fun op -> Hashtbl.replace t (show op) op) ops;
  Hashtbl.find_opt t

(*****************************************************************************)
(* Registers (7.out.h) *)
(*****************************************************************************)

let reg_tmp = 17 and reg_sb = 28 and reg_link = 30 and reg_sp = 31 and reg_zero = 31
let pcsz = 8

(* an instruction as 7l sees it: opcode, from, middle register, to *)
type view = { op : op Link.op; from : A.operand option; reg : int option; to_ : A.operand option }

let view (p : prog) : view =
  let op = p.op in
  (* a branch to a name is to its TEXT (resolved) *)
  let args = List.map (function A.Mem { base = SB; _ } when p.target <> None && (op = B || op = Bl) -> A.Target 0 | a -> a) p.args in
  let v from reg to_ = { op; from; reg; to_ } in
  match op, args with
  | Ins (Cmp _ | Fcmp _), [ a; (A.Reg r | A.FReg r) ] -> v (Some a) (Some r) None
  | _, [ a ] -> v None None (Some a)
  | _, [ a; b ] -> v (Some a) None (Some b)
  | _, [ a; (A.Reg r | A.FReg r); c ] -> v (Some a) (Some r) (Some c)
  | _, [] -> v None None None
  | _ -> let f, l = p.where in error "%s:%d: %s: bad operands" f l (Link.show_op show op)

(* a register operand's number: $0 is the zero register *)
let regno = function
  | Some (A.Reg r | A.FReg r) -> r
  | Some (A.Imm 0L) -> reg_zero
  | Some (A.Mem { base = R r; _ }) -> r
  | _ -> reg_zero

(*****************************************************************************)
(* Operand classes (7l's l.h C_xxx, span.c's aclass, cmp) *)
(*****************************************************************************)

(* in 7l's order: cmp compares the SEXTs' ranks *)
type cls = NONE | REG | RSP | SHIFT | EXTREG | FREG | SPR | COND
  | ZCON | ADDCON0 | ADDCON | MOVCON | BITCON | ABCON | MBCON | LCON | FCON | VCON
  | AACON | LACON | AECON | SBRA | LBRA
  | NPAUTO | NSAUTO | PSAUTO | PPAUTO | UAUTO4K | UAUTO8K | UAUTO16K | UAUTO32K | UAUTO64K | LAUTO
  | SEXT1 | SEXT2 | SEXT4 | SEXT8 | SEXT16 | LEXT
  | NPOREG | NSOREG | ZOREG | PSOREG | PPOREG | UOREG4K | UOREG8K | UOREG16K | UOREG32K | UOREG64K | LOREG
  | ADDR | ROFF | XPOST | XPRE | VREG | GOK
[@@warning "-37"]

let rank (c : cls) : int = Obj.magic c

(* 7l's cmp: may a form for class [a] take an operand of class [b] *)
let rec cmp a b =
  a = b
  || match a with
     | RSP -> b = REG
     | REG | ADDCON0 -> b = ZCON
     | ADDCON -> b = ZCON || b = ADDCON0 || b = ABCON
     | BITCON -> b = ABCON || b = MBCON
     | MOVCON -> b = MBCON || b = ZCON || b = ADDCON0
     | LCON -> List.mem b [ ZCON; BITCON; ADDCON; ADDCON0; ABCON; MBCON; MOVCON ]
     | VCON -> cmp LCON b
     | LACON -> b = AACON
     | SEXT2 | SEXT4 | SEXT8 | SEXT16 | LEXT -> rank b >= rank SEXT1 && rank b < rank a
     | PPAUTO -> b = PSAUTO
     | UAUTO4K -> b = PSAUTO || b = PPAUTO
     | UAUTO8K -> cmp UAUTO4K b
     | UAUTO16K -> cmp UAUTO8K b
     | UAUTO32K -> cmp UAUTO16K b
     | UAUTO64K -> cmp UAUTO32K b
     | NPAUTO -> cmp NSAUTO b
     | LAUTO -> cmp NPAUTO b || cmp UAUTO64K b
     | PSOREG -> b = ZOREG
     | PPOREG -> b = ZOREG || b = PSOREG
     | UOREG4K -> List.mem b [ ZOREG; PSAUTO; PSOREG; PPAUTO; PPOREG ]
     | UOREG8K -> cmp UOREG4K b
     | UOREG16K -> cmp UOREG8K b
     | UOREG32K -> cmp UOREG16K b
     | UOREG64K -> cmp UOREG32K b
     | NPOREG -> cmp NSOREG b
     | LOREG -> cmp NPOREG b || cmp UOREG64K b
     | LBRA -> b = SBRA
     | _ -> false

(* the logical immediates, all 5,334 of them: s ones rotated right by r
 * in an element of e bits, repeated (7l's bits.c, a table there) *)
let bitmasks : (int64, int * int * int) Hashtbl.t =
  let t = Hashtbl.create 8192 in
  List.iter (fun e ->
    for s = 1 to e - 1 do
      for r = 0 to e - 1 do
        let ones = Int64.pred (Int64.shift_left 1L s) in
        let elt = if r = 0 then ones
          else Int64.logand (Int64.logor (Int64.shift_right_logical ones r) (Int64.shift_left ones (e - r)))
                 (if e = 64 then (-1L) else Int64.pred (Int64.shift_left 1L e)) in
        let v = ref 0L in
        for i = 0 to (64 / e) - 1 do v := Int64.logor !v (Int64.shift_left elt (i * e)) done;
        if not (Hashtbl.mem t !v) then Hashtbl.replace t !v (s, e, r)
      done
    done) [ 64; 32; 16; 8; 4; 2 ];
  t

let isaddcon v = v >= 0L && (let v = if Int64.logand v 0xfffL = 0L then Int64.shift_right v 12 else v in v <= 0xfffL)
let isbitcon v = Hashtbl.mem bitmasks v

(* the 16-bit lane holding all of v's bits, for MOVZ and MOVN *)
let movcon v =
  let rec lane s = if s >= 64 then -1 else if Int64.logand v (Int64.lognot (Int64.shift_left 0xffffL s)) = 0L then s / 16 else lane (s + 16) in
  lane 0

(* the classes of an offset, by range (7l's constclass and tables) *)
let constclass l =
  if l = 0 then 0
  else if l < 0 then (if l >= -256 then 1 else if l >= -512 && l land 7 = 0 then 2 else 10)
  else if l <= 255 then 3 else if l <= 504 && l land 7 = 0 then 4 else if l <= 4095 then 5
  else if l <= 8190 && l land 1 = 0 then 6 else if l <= 16380 && l land 3 = 0 then 7
  else if l <= 32760 && l land 7 = 0 then 8 else if l <= 65520 && l land 15 = 0 then 9 else 10

let autoclass = [| PSAUTO; NSAUTO; NPAUTO; PSAUTO; PPAUTO; UAUTO4K; UAUTO8K; UAUTO16K; UAUTO32K; UAUTO64K; LAUTO |]
let oregclass = [| ZOREG; NSOREG; NPOREG; PSOREG; PPOREG; UOREG4K; UOREG8K; UOREG16K; UOREG32K; UOREG64K; LOREG |]
let sextclass = [| SEXT1; LEXT; LEXT; SEXT1; SEXT1; SEXT1; SEXT2; SEXT4; SEXT8; SEXT16; LEXT |]

type ctx = { t : op Link.t; mutable autosize : int; mutable lastcase : int (* CASE's pc, for BCASE *) }

let sym ctx (p : prog) n =
  let s = sym_of ctx.t p.version n in
  if s.kind = Undefined then (let f, l = p.where in error "%s:%d: undefined: %s" f l n.A.sym);
  s

(* 7l's aclass: the class, and the value (instoffset) *)
let aclass ctx (p : prog) (a : A.operand option) : cls * int64 =
  let i = Int64.of_int in
  match a with
  | None -> NONE, 0L
  | Some (A.Reg _) -> REG, 0L
  | Some (A.FReg _) -> FREG, 0L
  | Some (A.Target _) -> SBRA, 0L
  | Some (A.Special _) -> COND, 0L
  | Some (A.Shifted _) -> SHIFT, 0L
  | Some (A.Fimm _) -> FCON, 0L
  | Some (A.Imm v) ->
      let c =
        if v = 0L then ZCON
        else if isaddcon v then (if isbitcon v then ABCON else if v <= 0xfffL then ADDCON0 else ADDCON)
        else if movcon v >= 0 || movcon (Int64.lognot v) >= 0 then (if isbitcon v then MBCON else MOVCON)
        else if isbitcon v then BITCON
        else LCON
      in
      c, v
  (* MOV.W and MOV.P: pre- and post-indexed *)
  | Some (A.Mem { base = R _; off; _ }) when List.mem "W" p.suffixes -> XPRE, off
  | Some (A.Mem { base = R _; off; _ }) when List.mem "P" p.suffixes -> XPOST, off
  | Some (A.Mem { base = R _; off; _ }) -> let v = Int64.to_int off in oregclass.(constclass v), i v
  | Some (A.Mem { base = SB; name = Some n; off; _ }) ->
      let v = (sym ctx p n).value + Int64.to_int off in
      (if v >= 0 then sextclass.(constclass v) else LEXT), i v
  | Some (A.Mem { base = (SP | FP) as b; off; _ }) ->
      let v = ctx.autosize + Int64.to_int off + (if b = FP then pcsz else 0) in
      autoclass.(constclass v), i v
  | Some (A.Addr { base = SB; name = Some n; off; _ }) ->
      let s = sym ctx p n in
      let v = s.value + Int64.to_int off in
      (* PIE: the address is pc-relative, by ADRP and ADD (goken's -H6) *)
      if s.kind = Text then (if ctx.t.pie then ADDR else LCON), i v
      else if v <> 0 && isaddcon (i v) then AECON, i v
      else (if ctx.t.pie then ADDR else LCON), i (v + ctx.t.data_start)
  | Some (A.Addr { base; off; _ }) ->
      let v = Int64.to_int off + (match base with SP -> ctx.autosize | FP -> ctx.autosize + pcsz | _ -> 0) in
      (if isaddcon (i v) then AACON else LACON), i v
  | _ -> GOK, 0L

(*****************************************************************************)
(* After loading (7l's ldobj) *)
(*****************************************************************************)

(* frames rounded to 8; an ADD or SUB of a negative constant is the
 * other; a float constant is in the data (7l has no FMOV immediate) *)
let prepare (t : op Link.t) =
  List.iter (fun (p : prog) ->
    match p.op, p.args with
    | Func, _ -> if p.frame > 0 then p.frame <- rnd p.frame 8
    | Ins (Arith (a, sz)), A.Imm n :: rest when n < 0L ->
        p.op <- Ins (Arith ((match a with Add -> Sub | Sub -> Add | Adds -> Subs | Subs -> Adds), sz));
        p.args <- A.Imm (Int64.neg n) :: rest
    | Ins (Fcvt D), A.Fimm x :: rest ->
        p.op <- Ins (Mov (Float S));
        p.args <- float_constant t x ~single:true :: rest
    | Ins (Mov (Float pr)), A.Fimm x :: rest -> p.args <- float_constant t x ~single:(pr = S) :: rest
    | _ -> ()) t.progs

(* 7l's follow: B and the returns end the flow *)
let follow (t : op Link.t) = Link.follow t ~ends:(fun p -> match p.op with B | Ins (Ret | Return) -> true | _ -> false)

(*****************************************************************************)
(* Rewriting: frames and RETURN (7l's noops; xix's Rewrite7) *)
(*****************************************************************************)

let mem ?(off = 0) b = A.Mem { base = A.R b; name = None; off = Int64.of_int off; index = None }
let imm n = A.Imm (Int64.of_int n)
let prog_like (p : prog) op suffixes args = { p with op; suffixes; args; target = None; frame = 0; leaf = false }
let become (p : prog) op suffixes args = p.op <- op; p.suffixes <- suffixes; p.args <- args; p.target <- None

(* the frame: 16-aligned, with R30 at its bottom, pushed by a
 * pre-indexed store of at most 240 bytes (MOV.W: 7a's -x(RSP)!, and
 * MOV.P for (RSP)x!); a leaf keeps R30 and makes no frame when it
 * needs none *)
let rewrite (t : op Link.t) =
  let cur = ref None in
  List.iter (fun (p : prog) ->
    match p.op with
    | Func -> p.leaf <- true; cur := Some p
    | Bl -> Option.iter (fun c -> c.leaf <- false) !cur
    | _ -> ()) t.progs;
  let autosize = ref 0 and leaf = ref true in
  t.progs <- List.concat_map (fun (p : prog) ->
    match p.op with
    | Func ->
        let a = if p.frame < 0 then 0 else p.frame + pcsz in
        let a = if p.leaf && a <= pcsz then 0 else rnd a 16 in
        autosize := a;
        p.frame <- a - pcsz;
        if a = 0 then p.leaf <- true;
        leaf := p.leaf;
        let push = if p.leaf then 0 else min a 0xf0 in
        let sub = if a > push then [ prog_like p (Ins (Arith (Sub, X))) [] [ imm (a - push); A.Reg reg_sp ] ] else [] in
        p :: sub @ (if p.leaf then [] else [ prog_like p (Ins (Mov (Int X64))) [ "W" ] [ A.Reg reg_link; mem reg_sp ~off:(- push) ] ])
    | Ins Return ->
        let ret = [ prog_like p (Ins Ret) [] [ mem reg_link ] ] in
        if !leaf then
          if !autosize = 0 then (become p (Ins Ret) [] [ mem reg_link ]; [ p ])
          else (become p (Ins (Arith (Add, X))) [] [ imm !autosize; A.Reg reg_sp ]; p :: ret)
        else begin
          let pop = min !autosize 0xf0 in
          become p (Ins (Mov (Int X64))) [ "P" ] [ mem reg_sp ~off:pop; A.Reg reg_link ];
          p :: (if !autosize > pop then [ prog_like p (Ins (Arith (Add, X))) [] [ imm (!autosize - pop); A.Reg reg_sp ] ] else []) @ ret
        end
    | _ -> [ p ]) t.progs

(*****************************************************************************)
(* Encoding (7l's asmout.c; xix's Codegen7) *)
(*****************************************************************************)

let s64 = 1 lsl 31
let opdp2 x = (0xd6 lsl 21) lor (x lsl 10)
let fpop1s typ op = (0x1e lsl 24) lor (typ lsl 22) lor (1 lsl 21) lor (op lsl 15) lor (0x10 lsl 10)
let fpop2s typ op = (0x1e lsl 24) lor (typ lsl 22) lor (1 lsl 21) lor (op lsl 12) lor (2 lsl 10)
let fpcvti sf typ rmode op = (sf lsl 31) lor (0x1e lsl 24) lor (typ lsl 22) lor (1 lsl 21) lor (rmode lsl 19) lor (op lsl 16)

let sf = function X -> s64 | W -> 0
let pbit = function S -> 0 | D -> 1

(* register operations (7l's oprrr) *)
let oprrr (op : op) =
  let arith sz sub s = sf sz lor (if sub then 1 lsl 30 else 0) lor (if s then 1 lsl 29 else 0) lor (0x0b lsl 24) in
  let logic sz opc n = sf sz lor (opc lsl 29) lor (0xa lsl 24) lor (if n then 1 lsl 21 else 0) in
  let madd sz o0 = sf sz lor (0x1b lsl 24) lor (o0 lsl 15) and long o = (1 lsl 31) lor (0x1b lsl 24) lor (o lsl 21) in
  let sfbit sz = if sz = X then 1 else 0 in
  match op with
  | Arith (a, sz) -> arith sz (a = Sub || a = Subs) (a = Adds || a = Subs)
  | Cmp (cmn, sz) -> arith sz (not cmn) true
  | Neg (s, sz) -> sf sz lor (1 lsl 30) lor (if s then 1 lsl 29 else 0) lor (0xb lsl 24)
  | Logic (l, sz) -> logic sz (match l with And -> 0 | Orr -> 1 | Eor -> 2 | Ands -> 3) false
  | Mov (Int X64) -> logic X 1 false
  | Mov (Int W32u) -> logic W 1 false
  | Mvn sz -> logic sz 1 true
  | Shift (k, sz) -> sf sz lor opdp2 (8 + Link.shift_bits k)
  | Div (u, sz) | Rem (u, sz) -> sf sz lor opdp2 (if u then 2 else 3)
  | Mul sz -> madd sz 0
  | Mneg sz -> madd sz 1
  | Mull u -> long (if u then 5 else 1)
  | Mulh u -> long (if u then 6 else 2)
  | Fcvtz (u, pr, sz) -> fpcvti (sfbit sz) (pbit pr) 3 (if u then 1 else 0)
  | Cvtf (u, sz, pr) -> fpcvti (sfbit sz) (pbit pr) 0 (if u then 3 else 2)
  | Farith (f, pr) -> fpop2s (pbit pr) (match f with Fmul -> 0 | Fdiv -> 1 | Fadd -> 2 | Fsub -> 3 | Fnmul -> 8)
  | Fcmp pr -> (0x1e lsl 24) lor (pbit pr lsl 22) lor (1 lsl 21) lor (8 lsl 10)
  | Mov (Float pr) -> fpop1s (pbit pr) 0
  | Funary (f, pr) -> fpop1s (pbit pr) (match f with Fabs -> 1 | Fneg -> 2 | Fsqrt -> 3)
  | Fcvt S -> fpop1s 0 5
  | Fcvt D -> fpop1s 1 4
  | Mov (Int (B8 | B8u | H16 | H16u | W32)) | Ext _ | Cbz _ | Ret | Return | Svc | Case | Word | Dword -> error "bad rrr %s" (show op)

(* MSUB, for REM *)
let msub sz = sf sz lor (0x1b lsl 24) lor (1 lsl 15)

(* immediate operations (7l's opirr) *)
let addi sz sub s = sf sz lor (if sub then 1 lsl 30 else 0) lor (if s then 1 lsl 29 else 0) lor (0x11 lsl 24)
let logici sz l = sf sz lor ((match l with And -> 0 | Orr -> 1 | Eor -> 2 | Ands -> 3) lsl 29) lor (0x24 lsl 23)
let movn sz = sf sz lor (0x25 lsl 23) and movz sz = sf sz lor (2 lsl 29) lor (0x25 lsl 23)

(* SBFM and UBFM: the shifts and extensions by a constant *)
let bfm signed sz r s rf rt =
  sf sz lor (if signed then 0 else 2 lsl 29) lor (0x26 lsl 23) lor (if sz = X then 1 lsl 22 else 0)
  lor ((r land 0x3f) lsl 16) lor ((s land 0x3f) lsl 10) lor (rf lsl 5) lor rt

let opirr (op : op) =
  match op with
  | Arith (a, sz) -> addi sz (a = Sub || a = Subs) (a = Adds || a = Subs)
  | Cmp (cmn, sz) -> addi sz (not cmn) true
  | Mov (Int X64) -> addi X false false
  | Mov (Int W32) -> addi W false false
  | Logic (l, sz) -> logici sz l
  | Cbz (nz, sz) -> sf sz lor (0x1a lsl 25) lor (if nz then 1 lsl 24 else 0)
  | Mov (Int (B8 | B8u | H16 | H16u | W32u) | Float _) | Neg _ | Mvn _ | Shift _ | Div _ | Rem _ | Mul _ | Mneg _ | Mull _ | Mulh _
  | Ext _ | Farith _ | Funary _ | Fcmp _ | Fcvt _ | Fcvtz _ | Cvtf _ | Ret | Return | Svc | Case | Word | Dword -> error "bad irr %s" (show op)

let opbra : op Link.op -> int = function
  | B -> 5 lsl 26
  | Bl -> (1 lsl 31) lor (5 lsl 26)
  | Bcond c -> (0x2a lsl 25) lor cond_bits c
  | (Func | Nop | Bcase | Ins _) as op -> error "bad bra %s" (show_op show op)

let opbrr : op Link.op -> int = function
  | Bl -> (0x6b lsl 25) lor (1 lsl 21) lor (0x1f lsl 16)
  | B -> (0x6b lsl 25) lor (0x1f lsl 16)
  | Ins Ret -> (0x6b lsl 25) lor (2 lsl 21) lor (0x1f lsl 16)
  | (Func | Nop | Bcond _ | Bcase | Ins _) as op -> error "bad brr %s" (show_op show op)

(* loads and stores: size's log, vector, opc (7l's LDSTR12U, LDSTR9S) *)
let ldst = function
  | Int X64 -> 3, 0, 1 | Int W32 -> 2, 0, 2 | Int W32u -> 2, 0, 1 | Int H16 -> 1, 0, 2 | Int H16u -> 1, 0, 1
  | Int B8 -> 0, 0, 2 | Int B8u -> 0, 0, 1 | Float S -> 2, 1, 1 | Float D -> 3, 1, 1

let opldr12 m = let sz, v, opc = ldst m in (sz lsl 30) lor (7 lsl 27) lor (v lsl 26) lor (1 lsl 24) lor (opc lsl 22)
let opldr9 m = opldr12 m land lnot (1 lsl 24)
let tostore o = o land lnot (3 lsl 22)

let olsr12u o v b r = if v < 0 || v >= 1 lsl 12 then error "offset out of range: %d" v else o lor ((v land 0xfff) lsl 10) lor (b lsl 5) lor r
let olsr9s o v b r = if v < -256 || v > 255 then error "offset out of range: %d" v else o lor ((v land 0x1ff) lsl 12) lor (b lsl 5) lor r

let oaddi o1 v r rt =
  if v < 0 || v > 0xfff000 then error "offset out of range for ADD/SUB immediate: %#x" v;
  let o1, v = if v > 0xfff then o1 lor (1 lsl 22), v lsr 12 else o1, v in
  o1 lor ((v land 0xfff) lsl 10) lor (r lsl 5) lor rt

let adr p o rt = (p lsl 31) lor ((o land 3) lsl 29) lor (0x10 lsl 24) lor (((o asr 2) land 0x7ffff) lsl 5) lor rt

(*****************************************************************************)
(* Choosing an encoding (7l's optab, oplook and asmout) *)
(*****************************************************************************)

(* an instruction's encoding: its size, the operand it puts in the
 * literal pool, and its words, made once the pcs are known *)
(* old: 7l's design, a table of 90 rules (opcode and three operand
 * classes, a case number, a size, flags), sorted by the classes' ranks
 * so that the first that fits is the one wanted, a cached index into
 * it in each prog, and asmout's switch on the case numbers 1 to 66,
 * away from what chose them. Here one match on the opcode tries the
 * forms in the table's order, each next to its words; so written, the
 * table's dead rules showed (an ADD to RSP, MVN's shifted form, the
 * case 0s) *)
type action = { size : int; pool : A.operand option; words : unit -> int list }

let select ctx (p : prog) : action =
  let v = view p in
  let c1 = fst (aclass ctx p v.from) and c3 = fst (aclass ctx p v.to_) in
  let none = v.reg = None and fits a1 a3 = cmp a1 c1 && cmp a3 c3 in
  let illegal () = let f, l = p.where in error "%s:%d: illegal combination: %s" f l (Link.show show p) in
  let off a = Int64.to_int (snd (aclass ctx p a)) in
  let rt = if v.to_ = None then reg_zero else regno v.to_ and rf = regno v.from in
  let r = match v.reg with Some r -> r | None -> rt in
  (* a memory operand's base: SB's and the frame's registers for a name
   * and an auto *)
  let base = function Some (A.Mem { base = R b; _ }) -> b | Some (A.Mem { base = SB; _ }) -> reg_sb | _ -> reg_sp in
  let brdist preshift flen shift =
    let d = match p.target with Some q -> (q.pc asr preshift) - (p.pc asr preshift) | None -> 0 in
    if d land ((1 lsl shift) - 1) <> 0 then error "misaligned label";
    let d = d asr shift in
    if d < - (1 lsl (flen - 1)) || d >= 1 lsl (flen - 1) then error "branch too far";
    d land ((1 lsl flen) - 1)
  in
  (* a literal from the pool into dr (7l's omovlit) *)
  let omovlit ?(a = v.from) (m : mov) dr =
    match p.target with
    | None ->
        (* not in the pool: an ADD from ZR, of 12 bits (7l's own fallback) *)
        let x = off a in
        let o1, x = if x <> 0 && x land 0xfff = 0 then addi X false false lor (1 lsl 22), x asr 12 else addi X false false, x in
        o1 lor ((x land 0xfff) lsl 10) lor (reg_zero lsl 5) lor dr
    | Some w ->
        let raw = match w.args with [ A.Imm n ] -> n | [ A.Addr m ] | [ A.Mem m ] -> m.off | _ -> 0L in
        let fp, wd = match m with
          | Float S -> 1, 0 | Float D -> 1, 1
          | Int X64 -> 0, if w.op = Ins Dword then 1 else if raw < 0L then 2 else 0
          | Int (B8 | H16 | W32) -> 0, 2 | Int (B8u | H16u | W32u) -> 0, 0 in
        (wd lsl 30) lor (fp lsl 26) lor (3 lsl 27) lor ((brdist 0 19 2 land 0x7ffff) lsl 5) lor dr
  in
  let act ?pool size words = { size; pool; words } in
  let one w = act 4 (fun () -> [ w () ]) in
  (* op R, [R], R; with R<<n; with a constant from the pool (7l's cases 1, 3, 13) *)
  let rrr m = one (fun () -> oprrr m lor (rf lsl 16) lor (r lsl 5) lor rt) in
  let shifted m = one (fun () ->
    let s = match v.from with Some (A.Shifted { reg; kind; by = `Imm n }) -> (Link.shift_bits kind lsl 22) lor (reg lsl 16) lor ((n land 63) lsl 10) | _ -> 0 in
    oprrr m lor s lor (r lsl 5) lor rt) in
  let pooled m = act 8 ?pool:v.from (fun () ->
    (* the extended-register form when SP is involved (7l's opxrrr) *)
    let o2 = if v.to_ <> None && (rt = reg_sp || r = reg_sp) then oprrr m lor (1 lsl 21) lor (3 lsl 13) else oprrr m in
    [ omovlit (Int X64) reg_tmp; o2 lor (reg_tmp lsl 16) lor (r lsl 5) lor rt ]) in
  (* loads and stores: by the offset's class, a scaled 12-bit or signed
   * 9-bit offset, a long one by REGTMP, or pre- and post-indexed *)
  let move (m : mov) =
    let x = match m with Float _ -> FREG | Int _ -> REG and scale, _, _ = ldst m in
    let short = [ [| SEXT1; SEXT2; SEXT4; SEXT8 |].(scale); [| UAUTO4K; UAUTO8K; UAUTO16K; UAUTO32K |].(scale); ZOREG;
                  [| UOREG4K; UOREG8K; UOREG16K; UOREG32K |].(scale); NSAUTO; NSOREG ] in
    let long = [ LEXT; LAUTO; LOREG ] in
    let fits_any cs c = List.exists (fun a -> cmp a c) cs in
    let access store =
      let a = if store then v.to_ else v.from and rd = if store then rf else rt in
      let st o = if store then tostore o else o in
      one (fun () ->
        let x = off a and b = base a in
        if x < 0 then olsr9s (st (opldr9 m)) x b rd
        else if (x asr scale) lsl scale <> x then error "odd offset: %d" x
        else olsr12u (st (opldr12 m)) (x asr scale) b rd)
    in
    let long_access store =
      let a = if store then v.to_ else v.from and rd = if store then rf else rt in
      let st o = if store then tostore o else o in
      (* the pool for a name's offset, and for floats' *)
      let pool = if x = FREG || cmp LEXT (if store then c3 else c1) then a else None in
      act 8 ?pool (fun () ->
        let x = off a in
        if x land ((1 lsl scale) - 1) <> 0 then error "misaligned offset";
        if x < 0 || x >= 1 lsl 24 then
          (* huge: the offset into REGTMP, then a register-offset access,
           * sign-extended (7l's cases 47 and 48) *)
          let o2 = opldr9 m lor (1 lsl 21) lor (reg_tmp lsl 16) lor (2 lsl 10) lor (base a lsl 5) lor rd lor (7 lsl 13) in
          [ omovlit ~a (Int X64) reg_tmp; st o2 ]
        else
          let hi = x - (x land (0xfff lsl scale)) in
          [ oaddi (addi X false false) hi (base a) reg_tmp; olsr12u (st (opldr12 m)) (((x - hi) asr scale) land 0xfff) reg_tmp rd ])
    in
    let indexed store =
      let a = if store then v.to_ else v.from in
      one (fun () ->
        let x = match a with Some (A.Mem mm) -> Int64.to_int mm.off | _ -> 0 in
        if x < -256 || x > 255 then error "offset out of range";
        let o1 = opldr9 m lor (if List.mem "P" p.suffixes then 1 lsl 10 else 3 lsl 10) in
        (if store then tostore o1 else o1) lor ((x land 0x1ff) lsl 12) lor (regno a lsl 5) lor (if store then rf else rt))
    in
    if not none then None
    else if cmp x c1 && fits_any short c3 then Some (access true)
    else if cmp x c1 && fits_any long c3 then Some (long_access true)
    else if cmp x c1 && (c3 = XPOST || c3 = XPRE) then Some (indexed true)
    else if cmp x c3 && fits_any short c1 then Some (access false)
    else if cmp x c3 && fits_any long c1 then Some (long_access false)
    else if cmp x c3 && (c1 = XPOST || c1 = XPRE) then Some (indexed false)
    else None
  in
  (* MOVB ... UXTW between registers: SBFM or UBFM; MOVWU's, and one
   * from ZR, a 32-bit ORR *)
  let movwu () = oprrr (Mov (Int W32u)) lor (rf lsl 16) lor (reg_zero lsl 5) lor rt in
  let extend (w : width) sz =
    one (fun () ->
      let signed = match w with B8 | H16 | W32 | X64 -> true | B8u | H16u | W32u -> false in
      let bits = match w with B8 | B8u -> 7 | H16 | H16u -> 15 | W32 | W32u | X64 -> 31 in
      if rf = reg_zero then movwu () else bfm signed sz 0 bits rf rt)
  in
  (* MOVZ or MOVN of the one 16-bit lane *)
  let movwide sz = one (fun () ->
    let d = match v.from with Some (A.Imm d) -> d | _ -> 0L in
    let s = movcon d in
    let o1, d, s = if s < 0 then movn sz, Int64.lognot d, movcon (Int64.lognot d) else movz sz, d, s in
    if s < 0 then error "impossible move wide: %Lx" d;
    o1 lor ((Int64.to_int (Int64.shift_right_logical d (s * 16)) land 0xffff) lsl 5) lor ((s land 3) lsl 21) lor rt) in
  let from_pool m = act 4 ?pool:v.from (fun () -> [ omovlit m rt ]) in
  (* an ADD of a 12-bit constant, maybe shifted, to SB or SP (7l's case 4) *)
  let addcon base = one (fun () ->
    let x = off v.from in
    let o1, x = if x land 0xfff000 <> 0 then addi X false false lor (1 lsl 22), x asr 12 else addi X false false, x in
    o1 lor ((x land 0xfff) lsl 10) lor (base lsl 5) lor rt) in
  match v.op with
  | Ins (Arith _ as m) ->
      if fits REG REG then rrr m
      else if fits SHIFT REG then shifted m
      else if fits ADDCON RSP then one (fun () -> oaddi (opirr m) (off v.from) r rt)
      else if fits LCON REG then pooled m
      else illegal ()
  | Ins (Cmp _ as m) ->
      if none then illegal ()
      else if fits REG NONE then rrr m
      else if fits SHIFT NONE then shifted m
      else if fits ADDCON NONE then one (fun () -> oaddi (opirr m) (off v.from) r rt)
      else if fits LCON NONE then pooled m
      else illegal ()
  | Ins (Logic (l, sz) as m) ->
      if fits REG REG then rrr m
      else if fits SHIFT REG then shifted m
      else if fits BITCON REG then one (fun () ->
        (* goken's encoding, which leaves out the element size of the
         * patterns under 64 bits (a known 7l bug: xix's arm64_port.md) *)
        let o1 = logici sz l and s = if sz = X then 64 else 32 in
        let x = match v.from with Some (A.Imm x) -> x | _ -> 0L in
        let mask = match Hashtbl.find_opt bitmasks x with
          | None when s = 32 -> Hashtbl.find_opt bitmasks (Int64.logor x (Int64.shift_left x 32)) | m -> m in
        match mask with
        | Some (ms, e, mr) ->
            o1 lor ((mr land (s - 1)) lsl 16) lor (((ms - 1) land (s - 1)) lsl 10) lor (if s = 64 && e = 64 then 1 lsl 22 else 0)
            lor (r lsl 5) lor rt
        | None -> error "invalid mask %Lx" x)
      else if fits LCON REG then act 8 ?pool:v.from (fun () -> [ omovlit (Int X64) reg_tmp; oprrr m lor (reg_tmp lsl 16) lor (r lsl 5) lor rt ])
      else illegal ()
  | Ins (Neg _ | Mvn _ as m) when none && fits REG REG -> one (fun () -> oprrr m lor (rf lsl 16) lor (reg_zero lsl 5) lor rt)
  | Ins (Mov (Int X64) as m) -> (
      match move (Int X64) with
      | Some a -> a
      | None when not none -> illegal ()
      | None ->
          if fits RSP RSP then one (fun () -> if rf = reg_sp || rt = reg_sp then opirr m lor (rf lsl 5) lor rt else oprrr m lor (rf lsl 16) lor (reg_zero lsl 5) lor rt)
          else if fits MOVCON REG then movwide X
          else if fits LCON REG then from_pool (Int X64)
          else if fits AACON REG then addcon reg_sp
          else if fits LACON REG then
            act 8 ?pool:v.from (fun () ->
              [ omovlit (Int X64) reg_tmp; s64 lor (0x0b lsl 24) lor (1 lsl 21) lor (3 lsl 13) lor (reg_tmp lsl 16) lor (reg_sp lsl 5) lor rt ])
          else if fits AECON REG then addcon reg_sb
          else if fits ADDR REG then
            act 8 (fun () ->
              (* the page's distance, then the offset in it *)
              let d = off v.from in
              let x = (d asr 12) - (p.pc asr 12) in
              if x < - (1 lsl 20) || x >= 1 lsl 20 then error "adrp page displacement out of range";
              [ (1 lsl 31) lor (0x10 lsl 24) lor ((x land 3) lsl 29) lor (((x asr 2) land 0x7ffff) lsl 5) lor rt;
                addi X false false lor ((d land 0xfff) lsl 10) lor (rt lsl 5) lor rt ])
          else illegal ())
  | Ins (Mov (Int (W32 | W32u as w))) -> (
      match move (Int w) with
      | Some a -> a
      | None ->
          if none && fits REG REG then (if w = W32u then one movwu else extend w X)
          else if none && fits MOVCON REG then movwide W
          else if none && fits LCON REG then from_pool (Int w)
          else illegal ())
  | Ins (Mov (Int (B8 | B8u | H16 | H16u as w))) -> (
      match move (Int w) with Some a -> a | None -> if none && fits REG REG then extend w X else illegal ())
  | Ins (Mov (Float _ as m)) -> (
      match move m with
      | Some a -> a
      | None -> if none && fits FREG FREG then one (fun () -> oprrr (Mov m) lor (rf lsl 5) lor rt) else illegal ())
  | Ins (Ext (w, sz)) when none && fits REG REG -> extend w sz
  | Ins (Shift (k, sz) as m) ->
      if fits REG REG then rrr m
      else if fits LCON REG then one (fun () ->
        let n = off v.from and m = if sz = X then 63 else 31 in
        match k with
        | Asr -> bfm true sz n m r rt
        | Lsl -> bfm false sz ((m + 1 - n) land m) (m - n) r rt
        | Lsr -> bfm false sz n m r rt
        | Ror -> error "bad shift $con")
      else illegal ()
  | Ins (Div _ as m) when fits REG REG -> rrr m
  | Ins (Mul _ | Mneg _ | Mull _ | Mulh _ as m) when fits REG REG ->
      one (fun () -> oprrr m lor (rf lsl 16) lor (reg_zero lsl 10) lor (r lsl 5) lor rt)
  | Ins (Rem (_, sz) as m) when fits REG REG ->
      (* the quotient, then the remainder by MSUB *)
      act 8 (fun () ->
        let o1 = oprrr m lor (rf lsl 16) lor (r lsl 5) lor reg_tmp in
        [ o1; msub sz lor (rf lsl 16) lor (r lsl 10) lor (reg_tmp lsl 5) lor rt ])
  | Ins (Farith _ as m) when fits FREG FREG -> one (fun () -> oprrr m lor (rf lsl 16) lor (r lsl 5) lor rt)
  | Ins (Fcmp _ as m) when not none && (fits FREG NONE || fits FCON NONE) ->
      one (fun () ->
        let o1, rf = match v.from with Some (A.Fimm _) -> oprrr m lor 8, 0 | _ -> oprrr m, rf in
        o1 lor (rf lsl 16) lor (r lsl 5))
  | Ins (Fcvtz _ as m) when none && fits FREG REG -> one (fun () -> oprrr m lor (rf lsl 5) lor rt)
  | Ins (Cvtf _ as m) when none && fits REG FREG -> one (fun () -> oprrr m lor (rf lsl 5) lor rt)
  | Ins (Fcvt _ | Funary _ as m) when none && fits FREG FREG -> one (fun () -> oprrr m lor (rf lsl 5) lor rt)
  (* branches *)
  | (B | Bl) when fits NONE SBRA -> one (fun () -> opbra v.op lor brdist 0 26 2)
  | (B | Bl | Ins Ret) when fits NONE ZOREG || (v.op = Ins Ret && fits NONE REG) -> one (fun () -> opbrr v.op lor (regno v.to_ lsl 5))
  | Bcond _ when fits NONE SBRA -> one (fun () -> opbra v.op lor (brdist 0 19 2 lsl 5))
  | Ins (Cbz _ as m) when none && fits REG SBRA -> one (fun () -> opirr m lor rf lor (brdist 0 19 2 lsl 5))
  | Ins Svc when none && (fits NONE NONE || fits NONE LCON) ->
      one (fun () -> (0xd4 lsl 24) lor 1 lor (if v.to_ <> None then (off v.to_ land 0xffff) lsl 5 else 0))
  (* a switch: the table of offsets that follows, at CASE+16 *)
  | Ins Case when none && fits REG REG ->
      act 16 (fun () ->
        ctx.lastcase <- p.pc;
        [ adr 0 16 rt;
          (2 lsl 30) lor (7 lsl 27) lor (2 lsl 22) lor (1 lsl 21) lor (3 lsl 13) lor (1 lsl 12) lor (2 lsl 10) lor (rf lsl 16) lor (rt lsl 5) lor reg_tmp;
          oprrr (Arith (Add, X)) lor (rt lsl 16) lor (reg_tmp lsl 5) lor reg_tmp;
          (0x6b lsl 25) lor (0x1f lsl 16) lor (reg_tmp lsl 5) ])
  | Bcase when fits NONE SBRA -> one (fun () -> match p.target with Some q -> (q.pc - (ctx.lastcase + 16)) land 0xffffffff | None -> 0)
  (* the pool's words *)
  | Ins Dword when fits NONE VCON || fits NONE LEXT ->
      act 8 (fun () -> let d = snd (aclass ctx p v.to_) in [ Int64.to_int (Int64.logand d 0xffffffffL); Int64.to_int (Int64.shift_right_logical d 32) ])
  | Ins Word when fits NONE LCON || fits NONE LEXT -> one (fun () -> off v.to_ land 0xffffffff)
  | Func | Nop | B | Bl | Bcond _ | Bcase
  | Ins (Neg _ | Mvn _ | Ext _ | Div _ | Mul _ | Mneg _ | Mull _ | Mulh _ | Rem _ | Farith _ | Fcmp _ | Fcvtz _ | Cvtf _ | Fcvt _ | Funary _
        | Cbz _ | Ret | Return | Svc | Case | Dword | Word) -> illegal ()

(*****************************************************************************)
(* Layout: pcs and the literal pool (7l's span, addpool, flushpool,
 * checkpool; xix's Layout7) *)
(*****************************************************************************)

let ispcdisp v = v >= -0xfffff && v <= 0xfffff && v land 3 = 0

let layout (t : op Link.t) =
  let ctx = { t; autosize = 0; lastcase = 0 } in
  let pool = ref [] (* (key, word), newest first *) and pool_start = ref 0 and pool_size = ref 0 in
  let out = ref [] in
  (* the pool after p: behind a B around it when [skip] (to itself at
   * the very end) *)
  let flush (p : prog) rest skip =
    if !pool = [] then rest
    else if (not skip) && p.pc + !pool_size - !pool_start < 1024 * 1024 then rest
    else begin
      let words = List.rev_map snd !pool in
      pool := [];
      pool_start := 0;
      pool_size := 0;
      if skip then begin
        let b = prog_like p B [] [ A.Target 0 ] in
        b.target <- (match rest with q :: _ -> Some q | [] -> None);
        (b :: words) @ rest
      end
      else words @ rest
    end
  in
  let check (p : prog) rest skip =
    if !pool_size >= 0xffff0 || not (ispcdisp (p.pc + 4 + !pool_size - !pool_start + 8)) then flush p rest skip
    else if rest = [] then flush p rest true
    else rest
  in
  let add_pool (p : prog) (a : A.operand option) =
    let c, v = aclass ctx p a in
    let raw = match a with Some (A.Imm n) -> n | Some (A.Addr m | A.Mem m) -> m.off | _ -> 0L in
    let dword = p.op = Ins (Mov (Int X64)) || (cmp VCON c && Int64.logand raw 0xffffffffL <> raw) in
    let built = List.mem c [ PSAUTO; PPAUTO; UAUTO4K; UAUTO8K; UAUTO16K; UAUTO32K; UAUTO64K; NSAUTO; NPAUTO; LAUTO; PPOREG; PSOREG;
                             UOREG4K; UOREG8K; UOREG16K; UOREG32K; UOREG64K; NSOREG; NPOREG; LOREG; LACON ] in
    let operand, sz = if built then A.Imm v, 4 else Option.get a, if dword then 8 else 4 in
    (* the operand, as 7l's memcmp of it: a name<> is its object's *)
    let key = operand, (match operand with
      | _ when built -> -1   (* an offset made a constant: never the same record as an operand's *)
      | A.Mem { name = Some { static = true; _ }; _ } | A.Addr { name = Some { static = true; _ }; _ } -> p.version | _ -> 0) in
    match List.assoc_opt key !pool with
    | Some w -> p.target <- Some w
    | None ->
        let w = prog_like p (Ins (if dword then Dword else Word)) [] [ operand ] in
        if !pool = [] then pool_start := p.pc;
        pool := (key, w) :: !pool;
        pool_size := rnd !pool_size sz + sz;
        p.target <- Some w
  in
  let pc = ref t.text_start in
  let rec go = function
    | [] -> ()
    | (p : prog) :: rest ->
        if p.op = Ins Dword && !pc land 7 <> 0 then pc := !pc + 4;
        p.pc <- !pc;
        out := p :: !out;
        if p.op = Func then begin
          ctx.autosize <- p.frame + pcsz;
          (match p.args with A.Mem { name = Some n; _ } :: _ -> (sym_of t p.version n).value <- !pc | _ -> ());
          go rest
        end
        else begin
          let a = select ctx p in
          if a.pool <> None then add_pool p a.pool;
          let rest = if p.op = B || p.op = Ins Ret then check p rest false else rest in
          pc := !pc + a.size;
          let rest = if !pool <> [] then check p rest true else rest in
          go rest
        end
  in
  go t.progs;
  t.progs <- List.rev !out;
  let c = rnd !pc 8 in
  t.text_size <- c - t.text_start;
  (lookup t "etext" 0).value <- c;
  t.data_start <- rnd c t.data_round


let encode (t : op Link.t) : Bytes.t =
  let ctx = { t; autosize = 0; lastcase = 0 } in
  let b = Bytes.make t.text_size '\000' in
  List.iter (fun (p : prog) ->
    if p.op = Func then ctx.autosize <- p.frame + pcsz
    else begin
      (* chosen again, now that the pcs are known: as layout chose it *)
      let a = select ctx p in
      let ws = a.words () in
      if 4 * List.length ws <> a.size then (let f, l = p.where in error "%s:%d: phase error: %s" f l (Link.show show p));
      List.iteri (fun i w -> Link.put32 b (p.pc - t.text_start + (4 * i)) w) ws
    end) t.progs;
  b
