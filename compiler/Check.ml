(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Check.mli *)

open Tree

(* what the front end asks of the back end, set by Gen *)
let outstring : (string -> int -> int) ref = ref (fun _ _ -> 0)
let xcom : (node -> unit) ref = ref (fun _ -> ())

let ( |? ) a d = match a with Some x -> x | None -> d

(*****************************************************************************)
(* Constants (sub.c's vconst, log2; scon.c's evconst) *)
(*****************************************************************************)

(* the value of a small integral constant, or -159 *)
let vconst (n : node option) =
  match n with
  | Some ({ op = OCONST; ntype = Some ty; _ } as n) ->
      if typefd (ty.etype) then
        if n.fconst > 100. || n.fconst < -100. then -159
        else let i = Float.to_int n.fconst in if Float.of_int i <> n.fconst then -159 else i
      else if typei (ty.etype) || ty.etype = Tind then
        let i = Int64.to_int32 n.vconst in if Int64.of_int32 i <> n.vconst then -159 else Int32.to_int i
      else -159
  | _ -> -159

let log2 (v : int64) =
  let rec go i = if i >= 64 then -1 else if Int64.shift_left 1L i = v then i else go (i + 1) in
  go 0

let vlog (n : node) = if n.op <> OCONST || typefd (et n) then -1 else log2 n.vconst

let bool b = if b then 1L else 0L

