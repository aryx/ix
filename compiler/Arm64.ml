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

(* the no-op casts: pointers are vlongs (7c's txt.c) *)
let ncast = table [
  Tchar, b Tchar lor b Tuchar; Tuchar, b Tchar lor b Tuchar;
  Tshort, b Tshort lor b Tushort; Tushort, b Tshort lor b Tushort;
  Tint, b Tint lor b Tuint lor b Tlong lor b Tulong; Tuint, b Tint lor b Tuint lor b Tlong lor b Tulong;
  Tlong, b Tint lor b Tuint lor b Tlong lor b Tulong; Tulong, b Tint lor b Tuint lor b Tlong lor b Tulong;
  Tvlong, b Tvlong lor b Tuvlong lor b Tind; Tuvlong, b Tvlong lor b Tuvlong lor b Tind;
  Tfloat, b Tfloat; Tdouble, b Tdouble; Tind, b Tvlong lor b Tuvlong lor b Tind;
  Tstruct, b Tstruct; Tunion, b Tunion ]

(* what 7c generates itself, rather than com64.c's calls (7c's machcap.c) *)
let machcap (n : node option) =
  match n with
  | None -> true
  | Some n -> (
      match n.op with
      | OMUL | OLMUL | OASMUL | OASLMUL -> typechlv (et n)
      | OADD | OAND | OOR | OSUB | OXOR | OASHL | OLSHR | OASHR | ONEG -> typechlv (et (l n))
      | OCAST | OCOND | OCOMMA | OLIST | OANDAND | OOROR | ONOT | OASADD | OASSUB | OASAND | OASOR | OASXOR
      | OASASHL | OASASHR | OASLSHR | OPOSTINC | OPOSTDEC | OPREINC | OPREDEC
      | OEQ | ONE | OLE | OGT | OLT | OGE | OHI | OHS | OLO | OLS -> true
      | _ -> false)

let machine = {
  thechar = '7'; sz_ind = 8; maxalign = 8;
  typecmplx = typesu; typeword = typechlvp; typeswitch = typechlv;
  ncast;
  machcap;
}

(*****************************************************************************)
(* Moves (7c's txt.c gmove) *)
(*****************************************************************************)

module A = Ix_asm.Asm
open Emit

let is_mem (n : node) = match n.op with ONAME | OINDREG | OIND -> true | _ -> false

(* a word is MOVW, a vlong or pointer MOV *)
let width_op et = if ewidth et = 4 then (if typeu et then "MOVWU" else "MOVW") else "MOV"

let load_op = function
  | Tint -> "MOVW" | Tuint -> "MOVWU" | Tfloat -> "FMOVS" | Tdouble -> "FMOVD" | Tchar -> "MOVB" | Tuchar -> "MOVBU"
  | Tshort -> "MOVH" | Tushort -> "MOVHU" | t -> width_op t

let store_op = function
  | Tint -> "MOVW" | Tuint -> "MOVWU" | Tfloat -> "FMOVS" | Tdouble -> "FMOVD" | Tchar -> "MOVB" | Tuchar -> "MOVBU"
  | Tshort -> "MOVH" | Tushort -> "MOVHU" | t -> if ewidth t = 4 then "MOVW" else "MOV"

let samaddr (f : node) (t : node) = f.op = OREGISTER && t.op = OREGISTER && f.reg = t.reg

let rec gmove (f : node) (t : node) =
  let ft = et f and tt = et t in
  if is_mem f then begin
    let nod = regalloc f (Some t) in
    ignore (gins (load_op ft) (Some f) (Some nod));
    gmove nod t;
    regfree nod
  end
  else if is_mem t then begin
    (* a 0 stored from the zero register *)
    if not (typefd ft) && Check.vconst (Some f) = 0 then ignore (gins (store_op tt) (Some f) (Some t))
    else begin
      let nod = if ft = tt then regalloc t (Some f) else regalloc t None in
      gmove f nod;
      ignore (gins (store_op tt) (Some nod) (Some t));
      regfree nod
    end
  end
  else begin
    let bad () = ignore (diag None "bad opcode in gmove %s -> %s" (show_type f.ntype) (show_type t.ntype)) in
    let ins a =
      if (a = "MOV" || ((a = "MOVW" || a = "MOVWU") && ewidth ft = ewidth tt) || a = "FMOVS" || a = "FMOVD") && samaddr f t then ()
      else ignore (gins a (Some f) (Some t))
    in
    let now a = ignore (gins a (Some f) (Some t)) in
    let via ld cvt = let nod = regalloc f None in ignore (gins ld (Some f) (Some nod)); ignore (gins cvt (Some nod) (Some t)); regfree nod in
    let single = ft = Tfloat in
    match ft with
    | Tdouble | Tfloat -> (
        match tt with
        | Tdouble -> ins (if single then "FCVTSD" else "FMOVD")
        | Tfloat -> ins (if single then "FMOVS" else "FCVTDS")
        | Tchar | Tshort | Tint | Tlong -> ins (if single then "FCVTZSSW" else "FCVTZSDW")
        | Tuchar | Tushort | Tuint | Tulong -> ins (if single then "FCVTZUSW" else "FCVTZUDW")
        | Tvlong -> ins (if single then "FCVTZSS" else "FCVTZSD")
        | Tuvlong | Tind -> ins (if single then "FCVTZUS" else "FCVTZUD")
        | _ -> bad ())
    | Tuint | Tulong | Tint | Tlong -> (
        let u = ft = Tuint || ft = Tulong in
        match tt with
        | Tdouble -> now (if u then "UCVTFWD" else "SCVTFWD")
        | Tfloat -> now (if u then "UCVTFWS" else "SCVTFWS")
        | Tint | Tuint | Tlong | Tulong | Tshort | Tushort | Tchar | Tuchar -> ins (if typeu tt then "MOVWU" else "MOVW")
        | Tvlong | Tuvlong | Tind -> ins (if typeu ft then "MOVWU" else "SXTW")
        | _ -> bad ())
    | Tvlong | Tuvlong | Tind -> (
        match tt with
        | Tdouble -> now (if ft = Tvlong then "SCVTFD" else "UCVTFD")
        | Tfloat -> now (if ft = Tvlong then "SCVTFS" else "UCVTFS")
        | Tint | Tuint | Tlong | Tulong | Tshort | Tushort | Tchar | Tuchar -> ins "MOVWU"
        | Tvlong | Tuvlong | Tind -> ins "MOV"
        | _ -> bad ())
    | Tshort | Tushort | Tchar | Tuchar -> (
        let ld = load_op ft and u = typeu ft in
        match tt with
        | Tdouble -> via ld (if u then "UCVTFWD" else "SCVTFWD")
        | Tfloat -> via ld (if u then "UCVTFWS" else "SCVTFWS")
        | Tint | Tuint | Tlong | Tulong | Tvlong | Tuvlong | Tind -> ins ld
        | Tshort | Tushort when ft = Tchar || ft = Tuchar -> ins ld
        | Tshort | Tushort | Tchar | Tuchar -> ins "MOV"
        | _ -> bad ())
    | _ -> bad ()
  end

let gmover (f : node) (t : node) =
  let ft = et f and tt = et t in
  let a = match tt with Tshort -> Some "MOVH" | Tushort -> Some "MOVHU" | Tchar -> Some "MOVB" | Tuchar -> Some "MOVBU" | Tint -> Some "MOVW" | Tuint -> Some "MOVWU" | _ -> None in
  match a with
  | Some a when typechlp ft && typechlp tt && ewidth ft >= ewidth tt -> ignore (gins a (Some f) (Some t))
  | _ -> gmove f t

(*****************************************************************************)
(* Operators (7c's gopcode): W for 32 bits *)
(*****************************************************************************)

let isv = function Tvlong | Tuvlong | Tind -> true | _ -> false

let gopcode (o : op) tr (f1 : node option) (f2 : node option) (t : node option) =
  (* a constant's width is its destination's *)
  let et =
    match f1 with
    | Some ({ ntype = Some ty0; _ } as f1) ->
        if f1.op = OCONST then
          (match t, f2 with
           | Some { ntype = Some tt; _ }, _ -> tt.etype
           | _, Some { ntype = Some t2; _ } when ewidth t2.etype > ewidth ty0.etype -> t2.etype
           | _ -> ty0.etype)
        else ty0.etype
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
  | OAS -> gmove (Option.get f1) (Option.get t)
  | OEQ | ONE | OLT | OLE | OGE | OGT | OLO | OLS | OHS | OHI ->
      let q = nextpc () in
      q.as_ <- fl "FCMPS" "FCMPD" (w32 "CMP");
      q.from <- naddr_opt f1;
      (match q.as_, f1, q.from with
       | "CMPW", Some { op = OCONST; _ }, Some (A.Imm v) when Int64.compare v 0L < 0 && mask32 v <> 0x80000000L ->
           q.as_ <- "CMNW"; q.from <- Some (A.Imm (Int64.neg v))
       | "CMP", Some { op = OCONST; _ }, Some (A.Imm v) when Int64.compare v 0L < 0 && v <> Int64.min_int ->
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
        | OLO -> "BLO" | OLS -> "BLS" | OHS -> "BHS" | _ -> "BHI"
      in
      (nextpc ()).as_ <- br
  | _ ->
      let a =
        match o with
        | OASADD | OADD -> fl "FADDS" "FADDD" (w32 "ADD")
        | OASSUB | OSUB -> fl "FSUBS" "FSUBD" (w32 "SUB")
        | OASOR | OOR -> w32 "ORR" | OASAND | OAND -> w32 "AND" | OASXOR | OXOR -> w32 "EOR"
        | OASLSHR | OLSHR -> w32 "LSR" | OASASHR | OASHR -> w32 "ASR" | OASASHL | OASHL -> w32 "LSL"
        | OFUNC -> "BL"
        | OASMUL | OMUL -> fl "FMULS" "FMULD" (w32 "MUL")
        | OASDIV | ODIV -> fl "FDIVS" "FDIVD" (w32 "SDIV")
        | OASMOD | OMOD -> w32 "REM"
        | OASLMUL | OLMUL -> if isv et then "MUL" else "UMULL"
        | OASLMOD | OLMOD -> w32 "UREM"
        | OASLDIV | OLDIV -> w32 "UDIV"
        | OCOM -> w32 "MVN" | ONEG -> w32 "NEG"
        | OCASE -> "CASE"
        | o -> diag None "bad in gopcode %s" (opname o)
      in
      emit a

(*****************************************************************************)
(* Block copies and switches (7c's sugen, layout, swit) *)
(*****************************************************************************)

(* c words from f to t, two registers in turn (7c's layout); cn, the
 * loop's count, set on the way *)
let rec layout (f : node) (t : node) c cv (cn : node option) =
  let c = ref c in
  while !c > 3 do layout f t 2 0 None; c := !c - 2 done;
  let c = !c in
  let t1 = regalloc (regnode ()) None and t2 = regalloc (regnode ()) None in
  let move a b = Gen.gopcode OAS (Some a) None (Some b) in
  if c > 0 then (move f t1; f.xoffset <- f.xoffset + 4);
  Option.iter (fun cn -> move (nodconst (Int64.of_int cv)) cn) cn;
  if c > 1 then (move f t2; f.xoffset <- f.xoffset + 4);
  if c > 0 then (move t1 t; t.xoffset <- t.xoffset + 4);
  if c > 2 then (move f t1; f.xoffset <- f.xoffset + 4);
  if c > 1 then (move t2 t; t.xoffset <- t.xoffset + 4);
  if c > 2 then (move t1 t; t.xoffset <- t.xoffset + 4);
  regfree t1;
  regfree t2

(* the bytes past the words, then the words unrolled, or in a loop *)
let sucopy (n : node) (nn : node) w =
  let as_long (x : node) = let t0 = x.ntype in x.ntype <- Some (ty Tlong); let r = Gen.reglcgen x None in x.ntype <- t0; r in
  let nod1, nod2 = if n.complex > nn.complex then (let a = as_long n in let b = as_long nn in a, b) else (let b = as_long nn in let a = as_long n in a, b) in
  let w = ref w in
  let m = !w mod 4 in
  if m > 0 then begin
    nod1.xoffset <- nod1.xoffset + !w - m;
    nod2.xoffset <- nod2.xoffset + !w - m;
    let nod3 = regalloc (regnode ()) None in
    for _ = 1 to m do
      ignore (gins "MOVB" (Some nod1) (Some nod3));
      ignore (gins "MOVB" (Some nod3) (Some nod2));
      nod1.xoffset <- nod1.xoffset + 1;
      nod2.xoffset <- nod2.xoffset + 1;
      decr w
    done;
    regfree nod3;
    nod1.xoffset <- nod1.xoffset - !w;
    nod2.xoffset <- nod2.xoffset - !w
  end;
  let w = !w / 4 in
  if w <= 5 then layout nod1 nod2 w 0 None
  else begin
    (* unrolled 3 to 5 times, 2 for a small one: the least code *)
    let c = ref 0 and best = ref 100 in
    for i = (if w <= 15 then 2 else 3) to 5 do
      if i + w mod i <= !best then (c := i; best := i + w mod i)
    done;
    let c = !c in
    let nod3 = regalloc (regnode ()) None in
    layout nod1 nod2 (w mod c) (w / c) (Some nod3);
    let pc1 = !pc in
    layout nod1 nod2 c 0 None;
    Gen.gopcode OSUB (Some (nodconst 1L)) None (Some nod3);
    let bump (x : node) = x.op <- OREGISTER; let t0 = x.ntype in x.ntype <- Some (ty Tind); Gen.gopcode OADD (Some (nodconst (Int64.of_int (c * 4)))) None (Some x); x.ntype <- t0 in
    bump nod1;
    bump nod2;
    Gen.gopcode OGT (Some (nodconst 0L)) (Some nod3) None;
    patch (p ()) pc1;
    regfree nod3
  end;
  regfree nod1;
  regfree nod2

(* a vlong's constant, or a long's (7c's nodgconst) *)
let nodgconst v (t : typ option) =
  match t with
  | Some t when typev t.etype -> let n = nodconst v in n.ntype <- Some (ty Tvlong); n
  | _ -> nodconst (Int64.of_int32 (Int64.to_int32 v))

let swit (q : (int64 * int) array) def (n : node) =
  let tn = regalloc (regnode ()) None in
  let rec swit2 lo nc =
    let value i = fst q.(lo + i) and label i = snd q.(lo + i) in
    let range = if nc >= 3 then Int64.sub (value (nc - 1)) (value 0) else 0L in
    if nc >= 3 && Int64.compare range 0L > 0 && Int64.compare range (Int64.of_int (nc * 2)) < 0 then begin
      let v = ref (value 0) in
      if !v <> 0L then Gen.gopcode OSUB (Some (nodgconst !v n.ntype)) None (Some n);
      Gen.gopcode OHI (Some (nodgconst (Int64.sub (value (nc - 1)) !v) n.ntype)) (Some n) None;
      patch (p ()) def;
      Gen.gopcode OCASE (Some n) None (Some tn);
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
        Gen.gopcode OEQ (Some (nodgconst (value i) n.ntype)) (Some n) None;
        patch (p ()) (label i)
      done;
      patch (gbranch OGOTO) def
    end
    else begin
      let i = nc / 2 in
      Gen.gopcode OGT (Some (nodgconst (value i) n.ntype)) (Some n) None;
      let sp = p () in
      Gen.gopcode OEQ (Some (nodgconst (value i) n.ntype)) (Some n) None;
      patch (p ()) (label i);
      swit2 lo i;
      patch sp !pc;
      swit2 (lo + i + 1) (nc - i - 1)
    end
  in
  swit2 0 (Array.length q);
  regfree tn

let backend = {
  arch = A.Arm64; nreg = 32; nfreg = 32; regret = 0; fregret = 0; regsp = 31;
  (* the linker's temporary R17, SB R28, SP (and ZR) R31; R26 and R27 for extern registers *)
  reserved = [ 17; 28; 31; 27; 26 ]; regtmp = 17; word = 8; float_from_last = true;
  ret = "RETURN"; offset32 = false; zero_reg = Some 31;
  gmove; gmover; gopcode;
}

(* an offset a load or store encodes: scaled by its size, 12 bits up,
 * or 9 bits signed (7c's usableoffset) *)
let fits (n : node) o =
  let s = min 16 (t n).width in
  s > 0 && o mod s = 0 && o >= -256 && o < 4096 * s

let hooks = {
  Gen.sucopy; swit; fits;
  neg = (fun f t -> Gen.gopcode ONEG (Some f) None (Some t)); mul32 = true;
  rsb = false; by_left = true; com64 = false; shifts = true; zero_arg = true; asop_load = true; indreg_ptr = true;
}
