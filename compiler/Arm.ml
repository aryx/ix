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

open Tree

(* vlongs are structures to 5c: returned through a pointer, and their
 * operators calls to _addv... (com64.c) *)
let machine = {
  thechar = '5'; sz_ind = 4; maxalign = 4;
  typecmplx = typesuv; typeword = typechlp; typeswitch = typechl;
  machcap = (fun _ -> false);
}

(*****************************************************************************)
(* Moves (txt.c's gmove) *)
(*****************************************************************************)

module A = Ix_asm.Asm
open Emit

let load_op = function
  | Tfloat -> "MOVF" | Tdouble -> "MOVD" | Tchar -> "MOVB" | Tuchar -> "MOVBU" | Tshort -> "MOVH" | Tushort -> "MOVHU"
  | _ -> "MOVW"

let store_op = function Tvlong -> "MOVD" | t -> load_op t

(* f to t: a load or a store through a register, or a conversion *)
let rec gmove (f : node) (t : node) =
  let ft = et f and tt = et t in
  if is_mem f then begin
    let nod = if typechlp ft && typeilp tt then regalloc t (Some t) else regalloc f (Some t) in
    ins (load_op ft) f nod;
    gmove nod t;
    regfree nod
  end
  else if is_mem t then begin
    let nod = if ft = tt then regalloc t (Some f) else regalloc t None in
    gmove f nod;
    ins (store_op tt) nod t;
    regfree nod
  end
  else begin
    (* through a register, extended as the source says *)
    let via ld cvt = let nod = regalloc f None in ins ld f nod; ins cvt nod t; regfree nod in
    let to_float () = if tt = Tfloat then "MOVWF" else "MOVWD" in
    let bad () = ignore (diag None "bad opcode in gmove %s -> %s" (show_type f.ntype) (show_type t.ntype)) in
    let mv a = if (a = "MOVW" || a = "MOVF" || a = "MOVD") && samaddr f t then () else ins a f t in
    match ft with
    | Tdouble | Tvlong | Tfloat -> (
        match tt with
        | Tdouble | Tvlong -> mv (if ft = Tfloat then "MOVFD" else "MOVD")
        | Tfloat -> mv (if ft = Tfloat then "MOVF" else "MOVDF")
        | Tint | Tuint | Tlong | Tulong | Tind | Tshort | Tushort | Tchar | Tuchar -> mv (if ft = Tfloat then "MOVFW" else "MOVDW")
        | _ -> bad ())
    | Tuint | Tulong when tt = Tfloat || tt = Tdouble ->
        (* the top bit apart: vfp's conversion is signed *)
        let nod = regalloc f None in
        let nod1 = regalloc f None in
        ins "MOVW" f nod;
        ins "MOVW" nod nod1;
        ins "AND" (nodconst 0x80000000L) nod1;
        ins "EOR" nod1 nod;
        ins (to_float ()) nod t;
        let q = gins "CMP" (Some (nodconst 0L)) None in
        raddr (Some nod1) q;
        let p1 = gins "BEQ" None None in
        regfree nod;
        regfree nod1;
        let nod = regalloc t None in
        if tt = Tfloat then (ins "MOVF" (nodfconst 2147483648.) nod; ins "ADDF" nod t)
        else (ins "MOVD" (nodfconst 2147483648.) nod; ins "ADDD" nod t);
        regfree nod;
        patch p1 !pc
    | Tint | Tlong | Tind | Tuint | Tulong -> (
        match tt with
        | Tdouble -> ins "MOVWD" f t
        | Tfloat -> ins "MOVWF" f t
        | Tint | Tuint | Tlong | Tulong | Tind | Tshort | Tushort | Tchar | Tuchar -> mv "MOVW"
        | _ -> bad ())
    | Tshort | Tushort | Tchar | Tuchar -> (
        let ld = load_op ft in
        match tt with
        | Tdouble | Tfloat -> via ld (to_float ())
        | Tint | Tuint | Tlong | Tulong | Tind -> mv ld
        | Tshort | Tushort when ft = Tchar || ft = Tuchar -> mv ld
        | Tshort | Tushort | Tchar | Tuchar -> mv "MOVW"
        | _ -> bad ())
    | _ -> bad ()
  end

(* a narrowing move within registers, in a comparison (txt.c's gmover) *)
let gmover (f : node) (t : node) =
  let ft = et f and tt = et t in
  if typechlp ft && typechlp tt && ewidth ft >= ewidth tt && List.mem tt [ Tshort; Tushort; Tchar; Tuchar ] then
    ins (load_op tt) f t
  else gmove f t

(*****************************************************************************)
(* Operators (txt.c's gopcode) *)
(*****************************************************************************)

let fl et i f d = if et = Tfloat then f else if et = Tdouble || et = Tvlong then d else i

(* tr: the branch is taken when true, and a NaN must not *)
let gopcode (o : op) tr (f1 : node option) (f2 : node option) (t : node option) =
  let et = match f1 with Some { ntype = Some ty; _ } -> ty.etype | _ -> Tlong in
  let emit a f1 f2 =
    let q = nextpc () in
    q.as_ <- a;
    q.from <- naddr_opt f1;
    (match Option.map naddr f2 with Some (A.Reg r | A.FReg r) -> q.reg <- Some r | _ -> ());
    q.to_ <- naddr_opt t
  in
  match o with
  | OAS -> gmove (Option.get f1) (Option.get t)
  | OSUB | OASSUB when (match f2 with Some { op = OCONST; _ } -> true | _ -> false) ->
      (* c - x: a reverse subtract *)
      emit (fl et "RSB" "SUBF" "SUBD") f2 f1
  | OEQ | ONE | OLT | OLE | OGE | OGT | OLO | OLS | OHS | OHI | OCASE ->
      let fd = typefd et in
      gcmp (fl et "CMP" "CMPF" "CMPD") ~fd ~small:(fun v -> v = -2147483648L) f1 f2;
      (* a switch's table: CASE.LS, then to the default *)
      if o = OCASE then (let q = nextpc () in q.as_ <- "CASE"; q.cond <- [ "LS" ]; q.from <- naddr_opt f2);
      grel o ~fd ~tr
  | _ ->
      let a =
        match o with
        | OASADD | OADD -> fl et "ADD" "ADDF" "ADDD"
        | OASSUB | OSUB -> fl et "SUB" "SUBF" "SUBD"
        | OASOR | OOR -> "ORR" | OASAND | OAND -> "AND" | OASXOR | OXOR -> "EOR"
        | OASLSHR | OLSHR -> "SRL" | OASASHR | OASHR -> "SRA" | OASASHL | OASHL -> "SLL"
        | OFUNC -> "BL"
        | OASMUL | OMUL -> fl et "MUL" "MULF" "MULD"
        | OASDIV | ODIV -> fl et "DIV" "DIVF" "DIVD"
        | OASMOD | OMOD -> "MOD"
        | OASLMUL | OLMUL -> "MULU" | OASLMOD | OLMOD -> "MODU" | OASLDIV | OLDIV -> "DIVU"
        | o -> diag None "bad in gopcode %s" (opname o)
      in
      emit a f1 f2

(*****************************************************************************)
(* Block copies and switches (cgen.c's sugen, swt.c's swit) *)
(*****************************************************************************)

(* MOVM's register list, as a mask constant *)
let gmovm (f : node) (t : node) w =
  let q = gins "MOVM" (Some f) (Some t) in
  let regs = function Some (A.Imm m) -> Some (A.Regs (List.filter (fun i -> Int64.logand m (Int64.shift_left 1L i) <> 0L) (List.init 16 Fun.id))) | o -> o in
  q.from <- regs q.from;
  q.to_ <- regs q.to_;
  q.cond <- (if w then [ "W"; "U" ] else [ "U" ])

(* w bytes from n to nn: by one or two words, by MOVMs of up to four,
 * or a loop of them *)
let sucopy (n : node) (nn : node) w =
  let w = w / 4 in
  (* the addresses, the harder first *)
  let addrs () =
    let small = w <= 2 in
    if n.complex > nn.complex then (let a = Gen.reglpcgen n small in a, Gen.reglpcgen nn small)
    else (let b = Gen.reglpcgen nn small in Gen.reglpcgen n small, b)
  in
  let nod1, nod2 = addrs () in
  if w <= 2 then begin
    let nod3 = regalloc (regnode ()) None in
    let nod4 = regalloc (regnode ()) None in
    let nod3, nod4 = if nod3.reg > nod4.reg then nod4, nod3 else nod3, nod4 in
    let nod0 = nodconst (Int64.of_int ((1 lsl nod3.reg) lor (1 lsl nod4.reg))) in
    if w = 2 && nod1.xoffset = 0 then gmovm nod1 nod0 false
    else (gmove nod1 nod3; if w = 2 then (nod1.xoffset <- nod1.xoffset + 4; gmove nod1 nod4));
    if w = 2 && nod2.xoffset = 0 then gmovm nod0 nod2 false
    else (gmove nod3 nod2; if w = 2 then (nod2.xoffset <- nod2.xoffset + 4; gmove nod4 nod2));
    List.iter regfree [ nod1; nod2; nod3; nod4 ]
  end
  else begin
    (* up to four registers, the lowest free, moved at once *)
    let rec take k = if k = 0 then [] else (let i = tmpreg () in !regs.(i) <- !regs.(i) + 1; i :: take (k - 1)) in
    let rl = take (min w 4) in
    let c = List.length rl in
    let movm rl wb = let m = nodconst (Int64.of_int (List.fold_left (fun m i -> m lor (1 lsl i)) 0 rl)) in gmovm nod1 m wb; gmovm m nod2 wb in
    let rest =
      if w < 3 * c then (let rec go w = if w > c then (movm rl true; go (w - c)) else w in go w)
      else begin
        let nod3 = regalloc (regnode ()) None in
        gmove (Gen.iconst (w / c)) nod3;
        let pc1 = !pc in
        movm rl true;
        Gen.op2 OSUB (nodconst 1L) nod3;
        Gen.compare OEQ (nodconst 0L) nod3;
        (p ()).as_ <- "BGT";
        patch (p ()) pc1;
        regfree nod3;
        w mod c
      end
    in
    (* the rest, with the highest registers of the list *)
    if rest > 0 then movm (List.filteri (fun i _ -> i >= c - rest) rl) false;
    List.iter (fun i -> !regs.(i) <- 0) rl;
    regfree nod1;
    regfree nod2
  end

(* a switch's table: CMP, then CASE.LS and BHI to the default *)
let table (n : node) _ range def = Gen.compare OCASE range n; patch (p ()) def

let backend = {
  arch = A.Arm; nreg = 16; nfreg = 8; regret = 0; fregret = 0; regsp = 13;
  (* the linker's temporary R11, SB R12, SP, LR, PC; R9 and R10 for extern registers *)
  reserved = [ 11; 12; 13; 14; 15; 10; 9 ]; regtmp = 11; word = 4; float_from_last = false;
  ret = "RET"; offset32 = true; zero_reg = None;
  gmove; gmover; gopcode;
}

let hooks = {
  Gen.sucopy; table;
  fits = (fun _ v -> v > -4096 && v < 4096);
  neg = (fun f t -> Gen.op3 OSUB f (nodconst 0L) t); mul32 = false;
  rsb = true; by_left = false; com64 = true; shifts = false; zero_arg = false; asop_load = false; indreg_ptr = false;
}
