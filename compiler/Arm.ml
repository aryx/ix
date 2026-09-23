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

(* the no-op casts: pointers are longs (5c's txt.c) *)
let ncast = table [
  Tchar, b Tchar lor b Tuchar; Tuchar, b Tchar lor b Tuchar;
  Tshort, b Tshort lor b Tushort; Tushort, b Tshort lor b Tushort;
  Tint, b Tint lor b Tuint lor b Tlong lor b Tulong lor b Tind;
  Tuint, b Tint lor b Tuint lor b Tlong lor b Tulong lor b Tind;
  Tlong, b Tint lor b Tuint lor b Tlong lor b Tulong lor b Tind;
  Tulong, b Tint lor b Tuint lor b Tlong lor b Tulong lor b Tind;
  Tvlong, b Tvlong lor b Tuvlong; Tuvlong, b Tvlong lor b Tuvlong;
  Tfloat, b Tfloat; Tdouble, b Tdouble; Tind, b Tlong lor b Tulong lor b Tind;
  Tstruct, b Tstruct; Tunion, b Tunion ]

(* vlongs are structures to 5c: returned through a pointer, and their
 * operators calls to _addv... (com64.c) *)
let machine = {
  thechar = '5'; sz_ind = 4; maxalign = 4;
  typecmplx = typesuv; typeword = typechlp; typeswitch = typechl;
  ncast;
  machcap = (fun _ -> false);
}

(*****************************************************************************)
(* Moves (txt.c's gmove) *)
(*****************************************************************************)

module A = Ix_asm.Asm
open Emit

let is_mem (n : node) = match n.op with ONAME | OINDREG | OIND -> true | _ -> false

let load_op = function
  | Tfloat -> "MOVF" | Tdouble -> "MOVD" | Tchar -> "MOVB" | Tuchar -> "MOVBU" | Tshort -> "MOVH" | Tushort -> "MOVHU"
  | _ -> "MOVW"

let store_op = function Tvlong -> "MOVD" | t -> load_op t

let samaddr (f : node) (t : node) = f.op = OREGISTER && t.op = OREGISTER && f.reg = t.reg

(* f to t: a load or a store through a register, or a conversion *)
let rec gmove (f : node) (t : node) =
  let ft = et f and tt = et t in
  if is_mem f then begin
    let nod = if typechlp ft && typeilp tt then regalloc t (Some t) else regalloc f (Some t) in
    ignore (gins (load_op ft) (Some f) (Some nod));
    gmove nod t;
    regfree nod
  end
  else if is_mem t then begin
    let nod = if ft = tt then regalloc t (Some f) else regalloc t None in
    gmove f nod;
    ignore (gins (store_op tt) (Some nod) (Some t));
    regfree nod
  end
  else begin
    (* through a register, extended as the source says *)
    let via ld cvt = let nod = regalloc f None in ignore (gins ld (Some f) (Some nod)); ignore (gins cvt (Some nod) (Some t)); regfree nod in
    let to_float () = if tt = Tfloat then "MOVWF" else "MOVWD" in
    let bad () = ignore (diag None "bad opcode in gmove %s -> %s" (show_type f.ntype) (show_type t.ntype)) in
    let ins a = if (a = "MOVW" || a = "MOVF" || a = "MOVD") && samaddr f t then () else ignore (gins a (Some f) (Some t)) in
    match ft with
    | Tdouble | Tvlong | Tfloat -> (
        match tt with
        | Tdouble | Tvlong -> ins (if ft = Tfloat then "MOVFD" else "MOVD")
        | Tfloat -> ins (if ft = Tfloat then "MOVF" else "MOVDF")
        | Tint | Tuint | Tlong | Tulong | Tind | Tshort | Tushort | Tchar | Tuchar -> ins (if ft = Tfloat then "MOVFW" else "MOVDW")
        | _ -> bad ())
    | Tuint | Tulong when tt = Tfloat || tt = Tdouble ->
        (* the top bit apart: vfp's conversion is signed *)
        let nod = regalloc f None in
        let nod1 = regalloc f None in
        ignore (gins "MOVW" (Some f) (Some nod));
        ignore (gins "MOVW" (Some nod) (Some nod1));
        ignore (gins "AND" (Some (nodconst 0x80000000L)) (Some nod1));
        ignore (gins "EOR" (Some nod1) (Some nod));
        ignore (gins (to_float ()) (Some nod) (Some t));
        let q = gins "CMP" (Some (nodconst 0L)) None in
        raddr (Some nod1) q;
        let p1 = gins "BEQ" None None in
        regfree nod;
        regfree nod1;
        let nod = regalloc t None in
        if tt = Tfloat then (ignore (gins "MOVF" (Some (nodfconst 2147483648.)) (Some nod)); ignore (gins "ADDF" (Some nod) (Some t)))
        else (ignore (gins "MOVD" (Some (nodfconst 2147483648.)) (Some nod)); ignore (gins "ADDD" (Some nod) (Some t)));
        regfree nod;
        patch p1 !pc
    | Tint | Tlong | Tind | Tuint | Tulong -> (
        match tt with
        | Tdouble -> ignore (gins "MOVWD" (Some f) (Some t))
        | Tfloat -> ignore (gins "MOVWF" (Some f) (Some t))
        | Tint | Tuint | Tlong | Tulong | Tind | Tshort | Tushort | Tchar | Tuchar -> ins "MOVW"
        | _ -> bad ())
    | Tshort | Tushort | Tchar | Tuchar -> (
        let ld = load_op ft in
        match tt with
        | Tdouble | Tfloat -> via ld (to_float ())
        | Tint | Tuint | Tlong | Tulong | Tind -> ins ld
        | Tshort | Tushort when ft = Tchar || ft = Tuchar -> ins ld
        | Tshort | Tushort | Tchar | Tuchar -> ins "MOVW"
        | _ -> bad ())
    | _ -> bad ()
  end

(* a narrowing move within registers, in a comparison (txt.c's gmover) *)
let gmover (f : node) (t : node) =
  let ft = et f and tt = et t in
  if typechlp ft && typechlp tt && ewidth ft >= ewidth tt && List.mem tt [ Tshort; Tushort; Tchar; Tuchar ] then
    ignore (gins (load_op tt) (Some f) (Some t))
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
      let q = nextpc () in
      q.as_ <- fl et "CMP" "CMPF" "CMPD";
      q.from <- naddr_opt f1;
      (match q.as_, f1, q.from with
       | "CMP", Some { op = OCONST; _ }, Some (A.Imm v) when Int64.compare v 0L < 0 && v <> -2147483648L ->
           q.as_ <- "CMN"; q.from <- Some (A.Imm (Int64.neg v))
       | _ -> ());
      raddr f2 q;
      let fd = typefd et in
      let br =
        match o with
        | OEQ -> "BEQ" | ONE -> "BNE"
        | OLT -> if fd && not tr then "BMI" else "BLT"
        | OLE -> if fd && not tr then "BLS" else "BLE"
        | OGE -> if fd && tr then "BPL" else "BGE"
        | OGT -> if fd && tr then "BHI" else "BGT"
        | OLO -> "BLO" | OLS -> "BLS" | OHS -> "BHS" | OHI -> "BHI"
        | _ ->
            let q = nextpc () in
            q.as_ <- "CASE"; q.cond <- [ "LS" ]; q.from <- naddr_opt f2;
            "BHI"
      in
      let q = nextpc () in
      q.as_ <- br
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
  let order () = if n.complex > nn.complex then (let a = Gen.reglpcgen n (w <= 2) in let b = Gen.reglpcgen nn (w <= 2) in a, b) else (let b = Gen.reglpcgen nn (w <= 2) in let a = Gen.reglpcgen n (w <= 2) in a, b) in
  if w <= 2 then begin
    let nod1, nod2 = order () in
    let nod3 = regalloc (regnode ()) None in
    let nod4 = regalloc (regnode ()) None in
    let nod3, nod4 = if nod3.reg > nod4.reg then nod4, nod3 else nod3, nod4 in
    let nod0 = nodconst (Int64.of_int ((1 lsl nod3.reg) lor (1 lsl nod4.reg))) in
    if w = 2 && nod1.xoffset = 0 then gmovm nod1 nod0 false
    else (gmove nod1 nod3; if w = 2 then (nod1.xoffset <- nod1.xoffset + 4; gmove nod1 nod4));
    if w = 2 && nod2.xoffset = 0 then gmovm nod0 nod2 false
    else (gmove nod3 nod2; if w = 2 then (nod2.xoffset <- nod2.xoffset + 4; gmove nod4 nod2));
    regfree nod1; regfree nod2; regfree nod3; regfree nod4
  end
  else begin
    let nod1, nod2 = order () in
    let m = ref 0 and c = ref 0 in
    while !c < w && !c < 4 do
      let i = tmpreg () in
      !regs.(i) <- !regs.(i) + 1;
      m := !m lor (1 lsl i);
      incr c
    done;
    let c = !c and w = ref w in
    let nod4 = nodconst (Int64.of_int !m) in
    if !w < 3 * c then
      while !w > c do gmovm nod1 nod4 true; gmovm nod4 nod2 true; w := !w - c done
    else begin
      let nod3 = regalloc (regnode ()) None in
      Gen.gopcode OAS (Some (nodconst (Int64.of_int (!w / c)))) None (Some nod3);
      w := !w mod c;
      let pc1 = !pc in
      gmovm nod1 nod4 true;
      gmovm nod4 nod2 true;
      Gen.gopcode OSUB (Some (nodconst 1L)) None (Some nod3);
      Gen.gopcode OEQ (Some (nodconst 0L)) (Some nod3) None;
      (p ()).as_ <- "BGT";
      patch (p ()) pc1;
      regfree nod3
    end;
    (* the rest, with the highest registers of the list *)
    let c = ref c in
    if !w > 0 then begin
      let i = ref 0 in
      while !c > !w do
        while !m land (1 lsl !i) = 0 do incr i done;
        m := !m land lnot (1 lsl !i);
        !regs.(!i) <- 0;
        decr c;
        incr i
      done;
      nod4.vconst <- Int64.of_int !m;
      gmovm nod1 nod4 false;
      gmovm nod4 nod2 false
    end;
    let i = ref 0 in
    while !c > 0 do
      while !m land (1 lsl !i) = 0 do incr i done;
      !regs.(!i) <- 0;
      decr c;
      incr i
    done;
    regfree nod1;
    regfree nod2
  end

(* a switch: a table (CASE, then BCASEs) when dense, compares when few,
 * a binary search otherwise *)
let swit (q : (int64 * int) array) def (n : node) =
  let tn = regalloc (regnode ()) None in
  let rec swit2 lo nc =
    let value i = fst q.(lo + i) and label i = snd q.(lo + i) in
    let span = if nc >= 3 then Int64.to_int (sx32 (Int64.sub (value (nc - 1)) (value 0))) else 0 in
    if nc >= 3 && span > 0 && span < nc * 2 then begin
      let v = ref (value 0) in
      if !v <> 0L then Gen.gopcode OSUB (Some (nodconst !v)) None (Some n);
      Gen.gopcode OCASE (Some (nodconst (Int64.sub (value (nc - 1)) !v))) (Some n) None;
      patch (p ()) def;
      for i = 0 to nc - 1 do
        while value i <> !v do
          let q = nextpc () in q.as_ <- "BCASE"; patch q def;
          v := Int64.succ !v
        done;
        let q = nextpc () in q.as_ <- "BCASE"; patch q (label i);
        v := Int64.succ !v
      done;
      patch (gbranch OGOTO) def
    end
    else if nc < 5 then begin
      for i = 0 to nc - 1 do
        Gen.gopcode OEQ (Some (nodconst (value i))) (Some n) None;
        patch (p ()) (label i)
      done;
      patch (gbranch OGOTO) def
    end
    else begin
      let i = nc / 2 in
      Gen.gopcode OGT (Some (nodconst (value i))) (Some n) None;
      let sp = p () in
      Gen.gopcode OEQ (Some (nodconst (value i))) (Some n) None;
      patch (p ()) (label i);
      swit2 lo i;
      patch sp !pc;
      swit2 (lo + i + 1) (nc - i - 1)
    end
  in
  swit2 0 (Array.length q);
  regfree tn

let backend = {
  arch = A.Arm; nreg = 16; nfreg = 8; regret = 0; fregret = 0; regsp = 13;
  (* the linker's temporary R11, SB R12, SP, LR, PC; R9 and R10 for extern registers *)
  reserved = [ 11; 12; 13; 14; 15; 10; 9 ]; regtmp = 11; word = 4; float_from_last = false;
  ret = "RET"; offset32 = true; zero_reg = None;
  gmove; gmover; gopcode;
}

let hooks = {
  Gen.sucopy; swit;
  fits = (fun _ v -> v > -4096 && v < 4096);
  neg = (fun nn -> Gen.gopcode OSUB (Some nn) (Some (nodconst 0L)) (Some nn));
  rsb = true; by_left = false; com64 = true; shifts = false; zero_arg = false; asop_load = false; indreg_ptr = false;
}