let evconst (n : node) =
  match n.ntype with
  | None -> ()
  | Some ty ->
      let isf = typefd (ty.etype) in
      let lf () = (l n).fconst and rf () = (r n).fconst and lv () = (l n).vconst and rv () = (r n).vconst in
      let lfd () = typefd (et (l n)) in
      let u = Int64.unsigned_compare in
      let res =
        match n.op with
        | ONEG -> Some (if isf then `F (-. lf ()) else `V (Int64.neg (lv ())))
        | OCOM -> Some (`V (Int64.lognot (lv ())))
        | OCAST ->
            if ty.etype = Tvoid then None
            else if isf then Some (`F (if lfd () then lf () else Int64.to_float (lv ())))
            else if lfd () then Some (`V (Int64.of_float (lf ())))
            else Some (`V (convvtox (lv ()) ty.etype))
        | OCONST -> Some (if isf then `F n.fconst else `V n.vconst)
        | OADD -> Some (if isf then `F (lf () +. rf ()) else `V (Int64.add (lv ()) (rv ())))
        | OSUB -> Some (if isf then `F (lf () -. rf ()) else `V (Int64.sub (lv ()) (rv ())))
        | OMUL -> Some (if isf then `F (lf () *. rf ()) else `V (Int64.mul (lv ()) (rv ())))
        | OLMUL -> Some (`V (Int64.mul (lv ()) (rv ())))
        | ODIV | OLDIV | OMOD | OLMOD when vconst n.right = 0 -> None
        | ODIV -> Some (if isf then `F (lf () /. rf ()) else `V (Int64.div (lv ()) (rv ())))
        | OLDIV -> Some (`V (Int64.unsigned_div (lv ()) (rv ())))
        | OMOD -> Some (`V (Int64.rem (lv ()) (rv ())))
        | OLMOD -> Some (`V (Int64.unsigned_rem (lv ()) (rv ())))
        | OAND -> Some (`V (Int64.logand (lv ()) (rv ())))
        | OOR -> Some (`V (Int64.logor (lv ()) (rv ())))
        | OXOR -> Some (`V (Int64.logxor (lv ()) (rv ())))
        | OLSHR -> Some (`V (Int64.shift_right_logical (lv ()) (Int64.to_int (rv ()))))
        | OASHR -> Some (`V (Int64.shift_right (lv ()) (Int64.to_int (rv ()))))
        | OASHL -> Some (`V (Int64.shift_left (lv ()) (Int64.to_int (rv ()))))
        | OLO -> Some (`V (bool (u (lv ()) (rv ()) < 0)))
        | OHI -> Some (`V (bool (u (lv ()) (rv ()) > 0)))
        | OLS -> Some (`V (bool (u (lv ()) (rv ()) <= 0)))
        | OHS -> Some (`V (bool (u (lv ()) (rv ()) >= 0)))
        | OLT -> Some (`V (bool (if lfd () then lf () < rf () else lv () < rv ())))
        | OGT -> Some (`V (bool (if lfd () then lf () > rf () else lv () > rv ())))
        | OLE -> Some (`V (bool (if lfd () then lf () <= rf () else lv () <= rv ())))
        | OGE -> Some (`V (bool (if lfd () then lf () >= rf () else lv () >= rv ())))
        | OEQ -> Some (`V (bool (if lfd () then lf () = rf () else lv () = rv ())))
        | ONE -> Some (`V (bool (if lfd () then lf () <> rf () else lv () <> rv ())))
        | ONOT -> Some (`V (bool (if lfd () then lf () = 0. else lv () = 0L)))
        | OANDAND -> Some (`V (bool (if lfd () then lf () <> 0. && rf () <> 0. else lv () <> 0L && rv () <> 0L)))
        | OOROR -> Some (`V (bool (if lfd () then lf () <> 0. || rf () <> 0. else lv () <> 0L || rv () <> 0L)))
        | _ -> None
      in
      match res with
      | None -> ()
      | Some v ->
          (match v with
           | `F d -> if isf then n.fconst <- d else n.vconst <- convvtox (Int64.of_float d) ty.etype
           | `V v -> if isf then n.fconst <- Int64.to_float v else n.vconst <- convvtox v ty.etype);
          n.oldop <- n.op;
          n.op <- OCONST

(*****************************************************************************)
(* Helpers of the typechecker (sub.c) *)
(*****************************************************************************)

(* a cast that makes no code: a same-size move (sub.c's nocast) *)
let nocast (t1 : typ option) (t2 : typ option) =
  match t1 with
  | Some a when a.nbits <> 0 -> false
  | _ ->
      let i2 = match t2 with Some t -> t.etype | None -> Txxx and i1 = match t1 with Some t -> t.etype | None -> Txxx in
      b i2 land (m ()).ncast (i1) <> 0

(* a cast that means nothing: small to large (sub.c's nilcast) *)
let nilcast (t1 : typ option) (t2 : typ option) =
  match t1, t2 with
  | Some a, Some b when a.nbits = 0 ->
      let e1 = a.etype and e2 = b.etype in
      e1 = e2 || (typefd (e1) && typefd (e2) && ewidth e1 < ewidth e2)
      || (typechlp (e1) && typechlp (e2) && ewidth e1 < ewidth e2)
  | _ -> false

let stcompat (n : node) (t1 : typ option) (t2 : typ option) (ttab : etype -> int) =
  let i2 = match t2 with Some t -> t.etype | None -> Txxx and i1 = match t1 with Some t -> t.etype | None -> Txxx in
  let bb = b i2 in
  if bb land ttab i1 <> 0 then
    if ttab == tasign && (bb = b Tstruct || bb = b Tunion) && not (sametype t1 t2) then true
    else if n.op <> OCAST && bb = b Tind && i1 = Tind && not (sametype t1 t2) then true
    else false
  else true

let tcompat n t1 t2 ttab =
  if stcompat n t1 t2 ttab then
    diag (Some n) "incompatible types: \"%s\" and \"%s\" for op \"%s\"" (show_type t1) (show_type t2) (opname n.op)
  else false

let tlvalue (n : node) = if n.addable = 0 then diag (Some n) "not an l-value" else false

(* a structure element by name, then in unnamed substructures *)
let rec dotsearch (s : sym) (tt : typ option) (n : node) : (typ * int) option =
  let rec els (t : typ option) acc = match t with None -> List.rev acc | Some t -> els t.down (t :: acc) in
  let all = els tt [] in
  match List.filter (fun t1 -> match t1.tsym with Some s1 -> s1 == s | None -> false) all with
  | [ x ] -> Some (x, x.offset)
  | _ :: _ :: _ -> diag (Some n) "ambiguous structure element: %s" s.name
  | [] -> (
      let bytype =
        if s.sclass = Ctypedef || s.sclass = Ctypestr then
          List.filter (fun t1 -> t1.tsym = None && typesu (t1.etype) && sametype s.typ (Some t1)) all
        else [] in
      match bytype with
      | [ x ] -> Some (x, x.offset)
      | _ :: _ :: _ -> diag (Some n) "ambiguous structure element: %s" s.name
      | [] ->
          let found = List.filter_map (fun t1 ->
            if t1.tsym = None && typesu (t1.etype) then
              Option.map (fun (x, o) -> (x, o + t1.offset)) (dotsearch s t1.link n) else None) all in
          match found with [] -> None | [ x ] -> Some x | _ -> diag (Some n) "ambiguous structure element: %s" s.name)

(* n, an ODOT of t at o, made an addressable node or an address plus an
 * offset (sub.c's makedot) *)
let makedot (n : node) (tt : typ) o =
  let n =
    if tt.nbits <> 0 then begin
      let n1 = dup n in
      n.op <- OBIT; n.left <- Some n1; n.right <- None; n.ntype <- Some tt; n.addable <- (l n1).addable;
      n1
    end
    else n
  in
  n.addable <- (l n).addable;
  if n.addable = 0 then begin
    let n1 = node1 OCONST None None in
    n1.vconst <- Int64.of_int o; n1.ntype <- Some (ty Tlong);
    n.right <- Some n1;
    n.ntype <- Some tt
  end
  else begin
    (l n).ntype <- Some tt;
    if o = 0 then copy_into n (l n)
    else begin
      n.ntype <- Some tt;
      let pt = typ Tind (Some tt) in
      pt.width <- (ty Tind).width;
      let n1 = node1 OCONST None None in
      n1.vconst <- Int64.of_int o; n1.ntype <- Some pt;
      let n2 = node1 OADDR n.left None in
      n2.ntype <- Some pt;
      let n1 = node1 OADD (Some n1) (Some n2) in
      n1.ntype <- Some pt;
      n.op <- OIND; n.left <- Some n1; n.right <- None
    end
  end

let rec dotoffset (st : typ) (lt : typ) (n : node) =
  let rec els (t : typ option) acc = match t with None -> List.rev acc | Some t -> els t.down (t :: acc) in
  let unnamed = List.filter (fun t -> t.tsym = None) (els lt.link []) in
  let one l = match l with [] -> -1 | [ o ] -> o | _ -> diag (Some n) "ambiguous unnamed structure element" in
  let o = match st.tag with Some g -> one (List.filter_map (fun t -> match t.tag with Some g' when g' == g -> Some t.offset | _ -> None) unnamed) | None -> -1 in
  if o >= 0 then o
  else
    let o = one (List.filter_map (fun t -> if sametype (Some st) (Some t) then Some t.offset else None) unnamed) in
    if o >= 0 then o
    else one (List.filter_map (fun t -> if typesu (t.etype) then (let o = dotoffset st t n in if o >= 0 then Some (o + t.offset) else None) else None) unnamed)

let rec allfloat (n : node option) flag =
  match n with
  | None -> false
  | Some n ->
      if et n <> Tdouble then true
      else
        match n.op with
        | OCONST -> if flag then n.ntype <- Some (ty Tfloat); true
        | OADD | OSUB | OMUL | ODIV ->
            if not (allfloat n.right flag) then false
            else if not (allfloat n.left flag) then false
            else (if flag then n.ntype <- Some (ty Tfloat); true)
        | OCAST -> if not (allfloat n.left flag) then false else (if flag then n.ntype <- Some (ty Tfloat); true)
        | _ -> false

let typeext1 (st : typ option) (l : node) = match st with Some st when st.etype = Tfloat && allfloat (Some l) false -> ignore (allfloat (Some l) true) | _ -> ()

(* the extensions of an assignment (sub.c's typeext): 0 as a pointer,
 * a structure to its unnamed substructure *)
let typeext (st : typ option) (l : node) =
  match l.ntype, st with
  | None, _ | _, None -> ()
  | Some lt, Some st ->
      if st.etype = Tind && vconst (Some l) = 0 then (l.ntype <- Some st; l.vconst <- 0L)
      else begin
        typeext1 (Some st) l;
        if typesu (st.etype) && typesu (lt.etype) then begin
          let o = dotoffset st lt l in
          if o >= 0 then (let n1 = node1 OXXX None None in copy_into n1 l; l.op <- ODOT; l.left <- Some n1; l.right <- None; makedot l st o)
        end
        else
          match st.link, lt.link with
          | Some sl, Some ll when st.etype = Tind && typesu (sl.etype) && lt.etype = Tind && typesu (ll.etype) ->
              let o = dotoffset sl ll l in
              if o >= 0 then begin
                l.ntype <- Some st;
                if o <> 0 then begin
                  let n1 = node1 OXXX None None in copy_into n1 l;
                  let n2 = node1 OCONST None None in n2.vconst <- Int64.of_int o; n2.ntype <- Some st;
                  l.op <- OADD; l.left <- Some n1; l.right <- Some n2
                end
              end
          | _ -> ()
      end

(* "the usual arithmetic conversions" (sub.c's arith) *)
let arith (n : node) f =
  let t1 = (l n).ntype in
  let t2 = match n.right with None -> t1 | Some r -> r.ntype in
  let i = match t1 with Some t -> t.etype | None -> Txxx and j = match t2 with Some t -> t.etype | None -> Txxx in
  let k = arith_tab i j in
  if k = Tind then (if i = Tind then n.ntype <- t1 else if j = Tind then n.ntype <- t2)
  else begin
    let k = if f then promote k else k in
    n.ntype <- Some (ty k)
  end;
  let bad () = diag (Some n) "pointer addition not fully declared: %s" (show_type (link (t n)).link) in
  if n.op = OSUB && i = Tind && j = Tind then begin
    let w = (link (t (r n))).width in
    if w < 1 || (t (l n)).link = None || (link (t (l n))).width < 1 then bad ();
    n.ntype <- Some (ty (if ewidth Tind <= ewidth Tlong then Tlong else Tvlong));
    if ewidth Tind > ewidth Tlong then begin
      let n1 = node1 OXXX None None in copy_into n1 n;
      n.op <- OCAST; n.left <- Some n1; n.right <- None; n.ntype <- Some (ty Tlong)
    end;
    if w > 1 then begin
      let n1 = node1 OXXX None None in copy_into n1 n;
      n.op <- ODIV; n.left <- Some n1;
      let c = node1 OCONST None None in c.vconst <- Int64.of_int w; c.ntype <- n.ntype;
      n.right <- Some c;
      let w = vlog c in
      if w >= 0 then (n.op <- OASHR; c.vconst <- Int64.of_int w)
    end
  end
  else begin
    let scaled (side : node) =
      let c = node1 OCAST (Some side) None in
      c.ntype <- n.ntype;
      if (t n).etype = Tind then begin
        let lk = link (t n) in
        let w = if lk.width < 1 then (snap lk; if lk.width < 1 then bad () else lk.width) else lk.width in
        if w > 1 then begin
          let k = node1 OCONST None None in k.vconst <- Int64.of_int w; k.ntype <- n.ntype;
          let mul = node1 OMUL (Some c) (Some k) in mul.ntype <- n.ntype; mul
        end
        else c
      end
      else c
    in
    if not (sametype n.ntype (l n).ntype) then n.left <- Some (scaled (l n));
    match n.right with
    | Some rr when not (sametype n.ntype rr.ntype) -> n.right <- Some (scaled rr)
    | _ -> ()
  end

let side (n : node option) =
  let rec go (n : node option) =
    match n with
    | None -> false
    | Some n -> (
        match n.op with
        | OCAST | ONOT | OADDR | OIND -> go n.left
        | OCOND -> go n.left || go n.right
        | OEQ | ONE | OLT | OGE | OGT | OLE | OADD | OSUB | OMUL | OLMUL | ODIV | OLDIV | OLSHR | OASHL | OASHR
        | OAND | OOR | OXOR | OMOD | OLMOD | OANDAND | OOROR | OCOMMA | ODOT -> go n.left || go n.right
        | OSIGN | OSIZE | OCONST | OSTRING | OLSTRING | ONAME -> false
        | _ -> true)
  in
  go n

(* cast a constant down rather than a variable up: if(c == 'a')
 * (sub.c's relcon) *)
let relcon (l : node) (r : node) =
  if l.op = OCONST && r.op = OCAST && nilcast (Tree.l r).ntype r.ntype then
    let e = et r in
    if (e = Tchar || e = Tuchar || e = Tshort || e = Tushort) && convvtox l.vconst e = l.vconst then begin
      l.ntype <- (Tree.l r).ntype;
      copy_into r (Tree.l r)
    end

(* OEQ ONE OLE OLS OLT OLO OGE OHS OGT OHI (sub.c's relindex, logrel, invrel, comrel) *)
let rels = [| OEQ; ONE; OLE; OLS; OLT; OLO; OGE; OHS; OGT; OHI |]
let relindex o = let rec go i = if rels.(i) = o then i else go (i + 1) in go 0
let logrel = [| OEQ; ONE; OLS; OLS; OLO; OLO; OHS; OHS; OHI; OHI |]
let invrel = [| OEQ; ONE; OGE; OHS; OGT; OHI; OLE; OLS; OLT; OLO |]
let comrel = [| ONE; OEQ; OGT; OHI; OGE; OHS; OLT; OLO; OLE; OLS |]

let mixedasop (lt : typ) (rt : typ) = (not (typefd (lt.etype))) && typefd (rt.etype)

(* reverse a left-leaning OLIST into a right-leaning one (sub.c's invert) *)
let invert (n : node option) =
  match n with
  | Some ({ op = OLIST; _ } as n) ->
      let rec go (i : node) (m : node option) =
        match m with
        | Some ({ op = OLIST; _ } as m) -> i.left <- m.right; m.right <- Some i; go m m.left
        | _ -> i.left <- m; i
      in
      Some (go n n.left)
  | n -> n

(*****************************************************************************)
(* Typechecking (com.c's tcom) *)
(*****************************************************************************)

let addrof = 1 and castof = 2 and addrop = 4

let cast_to (x : node) tt = let c = node1 OCAST (Some x) None in c.ntype <- tt; c

let konst v tt = let c = node OCONST None None in c.vconst <- v; c.ntype <- Some tt; c

exception Bad

let rec tcom n = tcomo n addrof

and tcomo (n : node) f : bool =
  try tcomo1 n f; false with Bad -> n.ntype <- None; true

and tcomo1 (n : node) f =
  let bad () = raise Bad in
  let chk b = if b then bad () in
  n.addable <- 0;
  let l = n.left and r = n.right in
  let ll () = Option.get l and rr () = Option.get r in
  let both () = let o = tcom (ll ()) in chk (o || tcom (rr ())) in
  (match n.op with
   | ODOTDOT -> copy_into n (ll ()); if n.ntype = None then bad ()
   | OCAST ->
       if n.ntype <> None then begin
         if (t n).width = (ty Tlong).width then chk (tcomo (ll ()) (addrof lor castof)) else chk (tcom (ll ()));
         chk (tcompat n (ll ()).ntype n.ntype tcast)
       end
   | ORETURN -> (
       match l with
       | None -> ()
       | Some l ->
           chk (tcom l);
           typeext n.ntype l;
           if not (tcompat n n.ntype l.ntype tasign) then
             if not (sametype n.ntype l.ntype) then n.left <- Some (cast_to l n.ntype))
   | OASI | OAS ->
       if n.op = OASI then n.op <- OAS;
       both ();
       chk (tlvalue (ll ()));
       typeext (ll ()).ntype (rr ());
       chk (tcompat n (ll ()).ntype (rr ()).ntype tasign);
       if not (sametype (ll ()).ntype (rr ()).ntype) then n.right <- Some (cast_to (rr ()) (ll ()).ntype);
       n.ntype <- (ll ()).ntype
   | OASADD | OASSUB | OASMUL | OASLMUL | OASDIV | OASLDIV | OASMOD | OASLMOD | OASOR | OASAND | OASXOR ->
       both ();
       chk (tlvalue (ll ()));
       let ttab = match n.op with OASADD | OASSUB -> tasadd | OASMUL | OASLMUL | OASDIV | OASLDIV -> tmul | _ -> tand in
       if ttab != tand then typeext1 (ll ()).ntype (rr ());
       chk (tcompat n (ll ()).ntype (rr ()).ntype ttab);
       let tt = (ll ()).ntype in
       arith n false;
       while (Tree.l n).op = OCAST do n.left <- (Tree.l n).left done;
       if not (sametype tt n.ntype) && not (mixedasop (Option.get tt) (t n)) then begin
         n.right <- Some (cast_to (Tree.r n) tt);
         n.ntype <- tt
       end;
       if typeu (et n) then
         n.op <- (match n.op with OASDIV -> OASLDIV | OASMUL -> OASLMUL | OASMOD -> OASLMOD | o -> o)
   | OASLSHR | OASASHR | OASASHL ->
       both ();
       chk (tlvalue (ll ()));
       chk (tcompat n (ll ()).ntype (rr ()).ntype tand);
       n.ntype <- (ll ()).ntype;
       n.right <- Some (cast_to (rr ()) (Some (ty Tint)));
       if typeu (et n) && n.op = OASASHR then n.op <- OASLSHR
   | OPREINC | OPREDEC | OPOSTINC | OPOSTDEC ->
       chk (tcom (ll ()));
       chk (tlvalue (ll ()));
       chk (tcompat n (ll ()).ntype (Some (ty Tint)) tadd);
       n.ntype <- (ll ()).ntype;
       if et n = Tind then begin
         let lk = link (t n) in
         if lk.width < 1 then (snap lk; if lk.width < 1 then ignore (diag (Some n) "inc/dec of a void pointer"))
       end
   | OEQ | ONE ->
       both ();
       typeext (ll ()).ntype (rr ());
       typeext (rr ()).ntype (ll ());
       chk (tcompat n (ll ()).ntype (rr ()).ntype trel);
       arith n false;
       n.ntype <- Some (ty Tint)
   | OLT | OGE | OGT | OLE ->
       both ();
       typeext1 (ll ()).ntype (rr ());
       typeext1 (rr ()).ntype (ll ());
       chk (tcompat n (ll ()).ntype (rr ()).ntype trel);
       arith n false;
       if typeu (et n) then n.op <- logrel.(relindex n.op);
       n.ntype <- Some (ty Tint)
   | OCOND ->
       let rl = Tree.l (rr ()) and rr' = Tree.r (rr ()) in
       let o = tcom (ll ()) in
       let o = tcom rl || o in
       chk (tcom rr' || o);
       if et rr' = Tind && vconst (Some rl) = 0 then (rl.ntype <- rr'.ntype; rl.vconst <- 0L);
       if et rl = Tind && vconst (Some rr') = 0 then (rr'.ntype <- rl.ntype; rr'.vconst <- 0L);
       if sametype rr'.ntype rl.ntype then ((rr ()).ntype <- rr'.ntype; n.ntype <- (rr ()).ntype)
       else begin
         chk (tcompat (rr ()) rl.ntype rr'.ntype trel);
         arith (rr ()) false;
         n.ntype <- (rr ()).ntype
       end
   | OADD | OSUB ->
       both ();
       chk (tcompat n (ll ()).ntype (rr ()).ntype (if n.op = OADD then tadd else tsub));
       arith n true
   | OMUL | OLMUL | ODIV | OLDIV ->
       both ();
       chk (tcompat n (ll ()).ntype (rr ()).ntype tmul);
       arith n true;
       if typeu (et n) then n.op <- (match n.op with ODIV -> OLDIV | OMUL -> OLMUL | o -> o)
   | OLSHR | OASHL | OASHR ->
       both ();
       chk (tcompat n (ll ()).ntype (rr ()).ntype tand);
       n.right <- None;
       arith n true;
       n.right <- Some (cast_to (rr ()) (Some (ty Tint)));
       if typeu (et n) && n.op = OASHR then n.op <- OLSHR
   | OAND | OOR | OXOR ->
       both ();
       chk (tcompat n (ll ()).ntype (rr ()).ntype tand);
       arith n true
   | OMOD | OLMOD ->
       both ();
       chk (tcompat n (ll ()).ntype (rr ()).ntype tand);
       arith n true;
       if typeu (et n) then n.op <- OLMOD
   | OPOS ->
       chk (tcom (ll ()));
       let zero = konst 0L (ty Tint) in
       n.op <- OADD; n.right <- l; n.left <- Some zero;
       chk (tcom zero);
       chk (tcompat n zero.ntype (rr ()).ntype tsub);
       arith n true
   | ONEG | OCOM ->
       chk (tcom (ll ()));
       if not ((m ()).machcap (Some n)) then begin
         let c = konst (if n.op = ONEG then 0L else -1L) (ty Tint) in
         n.op <- (if n.op = ONEG then OSUB else OXOR); n.right <- l; n.left <- Some c;
         chk (tcom c);
         chk (tcompat n c.ntype (Tree.r n).ntype (if n.op = OSUB then tsub else tand))
       end;
       arith n true
   | ONOT ->
       chk (tcom (ll ()));
       chk (tcompat n None (ll ()).ntype tnot);
       n.ntype <- Some (ty Tint)
   | OANDAND | OOROR ->
       both ();
       let a = tcompat n None (ll ()).ntype tnot in
       chk (tcompat n None (rr ()).ntype tnot || a);
       n.ntype <- Some (ty Tint)
   | OCOMMA -> both (); n.ntype <- (rr ()).ntype
   | OSIGN -> diag (Some n) "signof is not in the subset"
   | OSIZE ->
       (match l with
        | Some l ->
            if l.op <> OSTRING && l.op <> OLSTRING then chk (tcomo l 0);
            if l.op = OBIT then ignore (diag (Some n) "sizeof bitfield");
            n.ntype <- l.ntype
        | None -> ());
       if n.ntype = None then bad ();
       if (t n).width <= 0 then ignore (diag (Some n) "sizeof undefined type");
       if et n = Tfunc then ignore (diag (Some n) "sizeof function");
       n.op <- OCONST; n.left <- None; n.right <- None;
       n.vconst <- convvtox (Int64.of_int (t n).width) Tint;
       n.ntype <- Some (ty Tint)
   | OFUNC ->
       chk (tcomo (ll ()) 0);
       let ft = t (ll ()) in
       if ft.etype = Tind && (link ft).etype = Tfunc then begin
         let ind = node1 OIND l None in
         ind.ntype <- ft.link;
         n.left <- Some ind
       end;
       chk (tcompat n None (Tree.l n).ntype tfunct);
       chk (tcoma (Tree.l n) r (t (Tree.l n)).down true);
       n.ntype <- (t (Tree.l n)).link
   | ONAME ->
       if n.ntype = None then ignore (diag (Some n) "name not declared: %s" (fnname (Some n)));
       if et n = Tenum then begin
         n.op <- OCONST;
         n.ntype <- (sym n).tenum;
         if not (typefd (et n)) then n.vconst <- (sym n).svconst else n.fconst <- (sym n).sfconst
       end
       else begin
         n.addable <- 1;
         if n.nclass = Cexreg then ignore (diag (Some n) "extern register is not in the subset")
       end
   | OLSTRING ->
       (* runes are 4 bytes, aligned (pswt.c's outlstring) *)
       let o = !outstring "" 0 in
       if o land 3 <> 0 then ignore (!outstring "" (4 - o land 3));
       n.op <- ONAME;
       n.xoffset <- !outstring n.cstring (t n).width;
       n.addable <- 1
   | OSTRING ->
       if (link (t n)) != ty Tchar then begin
         let o = ref (!outstring "" 0) in
         while !o land 3 <> 0 do ignore (!outstring "\000" 1); o := !outstring "" 0 done
       end;
       n.op <- ONAME;
       n.xoffset <- !outstring n.cstring (t n).width;
       n.addable <- 1
   | OCONST -> ()
   | ODOT ->
       chk (tcom (ll ()));
       chk (tcompat n None (ll ()).ntype tdots);
       (match dotsearch (sym n) (t (ll ())).link n with
        | None -> ignore (diag (Some n) "not a member of struct/union: %s" (fnname (Some n)))
        | Some (tt, o) -> makedot n tt o)
   | OADDR ->
       chk (tcomo (ll ()) addrop);
       chk (tlvalue (ll ()));
       if (t (ll ())).nbits <> 0 then ignore (diag (Some n) "address of a bit field");
       if (ll ()).op = OREGISTER then ignore (diag (Some n) "address of a register");
       n.ntype <- Some (typ Tind (ll ()).ntype);
       (t n).width <- (ty Tind).width
   | OIND ->
       chk (tcom (ll ()));
       chk (tcompat n None (ll ()).ntype tindir);
       n.ntype <- (t (ll ())).link;
       n.addable <- 1
   | OSTRUCT -> diag (Some n) "structure constructors are not in the subset"
   | o -> diag (Some n) "unknown op in type complex: %s" (opname o));
  let tt = match n.ntype with Some tt -> tt | None -> bad () in
  if tt.width < 0 then begin
    snap tt;
    if tt.width < 0 then ignore (diag (Some n) "structure not fully declared")
  end;
  if typeaf (tt.etype) && f land addrof <> 0 then begin
    (* an array or a function, used: its address *)
    chk (tlvalue n);
    let l1 = node1 OXXX None None in
    copy_into l1 n;
    n.op <- OADDR;
    if (t l1).etype = Tarray then l1.ntype <- (t l1).link;
    n.left <- Some l1; n.right <- None; n.addable <- 0;
    n.ntype <- Some (typ Tind l1.ntype);
    (t n).width <- (ty Tind).width
  end

(* the arguments against the prototype, promoted (com.c's tcoma) *)
and tcoma (l : node) (n : node option) (tt : typ option) f : bool =
  let tt = match tt with Some x when x.etype = Told || x.etype = Tdot -> None | x -> x in
  match n with
  | None ->
      if tt <> None && not (sametype tt (Some (ty Tvoid))) then diag (Some l) "not enough function arguments: %s" (fnname (Some l))
      else false
  | Some ({ op = OLIST; _ } as n) ->
      let o = tcoma l n.left tt false in
      let tt = match tt with Some x -> (match x.down with None -> Some (ty Tvoid) | d -> d) | None -> None in
      o || tcoma l n.right tt true
  | Some n ->
      if f && tt <> None then ignore (tcoma l None (Option.get tt).down false);
      if tcom n || tcompat n None n.ntype targ then true
      else if sametype tt (Some (ty Tvoid)) then diag (Some n) "too many function arguments: %s" (fnname (Some l))
      else begin
        let promote e = if e = Tchar || e = Tshort then Some (ty Tint) else if e = Tuchar || e = Tushort then Some (ty Tuint) else None in
        let tt =
          match tt with
          | Some x ->
              typeext tt n;
              if stcompat (node OPROTO None None) tt n.ntype tasign then
                ignore (diag (Some l) "argument prototype mismatch \"%s\" for \"%s\": %s" (show_type n.ntype) (show_type tt) (fnname (Some l)));
              (match promote x.etype with Some p -> Some p | None -> tt)
          | None -> (match promote (et n) with Some p -> Some p | None -> if et n = Tfloat then Some (ty Tdouble) else None)
        in
        (match tt with
         | Some _ when not (sametype tt n.ntype) ->
             let n1 = node1 OXXX None None in
             copy_into n1 n;
             n.op <- OCAST; n.left <- Some n1; n.right <- None; n.ntype <- tt; n.addable <- 0
         | _ -> ());
        false
      end

(*****************************************************************************)
(* Commas out of expressions (com.c's comma) *)
(*****************************************************************************)

let rec commas (acc : node list ref) (n : node option) : node option =
  match n with
  | None -> None
  | Some n -> (
      match n.op with
      | OREGISTER | OINDREG | OCONST | ONAME | OSTRING -> Some n
      | OCOMMA ->
          let tt = commas acc n.left in
          acc := Option.get tt :: !acc;
          commas acc n.right
      | OFUNC ->
          n.left <- commas acc n.left;
          n.right <- comargs acc n.right;
          Some n
      | OCOND ->
          n.left <- commas acc n.left;
          comma (Option.get (Tree.r n).left);
          comma (Option.get (Tree.r n).right);
          Some n
      | OANDAND | OOROR ->
          n.left <- commas acc n.left;
          comma (Option.get n.right);
          Some n
      | ORETURN -> Option.iter comma n.left; Some n
      | _ ->
          n.left <- commas acc n.left;
          if n.right <> None then n.right <- commas acc n.right;
          Some n)

and comargs acc (n : node option) =
  (match n with Some ({ op = OLIST; _ } as n) -> n.left <- comargs acc n.left; n.right <- comargs acc n.right | _ -> ());
  commas acc n

and comma (n : node) =
  let acc = ref [] in
  let nn = Option.get (commas acc (Some n)) in
  if !acc <> [] then begin
    if nn != n then copy_into n nn;
    List.iter (fun (lhs : node) ->
      let n1 = node1 OXXX None None in
      copy_into n1 n;
      n.op <- OCOMMA; n.ntype <- n1.ntype; n.left <- Some lhs; n.right <- Some n1; n.lineno <- lhs.lineno) !acc
  end

(*****************************************************************************)
(* The general rewrite (com.c's ccom): no-op casts, zeros, constants *)
(*****************************************************************************)

let rec ccom (n : node option) =
  match n with
  | None -> ()
  | Some n ->
      let l = n.left and r = n.right in
      let ll () = Option.get l and rr () = Option.get r in
      let common () =
        let konst = function None -> true | Some (x : node) -> x.op = OCONST in
        if konst l && konst r then evconst n
      in
      let commute () =
        let again = ref false in
        (match (rr ()).op, (ll ()).op with
         | OCONST, lo when lo = n.op ->
             if (Tree.l (ll ())).op = OCONST then (n.right <- (ll ()).right; (ll ()).right <- r; again := true)
             else if (Tree.r (ll ())).op = OCONST then (n.right <- (ll ()).left; (ll ()).left <- r; again := true)
         | _ -> ());
        if not !again then
          (match (ll ()).op, (rr ()).op with
           | OCONST, ro when ro = n.op ->
               if (Tree.l (rr ())).op = OCONST then (n.left <- (rr ()).right; (rr ()).right <- l; again := true)
               else if (Tree.r (rr ())).op = OCONST then (n.left <- (rr ()).left; (rr ()).left <- l; again := true)
           | _ -> ());
        if !again then ccom (Some n) else common ()
      in
      match n.op with
      | OAS | OASXOR | OASAND | OASOR | OASMOD | OASLMOD | OASLSHR | OASASHR | OASASHL | OASDIV | OASLDIV | OASMUL
      | OASLMUL | OASSUB | OASADD -> ccom l; ccom r
      | OCAST ->
          ccom l;
          let evaluated = (ll ()).op = OCONST && (evconst n; n.op = OCONST) in
          if not evaluated then
            if nocast (ll ()).ntype n.ntype
               && ((not (typefd (et (ll ())))) || (typeu (et (ll ())) && typeu (et n))) then begin
              (ll ()).ntype <- n.ntype;
              copy_into n (ll ())
            end
      | OCOND ->
          ccom l; ccom r;
          if (ll ()).op = OCONST then copy_into n (if vconst l = 0 then Tree.r (rr ()) else Tree.l (rr ()))
      | OREGISTER | OINDREG | OCONST | ONAME -> ()
      | OADDR ->
          ccom l;
          (ll ()).netype <- Tvoid;
          if (ll ()).op = OIND then ((Tree.l (ll ())).ntype <- n.ntype; copy_into n (Tree.l (ll ()))) else common ()
      | OIND ->
          ccom l;
          if (ll ()).op = OADDR then ((Tree.l (ll ())).ntype <- n.ntype; copy_into n (Tree.l (ll ()))) else common ()
      | OEQ | ONE | OLE | OGE | OLT | OGT | OLS | OHS | OLO | OHI ->
          ccom l; ccom r;
          relcon (ll ()) (rr ());
          relcon (rr ()) (ll ());
          common ()
      | OASHR | OASHL | OLSHR ->
          ccom l;
          if vconst l = 0 && not (side r) then copy_into n (ll ())
          else begin
            ccom r;
            if vconst r = 0 then copy_into n (ll ()) else common ()
          end
      | OMUL | OLMUL ->
          ccom l;
          let k = vconst l in
          if k = 0 && not (side r) then copy_into n (ll ())
          else if k = 1 then (copy_into n (rr ()); ccom (Some n))
          else begin
            ccom r;
            let k = vconst r in
            if k = 0 && not (side l) then copy_into n (rr ())
            else if k = 1 then copy_into n (ll ())
            else common ()
          end
      | ODIV | OLDIV ->
          ccom l;
          if vconst l = 0 && not (side r) then copy_into n (ll ())
          else begin
            ccom r;
            let k = vconst r in
            if k = 0 then ignore (diag (Some n) "divide check")
            else if k = 1 then copy_into n (ll ())
            else common ()
          end
      | OSUB ->
          ccom r;
          if (rr ()).op = OCONST then begin
            n.op <- OADD;
            if typefd (et (rr ())) then (rr ()).fconst <- -. (rr ()).fconst else (rr ()).vconst <- Int64.neg (rr ()).vconst;
            ccom (Some n)
          end
          else (ccom l; common ())
      | OXOR | OOR | OADD ->
          ccom l;
          if vconst l = 0 then (copy_into n (rr ()); ccom (Some n))
          else begin
            ccom r;
            if vconst r = 0 then copy_into n (ll ()) else commute ()
          end
      | OAND ->
          ccom l; ccom r;
          if vconst l = 0 && not (side r) then copy_into n (ll ())
          else if vconst r = 0 && not (side l) then copy_into n (rr ())
          else commute ()
      | OANDAND ->
          ccom l;
          if vconst l = 0 then copy_into n (ll ()) else (ccom r; common ())
      | OOROR ->
          ccom l;
          if (ll ()).op = OCONST && (ll ()).vconst <> 0L then (copy_into n (ll ()); n.vconst <- 1L)
          else (ccom r; common ())
      | _ -> ccom l; ccom r; common ()

(*****************************************************************************)
(* Sums of terms, regrouped (scon.c's acom) *)
(*****************************************************************************)

let nterm = 10

let addo (n : node option) =
  match n with
  | Some n when not (typefd (et n)) && ((not (typev (et n))) || ewidth Tvlong = ewidth Tind) -> (
      match n.op with
      | OCAST -> nilcast (l n).ntype n.ntype
      | ONEG | OADD | OSUB -> true
      | OMUL -> (l n).op = OCONST || (r n).op = OCONST
      | _ -> false)
  | _ -> false

let acast (tt : typ) (n : node) =
  if et n <> tt.etype || n.op = OBIT then begin
    let c = node1 OCAST (Some n) None in
    if nocast (l c).ntype (Some tt) then copy_into c (l c);
    c.ntype <- Some tt;
    c
  end
  else n

type term = { mutable mult : int64; mutable tnode : node option; id : int }

let rec acom (n : node) =
  match n.op with
  | ONAME | OCONST | OSTRING | OINDREG | OREGISTER -> ()
  | ONEG -> if addo (Some n) && addo n.left then acom0 n else acom (l n)
  | OADD | OSUB | OMUL ->
      if addo (Some n) && (addo n.right || addo n.left) then acom0 n else (acom (l n); acom (r n))
  | _ -> Option.iter acom n.left; Option.iter acom n.right

(* bust the terms out, then put them back together *)
and acom0 (n : node) =
  let tt = t n in
  let terms = Array.init nterm (fun id -> { mult = 0L; tnode = None; id }) in
  let count = ref 1 in
  let rec acom1 v (n : node) =
    if v <> 0L && !count < nterm then
      if not (addo (Some n)) then begin
        if n.op = OCONST && not (typefd (et n)) then terms.(0).mult <- Int64.add terms.(0).mult (Int64.mul v n.vconst)
        else (terms.(!count).mult <- v; terms.(!count).tnode <- Some n; incr count)
      end
      else
        match n.op with
        | OCAST -> acom1 v (l n)
        | ONEG -> acom1 (Int64.neg v) (l n)
        | OADD -> acom1 v (l n); acom1 v (r n)
        | OSUB -> acom1 v (l n); acom1 (Int64.neg v) (r n)
        | OMUL ->
            if (l n).op = OCONST && not (typefd (et n)) then acom1 (Int64.mul v (l n).vconst) (r n)
            else if (r n).op = OCONST && not (typefd (et n)) then acom1 (Int64.mul v (r n).vconst) (l n)
        | _ -> ignore (diag (Some n) "not addo")
  in
  acom1 1L n;
  if !count < nterm then acom2 n tt (Array.sub terms 0 !count);
  n.ntype <- Some tt

and acom2 (n : node) (tt : typ) (trm : term array) =
  let nt = Array.length trm in
  let j = ref false in
  for i = 1 to nt - 1 do
    if trm.(i).mult <> 0L then match trm.(i).tnode with Some l -> j := true; acom l | None -> ()
  done;
  let c1 = trm.(0).mult in
  if not !j then (n.oldop <- n.op; n.op <- OCONST; n.vconst <- c1)
  else begin
    let e = tt.etype in
    if c1 <> 0L then begin
      let l = ref (node1 OCONST None None) in
      !l.ntype <- Some tt; !l.vconst <- c1;
      trm.(0).mult <- 1L;
      (try
         for i = 1 to nt - 1 do
           if trm.(i).mult = 1L then
             match trm.(i).tnode with
             | Some ({ op = OADDR; _ } as r) ->
                 r.ntype <- Some tt;
                 l := node1 OADD (Some r) (Some !l);
                 !l.ntype <- Some tt;
                 trm.(i).mult <- 0L;
                 raise Exit
             | _ -> ()
         done
       with Exit -> ());
      trm.(0).tnode <- Some !l
    end;
    (* the terms sorted as goken's qsort does, the ties on their places
     * (acomcmp1, acomcmp2) *)
    let abs x = if Int64.compare x 0L < 0 then Int64.neg x else x in
    let sort cmp = let rest = Array.sub trm 1 (nt - 1) in Array.stable_sort cmp rest; Array.blit rest 0 trm 1 (nt - 1) in
    sort (fun a b ->
      let c = Int64.compare (abs a.mult) (abs b.mult) in
      if c <> 0 then c
      else let sa = if Int64.compare a.mult 0L < 0 then 0 else 1 and sb = if Int64.compare b.mult 0L < 0 then 0 else 1 in
        if sb - sa <> 0 then sb - sa else compare b.id a.id);
    for i = nt - 1 downto 0 do
      let c1 = abs trm.(i).mult in
      if Int64.compare c1 1L > 0 then
        for k = i + 1 to nt - 1 do
          let c2 = abs trm.(k).mult in
          if Int64.compare c2 1L > 0 && Int64.rem c2 c1 = 0L then begin
            let r = ref (Option.get trm.(k).tnode) in
            if et !r <> e then r := acast tt !r;
            let c2 = Int64.div trm.(k).mult trm.(i).mult in
            if c2 <> 1L && c2 <> -1L then begin
              let k' = node OCONST None None in
              r := node1 OMUL (Some !r) (Some k');
              !r.ntype <- Some tt; k'.ntype <- Some tt; k'.vconst <- c2
            end;
            let l = ref (Option.get trm.(i).tnode) in
            if et !l <> e then l := acast tt !l;
            let s = node1 OADD (Some !l) (Some !r) in
            s.ntype <- Some tt;
            if c2 = -1L then s.op <- OSUB;
            trm.(i).tnode <- Some s;
            trm.(k).mult <- 0L
          end
        done
    done;
    sort (fun a b -> let c = Int64.compare a.mult b.mult in if c <> 0 then c else compare b.id a.id);
    let l = ref None and c2 = ref 0L in
    for i = nt - 1 downto 0 do
      let c1 = trm.(i).mult in
      if c1 <> 0L then begin
        let r = ref (Option.get trm.(i).tnode) in
        if et !r <> e || !r.op = OBIT then r := acast tt !r;
        let c1 =
          if c1 <> 1L && c1 <> -1L then begin
            let k = node OCONST None None in
            r := node1 OMUL (Some !r) (Some k);
            !r.ntype <- Some tt; k.ntype <- Some tt;
            if Int64.compare c1 0L < 0 then (k.vconst <- Int64.neg c1; -1L) else (k.vconst <- c1; 1L)
          end
          else c1
        in
        match !l with
        | None -> l := Some !r; c2 := c1
        | Some ll ->
            let x =
              if Int64.compare c1 0L < 0 then (if Int64.compare !c2 0L < 0 then node1 OADD (Some ll) (Some !r) else node1 OSUB (Some ll) (Some !r))
              else if Int64.compare !c2 0L < 0 then (c2 := 1L; node1 OSUB (Some !r) (Some ll))
              else node1 OADD (Some ll) (Some !r)
            in
            x.ntype <- Some tt;
            l := Some x
      end
    done;
    let l = Option.get !l in
    let l =
      if Int64.compare !c2 0L < 0 then begin
        let z = node1 OCONST None None in z.vconst <- 0L; z.ntype <- Some tt;
        let x = node1 OSUB (Some z) (Some l) in x.ntype <- Some tt; x
      end
      else l
    in
    copy_into n l
  end

(*****************************************************************************)
(* complex: all of it, for an expression (com.c) *)
(*****************************************************************************)

let complex (n : node option) =
  match n with
  | None -> ()
  | Some n ->
      nearln := n.lineno;
      if not (tcom n) then begin
        comma n;
        ccom (Some n);
        acom n;
        !xcom n
      end
