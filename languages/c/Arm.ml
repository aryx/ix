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
let rec gmove (f : expr) (t : expr) =
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
    let bad () = ignore (diag None "bad opcode in gmove %s -> %s" (show_type (Some f.t)) (show_type (Some t.t))) in
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
let gmover (f : expr) (t : expr) =
  let ft = et f and tt = et t in
  if typechlp ft && typechlp tt && ewidth ft >= ewidth tt && List.mem tt [ Tshort; Tushort; Tchar; Tuchar ] then
    ins (load_op tt) f t
  else gmove f t

(*****************************************************************************)
(* Operators (txt.c's gopcode) *)
(*****************************************************************************)

let fl et i f d = if et = Tfloat then f else if et = Tdouble || et = Tvlong then d else i

(* tr: the branch is taken when true, and a NaN must not *)
let gopcode (o : gop) tr (f1 : expr option) (f2 : expr option) (t : expr option) =
  let et = match f1 with Some f when f.t != untyped -> et f | _ -> Tlong in
  let emit a f1 f2 =
    let q = nextpc () in
    q.as_ <- a;
    q.from <- naddr_opt f1;
    (match Option.map naddr f2 with Some (A.Reg r | A.FReg r) -> q.reg <- Some r | _ -> ());
    q.to_ <- naddr_opt t
  in
  let fd = typefd et in
  match o with
  | Op Sub when (match f2 with Some x -> is_const x | None -> false) ->
      (* c - x: a reverse subtract *)
      emit (fl et "RSB" "SUBF" "SUBD") f2 f1
  | Op o when is_rel o -> gcmp (fl et "CMP" "CMPF" "CMPD") ~fd ~small:(fun v -> v = -2147483648L) f1 f2; grel o ~fd ~tr
  | Gcase ->
      (* a switch's table: CASE.LS, then to the default *)
      gcmp "CMP" ~fd ~small:(fun v -> v = -2147483648L) f1 f2;
      let q = nextpc () in
      q.as_ <- "CASE"; q.cond <- [ "LS" ]; q.from <- naddr_opt f2;
      grel Hi ~fd ~tr
  | Gcall -> emit "BL" f1 f2
  | Op o ->
      let a =
        match o with
        | Add -> fl et "ADD" "ADDF" "ADDD"
        | Sub -> fl et "SUB" "SUBF" "SUBD"
        | Or -> "ORR" | And -> "AND" | Xor -> "EOR"
        | Lshr -> "SRL" | Ashr -> "SRA" | Ashl -> "SLL"
        | Mul -> fl et "MUL" "MULF" "MULD"
        | Div -> fl et "DIV" "DIVF" "DIVD"
        | Mod -> "MOD"
        | Lmul -> "MULU" | Lmod -> "MODU" | Ldiv -> "DIVU"
        | o -> diag None "bad in gopcode %s" (binop_name o)
      in
      emit a f1 f2
  | Gneg | Gcom -> diag None "bad in gopcode: 5c's front end makes them 0-x and -1^x"

(*****************************************************************************)
(* Block copies and switches (cgen.c's sugen, swt.c's swit) *)
(*****************************************************************************)

(* MOVM's register list, as a mask constant *)
let gmovm (f : expr) (t : expr) w =
  let q = gins "MOVM" (Some f) (Some t) in
  let regs = function Some (A.Imm m) -> Some (A.Regs (List.filter (fun i -> Int64.logand m (Int64.shift_left 1L i) <> 0L) (List.init 16 Fun.id))) | o -> o in
  q.from <- regs q.from;
  q.to_ <- regs q.to_;
  q.cond <- (if w then [ "W"; "U" ] else [ "U" ])

(* w bytes from n to nn: by one or two words, by MOVMs of up to four,
 * or a loop of them *)
let sucopy (n : expr) (nn : expr) w =
  let w = w / 4 in
  (* the addresses, the harder first *)
  let small = w <= 2 in
  let nod1, nod2 =
    if n.complex > nn.complex then (let a = Gen.reglpcgen n small in a, Gen.reglpcgen nn small)
    else (let b = Gen.reglpcgen nn small in Gen.reglpcgen n small, b)
  in
  let at0 (x : expr) = match x.e with Indreg (_, 0) -> true | _ -> false in
  if w <= 2 then begin
    let nod3 = regalloc (regnode ()) None in
    let nod4 = regalloc (regnode ()) None in
    let nod3, nod4 = if reg_of nod3 > reg_of nod4 then nod4, nod3 else nod3, nod4 in
    let nod0 = nodconst (Int64.of_int ((1 lsl reg_of nod3) lor (1 lsl reg_of nod4))) in
    if w = 2 && at0 nod1 then gmovm nod1 nod0 false
    else (gmove nod1 nod3; if w = 2 then gmove (plus nod1 4) nod4);
    if w = 2 && at0 nod2 then gmovm nod0 nod2 false
    else (gmove nod3 nod2; if w = 2 then gmove nod4 (plus nod2 4));
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
        Gen.op2 Sub (nodconst 1L) nod3;
        Gen.compare Eq (nodconst 0L) nod3;
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
let table (n : expr) _ range def = Gen.gcase range n; patch (p ()) def

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
  neg = (fun f t -> Gen.op3 Sub f (nodconst 0L) t); mul32 = false;
  rsb = true; by_left = false; com64 = true; shifts = false; zero_arg = false; asop_load = false; indreg_ptr = false;
}
