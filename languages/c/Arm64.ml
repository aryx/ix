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

open Tree

(* what 7c generates itself, rather than com64.c's calls (7c's machcap.c) *)
let machcap (n : expr option) =
  match n with
  | None -> true
  | Some n -> (
      match n.e with
      | Binary ((Mul | Lmul), _, _) | Assign (Some (Mul | Lmul), _, _) -> typechlv (et n)
      | Binary ((Add | And | Or | Sub | Xor | Ashl | Lshr | Ashr), l, _) | Unary (Neg, l) -> typechlv (et l)
      | Unary ((Cast | Not | Postinc | Postdec | Preinc | Predec), _) | Cond _ | Binary ((Comma | Andand | Oror), _, _)
      | Assign (Some (Add | Sub | And | Or | Xor | Ashl | Ashr | Lshr), _, _) -> true
      | Binary (o, _, _) -> is_rel o
      | _ -> false)

let machine = {
  thechar = '7'; sz_ind = 8; maxalign = 8;
  typecmplx = typesu; typeword = typechlvp; typeswitch = typechlv;
  machcap;
}

(*****************************************************************************)
(* Moves (7c's txt.c gmove) *)
(*****************************************************************************)

module A = Ix_asm.Asm
open Emit

(* a word is MOVW, a vlong or pointer MOV *)
let width_op et = if ewidth et = 4 then (if typeu et then "MOVWU" else "MOVW") else "MOV"

let load_op = function
  | Tint -> "MOVW" | Tuint -> "MOVWU" | Tfloat -> "FMOVS" | Tdouble -> "FMOVD" | Tchar -> "MOVB" | Tuchar -> "MOVBU"
  | Tshort -> "MOVH" | Tushort -> "MOVHU" | t -> width_op t

let store_op = function
  | Tint -> "MOVW" | Tuint -> "MOVWU" | Tfloat -> "FMOVS" | Tdouble -> "FMOVD" | Tchar -> "MOVB" | Tuchar -> "MOVBU"
  | Tshort -> "MOVH" | Tushort -> "MOVHU" | t -> if ewidth t = 4 then "MOVW" else "MOV"

let rec gmove (f : expr) (t : expr) =
  let ft = et f and tt = et t in
  if is_mem f then begin
    let nod = regalloc f (Some t) in
    ins (load_op ft) f nod;
    gmove nod t;
    regfree nod
  end
  else if is_mem t then begin
    (* a 0 stored from the zero register *)
    if not (typefd ft) && Check.vconst f = 0 then ins (store_op tt) f t
    else begin
      let nod = if ft = tt then regalloc t (Some f) else regalloc t None in
      gmove f nod;
      ins (store_op tt) nod t;
      regfree nod
    end
  end
  else begin
    let bad () = ignore (diag None "bad opcode in gmove %s -> %s" (show_type (Some f.t)) (show_type (Some t.t))) in
    let mv a =
      if (a = "MOV" || ((a = "MOVW" || a = "MOVWU") && ewidth ft = ewidth tt) || a = "FMOVS" || a = "FMOVD") && samaddr f t then ()
      else ins a f t
    in
    let now a = ins a f t in
    let via ld cvt = let nod = regalloc f None in ins ld f nod; ins cvt nod t; regfree nod in
    let single = ft = Tfloat in
    match ft with
    | Tdouble | Tfloat -> (
        match tt with
        | Tdouble -> mv (if single then "FCVTSD" else "FMOVD")
        | Tfloat -> mv (if single then "FMOVS" else "FCVTDS")
        | Tchar | Tshort | Tint | Tlong -> mv (if single then "FCVTZSSW" else "FCVTZSDW")
        | Tuchar | Tushort | Tuint | Tulong -> mv (if single then "FCVTZUSW" else "FCVTZUDW")
        | Tvlong -> mv (if single then "FCVTZSS" else "FCVTZSD")
        | Tuvlong | Tind -> mv (if single then "FCVTZUS" else "FCVTZUD")
        | _ -> bad ())
    | Tuint | Tulong | Tint | Tlong -> (
        let u = ft = Tuint || ft = Tulong in
        match tt with
        | Tdouble -> now (if u then "UCVTFWD" else "SCVTFWD")
        | Tfloat -> now (if u then "UCVTFWS" else "SCVTFWS")
        | Tint | Tuint | Tlong | Tulong | Tshort | Tushort | Tchar | Tuchar -> mv (if typeu tt then "MOVWU" else "MOVW")
        | Tvlong | Tuvlong | Tind -> mv (if typeu ft then "MOVWU" else "SXTW")
        | _ -> bad ())
    | Tvlong | Tuvlong | Tind -> (
        match tt with
        | Tdouble -> now (if ft = Tvlong then "SCVTFD" else "UCVTFD")
        | Tfloat -> now (if ft = Tvlong then "SCVTFS" else "UCVTFS")
        | Tint | Tuint | Tlong | Tulong | Tshort | Tushort | Tchar | Tuchar -> mv "MOVWU"
        | Tvlong | Tuvlong | Tind -> mv "MOV"
        | _ -> bad ())
    | Tshort | Tushort | Tchar | Tuchar -> (
        let ld = load_op ft and u = typeu ft in
        match tt with
        | Tdouble -> via ld (if u then "UCVTFWD" else "SCVTFWD")
        | Tfloat -> via ld (if u then "UCVTFWS" else "SCVTFWS")
        | Tint | Tuint | Tlong | Tulong | Tvlong | Tuvlong | Tind -> mv ld
        | Tshort | Tushort when ft = Tchar || ft = Tuchar -> mv ld
        | Tshort | Tushort | Tchar | Tuchar -> mv "MOV"
        | _ -> bad ())
    | _ -> bad ()
  end

let gmover (f : expr) (t : expr) =
  let ft = et f and tt = et t in
  let a = match tt with Tshort -> Some "MOVH" | Tushort -> Some "MOVHU" | Tchar -> Some "MOVB" | Tuchar -> Some "MOVBU" | Tint -> Some "MOVW" | Tuint -> Some "MOVWU" | _ -> None in
  match a with
  | Some a when typechlp ft && typechlp tt && ewidth ft >= ewidth tt -> ins a f t
  | _ -> gmove f t

(*****************************************************************************)
(* Operators (7c's gopcode): W for 32 bits *)
(*****************************************************************************)

let isv = function Tvlong | Tuvlong | Tind -> true | _ -> false

let gopcode (o : gop) tr (f1 : expr option) (f2 : expr option) (t : expr option) =
  (* a constant's width is its destination's *)
  let et =
    match f1 with
    | Some f1 when f1.t != untyped ->
        if is_const f1 then
          (match t, f2 with
           | Some tt, _ -> et tt
           | _, Some t2 when ewidth (et t2) > ewidth (et f1) -> et t2
           | _ -> et f1)
        else et f1
    | _ -> Tlong
  in
  let w32 a64 = if isv et then a64 else a64 ^ "W" in
  let fl w d a = if et = Tfloat then w else if et = Tdouble then d else a in
  let emit a =
    let q = nextpc () in
    q.as_ <- a;
    q.from <- naddr_opt f1;
    (match Option.map naddr f2 with Some (A.Reg r | A.FReg r) -> q.reg <- Some r | _ -> ());
    q.to_ <- naddr_opt t
  in
  match o with
  | Op o when is_rel o ->
      let fd = typefd et in
      let small v = if isv et then v = Int64.min_int else mask32 v = 0x80000000L in
      gcmp (fl "FCMPS" "FCMPD" (w32 "CMP")) ~fd ~small f1 f2;
      grel o ~fd ~tr
  | Op o ->
      emit
        (match o with
         | Add -> fl "FADDS" "FADDD" (w32 "ADD")
         | Sub -> fl "FSUBS" "FSUBD" (w32 "SUB")
         | Or -> w32 "ORR" | And -> w32 "AND" | Xor -> w32 "EOR"
         | Lshr -> w32 "LSR" | Ashr -> w32 "ASR" | Ashl -> w32 "LSL"
         | Mul -> fl "FMULS" "FMULD" (w32 "MUL")
         | Div -> fl "FDIVS" "FDIVD" (w32 "SDIV")
         | Mod -> w32 "REM"
         | Lmul -> if isv et then "MUL" else "UMULL"
         | Lmod -> w32 "UREM"
         | Ldiv -> w32 "UDIV"
         | o -> diag None "bad in gopcode %s" (binop_name o))
  | Gcall -> emit "BL"
  | Gcom -> emit (w32 "MVN")
  | Gneg -> emit (w32 "NEG")
  | Gcase -> emit "CASE"

(*****************************************************************************)
(* Block copies and switches (7c's sugen, layout, swit) *)
(*****************************************************************************)

(* c words from f to t, two registers in turn (7c's layout); cn, the
 * loop's count, set on the way; f and t, past the words *)
let rec layout (f : expr) (t : expr) c cv (cn : expr option) =
  if c > 3 then (let f, t = layout f t 2 0 None in layout f t (c - 2) cv cn)
  else begin
    let t1 = regalloc (regnode ()) None and t2 = regalloc (regnode ()) None in
    let move = Gen.gmove in
    let f = ref f and t = ref t in
    let step x = x := plus !x 4 in
    if c > 0 then (move !f t1; step f);
    Option.iter (fun cn -> move (nodconst (Int64.of_int cv)) cn) cn;
    if c > 1 then (move !f t2; step f);
    if c > 0 then (move t1 !t; step t);
    if c > 2 then (move !f t1; step f);
    if c > 1 then (move t2 !t; step t);
    if c > 2 then (move t1 !t; step t);
    regfree t1;
    regfree t2;
    !f, !t
  end

(* the bytes past the words, then the words unrolled, or in a loop *)
let sucopy (n : expr) (nn : expr) w =
  let as_long (x : expr) = Gen.reglcgen { x with t = ty Tlong } None in
  let nod1, nod2 = if n.complex > nn.complex then (let a = as_long n in let b = as_long nn in a, b) else (let b = as_long nn in let a = as_long n in a, b) in
  let m = w mod 4 in
  let f, t =
    if m = 0 then nod1, nod2
    else begin
      let nod3 = regalloc (regnode ()) None in
      for i = w - m to w - 1 do
        ins "MOVB" (plus nod1 i) nod3;
        ins "MOVB" nod3 (plus nod2 i)
      done;
      regfree nod3;
      (* claude: the words from m on, as 7c's offsets end up *)
      plus nod1 m, plus nod2 m
    end
  in
  let w = w / 4 in
  if w <= 5 then ignore (layout f t w 0 None)
  else begin
    (* unrolled 3 to 5 times, 2 for a small one: the least code *)
    let c = ref 0 and best = ref 100 in
    for i = (if w <= 15 then 2 else 3) to 5 do
      if i + w mod i <= !best then (c := i; best := i + w mod i)
    done;
    let c = !c in
    let nod3 = regalloc (regnode ()) None in
    let f, t = layout f t (w mod c) (w / c) (Some nod3) in
    let pc1 = !pc in
    ignore (layout f t c 0 None);
    Gen.gopcode (Op Sub) (Some (nodconst 1L)) None (Some nod3);
    let bump (x : expr) = Gen.gopcode (Op Add) (Some (nodconst (Int64.of_int (c * 4)))) None (Some { x with e = Reg (reg_of x); t = ty Tind }) in
    bump nod1;
    bump nod2;
    Gen.gopcode (Op Gt) (Some (nodconst 0L)) (Some nod3) None;
    patch (p ()) pc1;
    regfree nod3
  end;
  regfree nod1;
  regfree nod2

(* a switch's table: to the default if above the range, then CASE *)
let table (n : expr) tn range def = Gen.compare Hi range n; patch (p ()) def; Gen.gopcode Gcase (Some n) None (Some tn)

let backend = {
  arch = A.Arm64; nreg = 32; nfreg = 32; regret = 0; fregret = 0; regsp = 31;
  (* the linker's temporary R17, SB R28, SP (and ZR) R31; R26 and R27 for extern registers *)
  reserved = [ 17; 28; 31; 27; 26 ]; regtmp = 17; word = 8; float_from_last = true;
  ret = "RETURN"; offset32 = false; zero_reg = Some 31;
  gmove; gmover; gopcode;
}

(* an offset a load or store encodes: scaled by its size, 12 bits up,
 * or 9 bits signed (7c's usableoffset) *)
let fits (n : expr) o =
  let s = min 16 n.t.width in
  s > 0 && o mod s = 0 && o >= -256 && o < 4096 * s

let hooks = {
  Gen.sucopy; table; fits;
  neg = (fun f t -> Gen.gopcode Gneg (Some f) None (Some t)); mul32 = true;
  rsb = false; by_left = true; com64 = false; shifts = true; zero_arg = true; asop_load = true; indreg_ptr = true;
}
