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
(* Opcodes (5.out.h; 5a's lex.c) *)
(*****************************************************************************)

(* the data-processing operations, and those that only set the flags *)
type alu = And | Eor | Sub | Rsb | Add | Adc | Sbc | Rsc | Orr | Bic
type test = Tst | Teq | Cmp | Cmn

(* a load's or store's width; u: zero-extended *)
type width = B8 | B8u | H16 | H16u | W32
type prec = F | D
type farith = Fadd | Fsub | Fmul | Fdiv

(* bool: the unsigned forms (MULU, DIVU, MODU); Mull's second, MULAL's
 * accumulating; a conversion's prec is its result's *)
(* old: the mnemonic's string, matched with catch-alls ending in "bad
 * data-processing op", its letters looked at (op.[0], op.[3]) *)
type op =
  | Alu of alu | Test of test | Mov of width | Mvn | Shift of A.shift_kind
  | Mul of bool | Mula | Mull of bool * bool | Div of bool | Mod of bool
  | Swi | Movm | Case | Word | Ret
  | Fmov of prec | Farith of farith * prec | Fcmp of prec | Fcvt of prec | Itof of prec | Ftoi of prec

type prog = op Link.prog

let show op =
  let p = function F -> "F" | D -> "D" and u b = if b then "U" else "" in
  match op with
  | Alu a -> (match a with And -> "AND" | Eor -> "EOR" | Sub -> "SUB" | Rsb -> "RSB" | Add -> "ADD" | Adc -> "ADC"
                         | Sbc -> "SBC" | Rsc -> "RSC" | Orr -> "ORR" | Bic -> "BIC")
  | Test t -> (match t with Tst -> "TST" | Teq -> "TEQ" | Cmp -> "CMP" | Cmn -> "CMN")
  | Mov w -> (match w with B8 -> "MOVB" | B8u -> "MOVBU" | H16 -> "MOVH" | H16u -> "MOVHU" | W32 -> "MOVW")
  | Mvn -> "MVN"
  | Shift k -> (match k with Lsl -> "SLL" | Lsr -> "SRL" | Asr -> "SRA" | Ror -> "SRR")
  | Mul un -> "MUL" ^ u un
  | Mula -> "MULA"
  | Mull (un, acc) -> "MUL" ^ (if acc then "AL" else "L") ^ u un
  | Div un -> "DIV" ^ u un
  | Mod un -> "MOD" ^ u un
  | Swi -> "SWI" | Movm -> "MOVM" | Case -> "CASE" | Word -> "WORD" | Ret -> "RET"
  | Fmov pr -> "MOV" ^ p pr
  | Farith (f, pr) -> (match f with Fadd -> "ADD" | Fsub -> "SUB" | Fmul -> "MUL" | Fdiv -> "DIV") ^ p pr
  | Fcmp pr -> "CMP" ^ p pr
  | Fcvt D -> "MOVFD"
  | Fcvt F -> "MOVDF"
  | Itof pr -> "MOVW" ^ p pr
  | Ftoi pr -> "MOV" ^ p pr ^ "W"

(* the opcodes, each once: show's inverse is a table of them *)
let decode =
  let each l f = List.concat_map f l and both = [ false; true ] and precs = [ F; D ] in
  let ops = List.concat [
    List.map (fun a -> Alu a) [ And; Eor; Sub; Rsb; Add; Adc; Sbc; Rsc; Orr; Bic ];
    List.map (fun t -> Test t) [ Tst; Teq; Cmp; Cmn ];
    List.map (fun w -> Mov w) [ B8; B8u; H16; H16u; W32 ];
    List.map (fun k -> Shift k) [ A.Lsl; Lsr; Asr ];
    List.map (fun b -> Mul b) both; List.map (fun b -> Div b) both; List.map (fun b -> Mod b) both;
    each both (fun un -> List.map (fun acc -> Mull (un, acc)) both);
    [ Mvn; Mula; Swi; Movm; Case; Word; Ret ];
    each precs (fun pr -> [ Fmov pr; Fcmp pr; Fcvt pr; Itof pr; Ftoi pr ]);
    each [ Fadd; Fsub; Fmul; Fdiv ] (fun f -> List.map (fun pr -> Farith (f, pr)) precs) ] in
  let t = Hashtbl.create 128 in
  List.iter (fun op -> Hashtbl.replace t (show op) op) ops;
  Hashtbl.find_opt t

(*****************************************************************************)
(* Registers, conditions, suffixes (5l's l.h, 5.out.h; 5a's lex.c) *)
(*****************************************************************************)

let reg_tmp = 11 and reg_sb = 12 and reg_sp = 13 and reg_link = 14 and reg_pc = 15
let big = 4092        (* R12 is the data's start + BIG: 5l's setR12 *)

let c_sbit = 1 lsl 4 and c_pbit = 1 lsl 5 and c_wbit = 1 lsl 6 and c_ubit = 1 lsl 7
let always = 14

(* a condition suffix's code, AL's always *)
let condition s = if s = "AL" then Some always else Option.map cond_bits (cond_of_string s)

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

(* an instruction as 5l sees it: opcode, condition, from, middle register, to *)
type view = { op : op Link.op; sc : int; from : A.operand option; reg : int option; to_ : A.operand option }

let view (p : prog) : view =
  let op = p.op in
  let sc = scond p in
  (* a branch to a name is to its TEXT (resolved), a C_BRANCH *)
  let branch = match op with B | Bl | Bcond _ | Bcase -> true | Func | Nop | Ins _ -> false in
  let args = List.map (function A.Mem { base = SB; _ } when branch && p.target <> None -> A.Target 0 | a -> a) p.args in
  let v from reg to_ = { op; sc; from; reg; to_ } in
  match op, args with
  | Ins (Test _), [ a; A.Reg r ] | Ins (Fcmp _), [ a; A.FReg r ] -> v (Some a) (Some r) None
  | Ins Case, [ a ] -> v (Some a) None None
  | _, [ a ] -> v None None (Some a)
  | _, [ a; b ] -> v (Some a) None (Some b)
  | _, [ a; (A.Reg r | A.FReg r); c ] -> v (Some a) (Some r) (Some c)
  | _, [] -> v None None None
  | _ -> let f, l = p.where in error "%s:%d: %s: bad operands" f l (show_op show op)

(*****************************************************************************)
(* Operand classes (5l's m.h C_xxx, span.c's aclass, cmp) *)
(*****************************************************************************)

(* 5l's classes (C_xxx) *)
type cls = NONE | REG | BRANCH | RCON | NCON | LCON | HOREG | FOREG | HFOREG | SOREG | LOREG | ROREG | SROREG
  | HEXT | FEXT | HFEXT | SEXT | LEXT | HAUTO | FAUTO | HFAUTO | SAUTO | LAUTO | RECON | RACON | LACON
  | SHIFT | ADDR | FREG | FCON | FCR | REGREG | PSR | GOK
[@@warning "-37"]

(* 5l's cmp: may a form for class [a] take an operand of class [b] *)
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

type ctx = { t : op Link.t; mutable autosize : int }

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
(* Following the flow (5l's follow and xfol; not in xix) *)
(*****************************************************************************)

(* after loading (5a's outcode, 5l's ldobj): B.NE is BNE, and always,
 * BCS is BHS; not so the B that a conditional RET becomes, later. A
 * float constant that is no FPA immediate is in the data, in a symbol
 * named by its bits *)
let prepare (t : op Link.t) =
  List.iter (fun (p : prog) ->
    (* a constant is 32 bits, sign-extended, as 5l reads it from 5a's
     * object: $0x80000000 is $-2147483648 *)
    p.args <- List.map (function A.Imm n -> A.Imm (Int64.of_int (sx32 n)) | a -> a) p.args;
    match p.op, p.args with
    | Func, _ -> p.frame <- rnd p.frame 4
    | Ins (Fmov pr), A.Fimm x :: rest when chip_float x = None ->
        p.args <- float_constant t x ~single:(pr = F) :: rest
    | _ -> ()) t.progs;
  List.iter (fun (p : prog) ->
    match p.op, List.partition (fun s -> condition s <> None) p.suffixes with
    | B, (c :: _, rest) ->
        p.op <- (match cond_of_string c with Some c -> Bcond c | None -> B);
        p.suffixes <- rest
    | _ -> ()) t.progs

(* 5l's follow: B and an unconditional RET end the flow *)
let follow (t : op Link.t) =
  Link.follow t ~ends:(fun p -> p.op = B || (p.op = Ins Ret && not (List.exists (fun s -> condition s <> None) p.suffixes)))

(*****************************************************************************)
(* Rewriting: frames, RET, DIV and MOD (5l's noops; xix's Rewrite5) *)
(*****************************************************************************)

let mem ?(off = 0) b = A.Mem { base = A.R b; name = None; off = Int64.of_int off; index = None }
let imm n = A.Imm (Int64.of_int n)
let prog_like (p : prog) op suffixes args = { p with op; suffixes; args; target = None; frame = 0; leaf = false }
let become (p : prog) op suffixes args = p.op <- op; p.suffixes <- suffixes; p.args <- args; p.target <- None

let division (p : prog) = match p.op with Ins (Div _ | Mod _) -> true | _ -> false

(* the names a program needs besides its own: arm divides by calls *)
let needs (progs : prog list) =
  if List.exists division progs then [ "_div"; "_divu"; "_mod"; "_modu" ] else []

let rewrite (t : op Link.t) =
  let texts = Hashtbl.create 64 in
  let cur = ref None in
  List.iter (fun (p : prog) ->
    match p.op with
    | Func ->
        p.leaf <- true;
        cur := Some p;
        (match p.args with A.Mem { name = Some n; _ } :: _ -> Hashtbl.replace texts (sym_of t p.version n).name p | _ -> ())
    | _ when p.op = Bl || division p -> Option.iter (fun c -> c.leaf <- false) !cur
    | _ -> ()) t.progs;
  let autosize = ref 0 and leaf = ref true in
  t.progs <- List.concat_map (fun (p : prog) ->
    match p.op with
    | Func ->
        if p.frame <= 0 && p.leaf then p.frame <- -4;
        autosize := p.frame + 4;
        if !autosize = 0 && not p.leaf then p.leaf <- true;
        leaf := p.leaf;
        if p.leaf && !autosize = 0 then [ p ]
        else [ p; prog_like p (Ins (Mov W32)) [ "W" ] [ A.Reg reg_link; mem reg_sp ~off:(- !autosize) ] ]
    (* in place, as the branches to it stay *)
    | Ins Ret ->
        let conds = List.filter (fun s -> condition s <> None) p.suffixes in
        if !leaf && !autosize = 0 then become p B conds [ mem reg_link ]
        else become p (Ins (Mov W32)) (conds @ [ "P" ]) [ mem reg_sp ~off:!autosize; A.Reg reg_pc ];
        [ p ]
    | Ins (Div _ | Mod _ as op) -> (
        match p.args with
        | [ A.Reg a; A.Reg _; A.Reg d ] | [ A.Reg a; A.Reg d ] ->
            (* the dividend: the middle register, else the destination *)
            let b' = match p.args with [ _; A.Reg m; _ ] -> m | _ -> d in
            let name = "_" ^ String.lowercase_ascii (show op) in
            let callee = match Hashtbl.find_opt texts name with
              | Some q -> q | None -> let f, l = p.where in error "%s:%d: no %s to call" f l name in
            let bl = prog_like p Bl [] [ A.Target 0 ] in
            bl.target <- Some callee;
            let rest =
              [ prog_like p (Ins (Mov W32)) [] [ A.Reg a; mem reg_sp ~off:4 ];
              prog_like p (Ins (Mov W32)) [] [ A.Reg b'; A.Reg reg_tmp ];
              bl;
              prog_like p (Ins (Mov W32)) [] [ A.Reg reg_tmp; A.Reg d ];
              prog_like p (Ins (Alu Add)) [] [ imm 8; A.Reg reg_sp ] ] in
            become p (Ins (Alu Sub)) [] [ imm 8; A.Reg reg_sp ];
            p :: rest
        | _ -> [ p ])
    (* 5l's ldobj: an ADD or SUB of a negative constant is the other *)
    | Ins (Alu (Add | Sub as a)) -> (
        match p.args with
        | A.Imm n :: rest when sx32 n < 0 ->
            p.op <- Ins (Alu (if a = Add then Sub else Add));
            p.args <- imm (- (sx32 n)) :: rest;
            [ p ]
        | _ -> [ p ])
    | _ -> [ p ]) t.progs

(*****************************************************************************)
(* Encoding (5l's asmout and its helpers, codegen.c; xix's Codegen5) *)
(*****************************************************************************)

(* the data-processing opcodes, bits 21-24 (5l's oprrr) *)
let oprrr (op : op) sc =
  let o = ((sc land 15) lsl 28) lor (if sc land c_sbit <> 0 then 1 lsl 20 else 0) in
  let d = function F -> 0 | D -> 1 lsl 7 in
  o lor (match op with
    | Alu a -> (match a with And -> 0x0 | Eor -> 0x1 | Sub -> 0x2 | Rsb -> 0x3 | Add -> 0x4 | Adc -> 0x5 | Sbc -> 0x6 | Rsc -> 0x7
                           | Orr -> 0xc | Bic -> 0xe) lsl 21
    | Test t -> ((match t with Tst -> 0x8 | Teq -> 0x9 | Cmp -> 0xa | Cmn -> 0xb) lsl 21) lor (1 lsl 20)
    | Mov W32 -> 0xd lsl 21
    | Mvn -> 0xf lsl 21
    | Shift k -> (0xd lsl 21) lor (Link.shift_bits k lsl 5)
    | Mul _ -> 0x9 lsl 4
    | Swi -> 0xf lsl 24
    | Mula -> (0x1 lsl 21) lor (0x9 lsl 4)
    | Mull (un, acc) -> ((0x4 lor (if un then 0 else 2) lor (if acc then 1 else 0)) lsl 21) lor (0x9 lsl 4)
    | Farith (f, pr) ->
        (0xe lsl 24) lor ((match f with Fadd -> 0 | Fmul -> 1 | Fsub -> 2 | Fdiv -> 4) lsl 20) lor (1 lsl 8) lor d pr
    | Fcmp _ -> (0xe lsl 24) lor (0x9 lsl 20) lor (0xf lsl 12) lor (1 lsl 8) lor (1 lsl 4)
    | Fmov pr | Fcvt pr -> (0xe lsl 24) lor (1 lsl 15) lor (1 lsl 8) lor d pr
    | Itof pr -> (0xe lsl 24) lor (1 lsl 8) lor (1 lsl 4) lor d pr
    | Ftoi pr -> (0xe lsl 24) lor (1 lsl 20) lor (1 lsl 8) lor (1 lsl 4) lor d pr
    | Mov (B8 | B8u | H16 | H16u) | Div _ | Mod _ | Movm | Case | Word | Ret -> error "bad data-processing op %s" (show op))

(* branches (5l's opbra): B's condition is always, BL's its suffix's *)
let opbra (op : op Link.op) sc =
  match op with
  | Bl -> ((sc land 15) lsl 28) lor (0x5 lsl 25) lor (1 lsl 24)
  | B -> (always lsl 28) lor (0x5 lsl 25)
  | Bcond c -> (cond_bits c lsl 28) lor (0x5 lsl 25)
  | Func | Nop | Bcase | Ins _ -> error "bad branch %s" (show_op show op)

(* loads and stores of words and bytes (5l's olr, osr, olrr, osrr) *)
let olr ~byte sc v b rt =
  let o = ((sc land 15) lsl 28) lor (if sc land c_pbit = 0 then 1 lsl 24 else 0) lor (if sc land c_wbit <> 0 then 1 lsl 21 else 0)
          lor (1 lsl 26) lor (1 lsl 20) in
  let o, v = if v >= 0 then o lor (1 lsl 23), v else o, - v in
  if v >= 1 lsl 12 then error "literal span too large: %d" v;
  o lor (if byte then 1 lsl 22 else 0) lor (b lsl 16) lor (rt lsl 12) lor v

let osr ~byte sc r v b = olr ~byte sc v b r lxor (1 lsl 20)
let olrr ~byte sc i b r = olr ~byte sc i b r lor (1 lsl 25)
let osrr ~byte sc r i b = olrr ~byte sc i b r lxor (1 lsl 20)

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
let ofsr pr r v b sc =
  let o = ((sc land 15) lsl 28) lor (if sc land c_pbit = 0 then 1 lsl 24 else 0) lor (if sc land c_wbit <> 0 then 1 lsl 21 else 0)
          lor (6 lsl 25) lor (1 lsl 24) lor (1 lsl 23) in
  let o, v = if v < 0 then o lxor (1 lsl 23), - v else o, v in
  if v land 3 <> 0 then error "odd offset for floating point op: %d" v;
  if v >= 1 lsl 10 then error "literal span too large: %d" v;
  o lor ((v lsr 2) land 0xff) lor (b lsl 16) lor (r lsl 12) lor (1 lsl 8) lor (if pr = D then 1 lsl 15 else 0)

let fregof = function Some (A.FReg r) -> r | _ -> -1

let regof = function Some (A.Reg r) -> r | Some (A.Mem { base = R r; _ }) -> r | Some (A.Addr { base = R r; _ }) -> r | _ -> -1

(* a shift operand as 5a encodes it: reg | amount or reg<<8|1<<4 | kind<<5 *)
let shift_bits (s : A.shift) =
  s.reg lor (Link.shift_bits s.kind lsl 5) lor (match s.by with `Imm n -> (n land 31) lsl 7 | `Reg r -> (r lsl 8) lor (1 lsl 4))

let shift_of = function Some (A.Shifted s) -> s | Some (A.Mem { index = Some s; _ }) -> s | _ -> error "not a shift"

(*****************************************************************************)
(* Choosing an encoding (5l's optab, oplook and asmout) *)
(*****************************************************************************)

(* an instruction's encoding: its size, the operand it puts in the
 * literal pool, whether the pool may follow it (after a B), and its
 * words, made once the pcs are known *)
(* old: 5l's design, a table of rules (opcode, three operand classes, a
 * case number, a size, flags) sorted so that the first that fits is the
 * one wanted, ARMv4's before the others, a cached index into it in each
 * prog, and asmout's switch on the case numbers, away from what chose
 * them. Here one match on the opcode tries the forms in the table's
 * order, each next to its words; so written, its dead rules showed:
 * the ARMv4 rules take every load of a byte or half and every store of
 * a half, and cases 22, 23, 32 and 33 were never reached *)
type action = { size : int; pool : A.operand option; flush : bool; words : unit -> int list }

let select ctx (p : prog) : action =
  let v = view p in
  let sc = v.sc in
  let c1 = fst (aclass ctx p v.from) and c3 = fst (aclass ctx p v.to_) in
  let none = v.reg = None and fits a1 a3 = cmp a1 c1 && cmp a3 c3 in
  let illegal () = let f, l = p.where in error "%s:%d: illegal combination: %s" f l (Link.show show p) in
  let off a = snd (aclass ctx p a) in
  let rt = regof v.to_ and rf = regof v.from in
  let is_mov = v.op = Ins (Mov W32) || v.op = Ins Mvn in
  let mid rt = if is_mov then 0 else match v.reg with Some r -> r | None -> rt in
  (* a memory operand's base: R12 and the frame's register for a name
   * and an auto *)
  let base a = match a with
    | Some (A.Mem { base = SB; _ } | A.Addr { base = SB; _ }) -> reg_sb
    | _ -> (match regof a with -1 -> reg_sp | r -> r) in
  (* a constant from the pool, or an MVN of its complement (5l's omvl) *)
  let omvl a dr =
    match p.target with
    | Some w -> olr ~byte:false (sc land 15) (w.pc - p.pc - 8) reg_pc dr
    | None -> (
        match immrot (lnot (off a)) with
        | Some i -> oprrr Mvn (sc land 15) lor (dr lsl 12) lor i
        | None -> error "missing literal")
  in
  let target_pc () = match p.target with Some q -> q.pc | None -> p.pc in
  let act ?pool ?(flush = false) size words = { size; pool; flush; words } in
  let one w = act 4 (fun () -> [ w () ]) in
  (* data processing: R, a rotated constant, R<<n, or a constant from
   * the pool (or the MVN of its complement) into REGTMP (5l's cases 1,
   * 2, 3, 13) *)
  let alu m d =
    let rt' = if v.to_ = None then 0 else rt in
    if fits REG d then one (fun () -> oprrr m sc lor (mid rt' lsl 16) lor (rt' lsl 12) lor rf)
    else if fits RCON d then one (fun () -> oprrr m sc lor Option.get (immrot (off v.from)) lor (mid rt' lsl 16) lor (rt' lsl 12))
    else if fits NCON d || fits LCON d then
      act 8 ?pool:(if c1 = NCON then None else v.from) (fun () ->
        [ omvl v.from reg_tmp; oprrr m sc lor (mid rt lsl 16) lor reg_tmp lor (if v.to_ <> None then rt lsl 12 else 0) ])
    else if fits SHIFT d then one (fun () -> oprrr m sc lor shift_bits (shift_of v.from) lor (mid rt' lsl 16) lor (rt' lsl 12))
    else illegal ()
  in
  (* loads and stores of words and bytes: a 12-bit offset, or one from
   * the pool into REGTMP (5l's cases 20, 21, 30, 31) *)
  let short = [ SEXT; SAUTO; SOREG ] and long = [ LEXT; LAUTO; LOREG ] in
  let fits_any cs c = List.exists (fun a -> cmp a c) cs in
  let word_access ?(load = true) ~byte () =
    if not none then None
    else if c1 = REG && fits_any short c3 then Some (one (fun () -> osr ~byte sc rf (off v.to_) (base v.to_)))
    else if c1 = REG && fits_any long c3 then
      Some (act 8 ?pool:v.to_ (fun () -> [ omvl v.to_ reg_tmp; osrr ~byte sc rf reg_tmp (base v.to_) ]))
    else if load && c3 = REG && fits_any short c1 then Some (one (fun () -> olr ~byte sc (off v.from) (base v.from) rt))
    else if load && c3 = REG && fits_any long c1 then
      Some (act 8 ?pool:v.from (fun () -> [ omvl v.from reg_tmp; olrr ~byte sc reg_tmp (base v.from) rt ]))
    else None
  in
  (* ARMv4's loads of halves and signed bytes, and stores of halves: an
   * 8-bit offset, or one from the pool (5l's cases 70 to 73) *)
  let half_access (w : width) ~store =
    let sign o = match w with B8 -> o lxor ((1 lsl 5) lor (1 lsl 6)) | H16 -> o lxor (1 lsl 6) | B8u | H16u | W32 -> o in
    let hshort = [ HEXT; HAUTO; HOREG ] in
    if not none then None
    else if store && c1 = REG && fits_any hshort c3 then Some (one (fun () -> oshr rf (off v.to_) (base v.to_) sc))
    else if store && c1 = REG && fits_any long c3 then
      Some (act 8 ?pool:v.to_ (fun () -> [ omvl v.to_ reg_tmp; oshrr rf reg_tmp (base v.to_) sc ]))
    else if c3 = REG && fits_any hshort c1 then Some (one (fun () -> sign (olhr (off v.from) (base v.from) rt sc)))
    else if c3 = REG && fits_any long c1 then
      Some (act 8 ?pool:v.from (fun () -> [ omvl v.from reg_tmp; sign (olhrr reg_tmp (base v.from) rt sc) ]))
    else None
  in
  (* a byte or half between registers: shifted up, then down (5l's case 14) *)
  let extend (w : width) =
    act 8 (fun () ->
      let n = match w with B8 | B8u -> 24 | H16 | H16u | W32 -> 16 in
      [ oprrr (Shift Lsl) sc lor (rt lsl 12) lor (n lsl 7) lor rf;
        oprrr (Shift (match w with B8u | H16u -> Lsr | B8 | H16 | W32 -> Asr)) sc lor (rt lsl 12) lor (n lsl 7) lor rt ])
  in
  (* a load by a shifted register index, and a store (5l's cases 59, 61) *)
  let shifted_load m ~byte =
    one (fun () ->
      match v.from with
      | Some (A.Mem { base = R b; index = Some s; _ }) -> olrr ~byte sc (shift_bits s) b rt
      | _ -> oprrr m sc lor shift_bits (shift_of v.from) lor (rt lsl 12))
  in
  let shifted_store ~byte =
    one (fun () ->
      match v.to_ with
      | Some (A.Mem { base = R b; index = Some s; _ }) -> osrr ~byte sc rf (shift_bits s) b
      | _ -> error "MOV to shifter operand")
  in
  let or_else a f = match a with Some a -> a | None -> f () in
  (* FPA's loads and stores (5l's cases 50 to 53) *)
  let float_access pr =
    let fshort = [ FEXT; FAUTO; FOREG ] in
    if not none then None
    else if c1 = FREG && fits_any fshort c3 then Some (one (fun () -> ofsr pr (fregof v.from) (off v.to_) (base v.to_) sc))
    else if c1 = FREG && fits_any long c3 then
      Some (act 12 ?pool:v.to_ (fun () ->
        [ omvl v.to_ reg_tmp; oprrr (Alu Add) sc lor (reg_tmp lsl 12) lor (reg_tmp lsl 16) lor base v.to_;
          ofsr pr (fregof v.from) 0 reg_tmp sc ]))
    else if c3 = FREG && fits_any fshort c1 then Some (one (fun () -> ofsr pr (fregof v.to_) (off v.from) (base v.from) sc lor (1 lsl 20)))
    else if c3 = FREG && fits_any long c1 then
      Some (act 12 ?pool:v.from (fun () ->
        [ omvl v.from reg_tmp; oprrr (Alu Add) sc lor (reg_tmp lsl 12) lor (reg_tmp lsl 16) lor base v.from;
          ofsr pr (fregof v.to_) 0 reg_tmp sc lor (1 lsl 20) ]))
    else None
  in
  (* FPA's data processing: F or one of its eight constants (5l's case 54) *)
  let farith m =
    one (fun () ->
      let o1 = oprrr m sc in
      let rf = match v.from with
        | Some (A.Fimm x) -> (match chip_float x with Some i -> i lor 8 | None -> error "invalid floating-point immediate")
        | a -> fregof a in
      let rt = fregof v.to_ in
      let r = if v.to_ = None then Option.get v.reg else if o1 land (1 lsl 15) <> 0 then 0 else Option.value v.reg ~default:rt in
      let rt = if v.to_ = None then 0 else rt in
      o1 lor rf lor (r lsl 16) lor (rt lsl 12))
  in
  match v.op with
  | Ins (Alu _ as m) -> alu m REG
  | Ins (Test _ as m) -> if none then illegal () else alu m NONE
  | Ins (Mvn as m) -> if none then alu m REG else illegal ()
  | Ins (Mov W32) ->
      or_else (word_access ~byte:false ()) (fun () ->
        if not none then illegal ()
        else if fits REG REG then one (fun () -> oprrr (Mov W32) sc lor (rt lsl 12) lor rf)
        else if fits REG SHIFT then shifted_store ~byte:false
        else if fits RCON REG then one (fun () -> oprrr (Mov W32) sc lor Option.get (immrot (off v.from)) lor (rt lsl 12))
        else if fits NCON REG || fits LCON REG then act 4 ?pool:(if c1 = NCON then None else v.from) (fun () -> [ omvl v.from rt ])
        else if fits RECON REG || fits RACON REG then
          one (fun () -> oprrr (Alu Add) sc lor (base v.from lsl 16) lor (rt lsl 12) lor Option.get (immrot (off v.from)))
        else if fits LACON REG then
          act 8 ?pool:v.from (fun () -> [ omvl v.from reg_tmp; oprrr (Alu Add) sc lor (base v.from lsl 16) lor (rt lsl 12) lor reg_tmp ])
        else if fits SHIFT REG then shifted_load (Mov W32) ~byte:false
        else illegal ())
  | Ins (Mov B8u) ->
      or_else (word_access ~byte:true ()) (fun () ->
        if not none then illegal ()
        else if fits REG REG then one (fun () -> oprrr (Alu And) sc lor Option.get (immrot 0xff) lor (rf lsl 16) lor (rt lsl 12))
        else if fits REG SHIFT then shifted_store ~byte:true
        else if fits SHIFT REG then shifted_load (Mov B8u) ~byte:true
        else illegal ())
  | Ins (Mov B8) ->
      or_else (half_access B8 ~store:false) (fun () ->
        or_else (word_access ~load:false ~byte:true ()) (fun () ->
          if not none then illegal ()
          else if fits REG REG then extend B8
          else if fits REG SHIFT then shifted_store ~byte:true
          else if fits SHIFT REG then
            one (fun () ->
              match v.from with
              | Some (A.Mem { base = R b; index = Some s; _ }) -> olhrr (shift_bits s) b rt sc lxor ((1 lsl 5) lor (1 lsl 6))
              | _ -> error "byte MOV from shifter operand")
          else illegal ()))
  | Ins (Mov (H16 | H16u as w)) ->
      or_else (half_access w ~store:true) (fun () -> if none && fits REG REG then extend w else illegal ())
  | Ins (Shift _ as m) ->
      let r = match v.reg with Some r -> r | None -> rt in
      if fits REG REG then one (fun () -> oprrr m sc lor (rt lsl 12) lor (rf lsl 8) lor (1 lsl 4) lor r)
      else if fits RCON REG then one (fun () -> oprrr m sc lor (rt lsl 12) lor ((off v.from land 31) lsl 7) lor r)
      else illegal ()
  | Ins (Mul _ as m) when fits REG REG ->
      one (fun () ->
        let r = match v.reg with Some r -> r | None -> rt in
        let r, rf = if rt = r then rf, rt else r, rf in
        oprrr m sc lor (rt lsl 16) lor (rf lsl 8) lor r)
  (* claude: 5l's case 16, a division left for the rewriting's calls *)
  | Ins (Div _ | Mod _) when fits REG REG -> one (fun () -> 0xf lsl 28)
  | Ins (Mula | Mull _ as m) when not none && fits REG REGREG ->
      one (fun () ->
        let rt, rt2 = match v.to_ with Some (A.Pair (a, b)) -> a, b | _ -> 0, 0 in
        oprrr m sc lor (rf lsl 8) lor Option.get v.reg lor (rt lsl 16) lor (rt2 lsl 12))
  | Ins Swi when none && c1 = NONE && (c3 = NONE || cmp LCON c3 || cmp LOREG c3) ->
      one (fun () -> oprrr Swi sc lor (if v.to_ <> None then off v.to_ land 0xffffff else 0))
  | Ins Movm when none && (fits LCON SOREG || fits SOREG LCON) ->
      one (fun () ->
        let store = cmp LCON c1 in
        let mask = if store then off v.from else off v.to_ in
        let b = if store then regof v.to_ else rf in
        if (if store then off v.to_ else off v.from) <> 0 then error "offset must be zero in MOVM";
        (0x4 lsl 25) lor (if store then 0 else 1 lsl 20) lor (mask land 0xffff) lor (b lsl 16)
        lor ((sc land 15) lsl 28) lor (if sc land c_pbit <> 0 then 1 lsl 24 else 0)
        lor (if sc land c_ubit <> 0 then 1 lsl 23 else 0) lor (if sc land c_sbit <> 0 then 1 lsl 22 else 0)
        lor (if sc land c_wbit <> 0 then 1 lsl 21 else 0))
  (* branches; B's pool may follow it *)
  | (B | Bl | Bcond _) when none && fits NONE BRANCH ->
      act 4 ~flush:(v.op = B) (fun () -> [ opbra v.op sc lor (((target_pc () - p.pc - 8) asr 2) land 0xffffff) ])
  | B when none && fits NONE ROREG ->
      act 4 ~flush:true (fun () -> [ oprrr (Alu Add) sc lor Option.get (immrot (off v.to_)) lor (regof v.to_ lsl 16) lor (reg_pc lsl 12) ])
  | Bl when none && fits NONE ROREG ->
      act 8 (fun () ->
        [ oprrr (Alu Add) sc lor (reg_pc lsl 16) lor (reg_link lsl 12) lor Option.get (immrot 0);
          oprrr (Alu Add) sc lor (regof v.to_ lsl 16) lor (reg_pc lsl 12) lor Option.get (immrot (off v.to_)) ])
  (* a switch: the PC loaded from the table of addresses that follows *)
  | Ins Case when none && fits REG NONE -> one (fun () -> olrr ~byte:false sc rf reg_pc reg_pc lor (2 lsl 7))
  | Bcase when none && fits NONE BRANCH -> one target_pc
  | Ins Word when fits NONE LCON || fits NONE LEXT -> one (fun () -> off v.to_ land 0xffffffff)
  (* FPA's floating point *)
  | Ins (Fmov pr) ->
      or_else (float_access pr) (fun () -> if none && (fits FCON FREG || fits FREG FREG) then farith (Fmov pr) else illegal ())
  | Ins (Farith _ | Fcvt _ as m) when fits FREG FREG || fits FCON FREG -> farith m
  | Ins (Fcmp _ as m) when not none && (fits FREG NONE || fits FCON NONE) -> farith m
  | Ins (Itof _ | Ftoi _ as m) when none && (fits FREG REG || fits REG FREG) ->
      one (fun () ->
        let o1 = oprrr m sc in
        match v.from, v.to_ with
        | Some (A.Reg rf), Some (A.FReg rt) -> o1 lor (rf lsl 12) lor (rt lsl 16)
        | Some (A.FReg rf), Some (A.Reg rt) -> o1 lor rf lor (rt lsl 12)
        | _ -> error "bad float conversion")
  | Func | Nop | B | Bl | Bcond _ | Bcase
  | Ins (Mul _ | Div _ | Mod _ | Mula | Mull _ | Swi | Movm | Case | Word | Ret | Farith _ | Fcvt _ | Fcmp _ | Itof _ | Ftoi _) -> illegal ()

(*****************************************************************************)
(* Layout: pcs and literal pools (5l's dotext, addpool, flushpool,
 * checkpool; xix's Layout5) *)
(*****************************************************************************)

let layout (t : op Link.t) =
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
        let b = prog_like p B [] [ A.Target 0 ] in
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
      (* an offset made a constant: never the same record as an operand's
       * (which carries its class), so never shared with one *)
      | SROREG | LOREG | ROREG | FOREG | SOREG | FAUTO | SAUTO | LAUTO | LACON -> A.Imm (Int64.of_int v), -1
      (* the operand, as 5l's memcmp of it: a name<> is its object's *)
      | _ ->
          let a = Option.get a in
          a, (match a with A.Mem { name = Some { static = true; _ }; _ } | A.Addr { name = Some { static = true; _ }; _ } -> p.version | _ -> 0)
    in
    match List.assoc_opt key !pool with
    | Some w -> p.target <- Some w
    | None ->
        let w = prog_like p (Ins Word) [] [ fst key ] in
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
        if p.op = Func then begin
          ctx.autosize <- p.frame + 4;
          (match p.args with A.Mem { name = Some n; _ } :: _ -> (sym_of t p.version n).value <- !pc | _ -> ());
          go rest
        end
        else begin
          let a = select ctx p in
          pc := !pc + a.size;
          let v = view p in
          if a.pool <> None then add_pool p a.pool;
          let rest = if a.flush && v.sc land 15 = always then flush p rest false else rest in
          let rest =
            if v.op = Ins (Mov W32) && v.to_ = Some (A.Reg reg_pc) && v.sc land 15 = always then flush p rest false else rest
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


let encode (t : op Link.t) : Bytes.t =
  let ctx = { t; autosize = 0 } in
  let b = Bytes.make t.text_size '\000' in
  List.iter (fun (p : prog) ->
    if p.op = Func then ctx.autosize <- p.frame + 4
    else begin
      (* chosen again, now that the pcs are known: as layout chose it *)
      let a = select ctx p in
      let ws = a.words () in
      if 4 * List.length ws <> a.size then (let f, l = p.where in error "%s:%d: phase error: %s" f l (Link.show show p));
      List.iteri (fun i w -> Link.put32 b (p.pc - t.text_start + (4 * i)) w) ws
    end) t.progs;
  b
