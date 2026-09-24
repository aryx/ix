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

(* a node of op on l and r, of type t, at the line diagnosed *)
let mkt op l r t = let n = node1 op l r in n.ntype <- t; n
let konst v t = mkt OCONST None None (Some t) |> fun c -> c.vconst <- v; c
let cast_to (x : node) t = mkt OCAST (Some x) None t

(* n made op on a copy of itself; the copy *)
let wrap (n : node) op = let c = dup n in n.op <- op; n.left <- Some c; n.right <- None; c

(*****************************************************************************)
(* Constants (sub.c's vconst, log2; scon.c's evconst) *)
(*****************************************************************************)

(* the value of a small integral constant, or -159 *)
let vconst (n : node option) =
  match n with
  | Some ({ op = OCONST; ntype = Some ty; _ } as n) ->
      if typefd ty.etype then
        if n.fconst > 100. || n.fconst < -100. then -159
        else let i = Float.to_int n.fconst in if Float.of_int i <> n.fconst then -159 else i
      else if typei ty.etype || ty.etype = Tind then
        let i = Int64.to_int32 n.vconst in if Int64.of_int32 i <> n.vconst then -159 else Int32.to_int i
      else -159
  | _ -> -159

let log2 (v : int64) = let rec go i = if i >= 64 then -1 else if Int64.shift_left 1L i = v then i else go (i + 1) in go 0
let vlog (n : node) = if n.op <> OCONST || typefd (et n) then -1 else log2 n.vconst

let int_ops = [ OADD, Int64.add; OSUB, Int64.sub; OMUL, Int64.mul; OLMUL, Int64.mul; ODIV, Int64.div; OLDIV, Int64.unsigned_div;
                OMOD, Int64.rem; OLMOD, Int64.unsigned_rem; OAND, Int64.logand; OOR, Int64.logor; OXOR, Int64.logxor;
                OLSHR, (fun a b -> Int64.shift_right_logical a (Int64.to_int b)); OASHR, (fun a b -> Int64.shift_right a (Int64.to_int b));
                OASHL, (fun a b -> Int64.shift_left a (Int64.to_int b)) ]
let float_ops = [ OADD, ( +. ); OSUB, ( -. ); OMUL, ( *. ); ODIV, ( /. ) ]

(* a relation, on floats or signed integers; the unsigned ones on
 * unsigned_compare *)
let relate o a b = match o with OLT -> a < b | OGT -> a > b | OLE -> a <= b | OGE -> a >= b | OEQ -> a = b | _ -> a <> b
let unsigned_rels = [ OLO, OLT; OHI, OGT; OLS, OLE; OHS, OGE ]

(* n of constants, a constant *)
let evconst (n : node) =
  match n.ntype with
  | None -> ()
  | Some ty ->
      let isf = typefd ty.etype and o = n.op in
      let lf () = (l n).fconst and rf () = (r n).fconst and lv () = (l n).vconst and rv () = (r n).vconst in
      let lfd () = typefd (et (l n)) in
      let bool b = Some (`V (if b then 1L else 0L)) in
      let truth x () = if lfd () then (l x).fconst <> 0. else (l x).vconst <> 0L in
      let res =
        match o with
        | ONEG -> Some (if isf then `F (-. lf ()) else `V (Int64.neg (lv ())))
        | OCOM -> Some (`V (Int64.lognot (lv ())))
        | OCAST when ty.etype = Tvoid -> None
        | OCAST -> Some (if isf then `F (if lfd () then lf () else Int64.to_float (lv ())) else if lfd () then `V (Int64.of_float (lf ())) else `V (convvtox (lv ()) ty.etype))
        | OCONST -> Some (if isf then `F n.fconst else `V n.vconst)
        | (ODIV | OLDIV | OMOD | OLMOD) when vconst n.right = 0 -> None
        | _ when isf && List.mem_assoc o float_ops -> Some (`F ((List.assoc o float_ops) (lf ()) (rf ())))
        | _ when List.mem_assoc o int_ops -> Some (`V ((List.assoc o int_ops) (lv ()) (rv ())))
        | _ when List.mem_assoc o unsigned_rels -> bool (relate (List.assoc o unsigned_rels) (Int64.unsigned_compare (lv ()) (rv ())) 0)
        | OLT | OGT | OLE | OGE | OEQ | ONE -> bool (if lfd () then relate o (lf ()) (rf ()) else relate o (lv ()) (rv ()))
        | ONOT -> bool (not (truth n ()))
        | OANDAND -> bool (truth n () && (if lfd () then rf () <> 0. else rv () <> 0L))
        | OOROR -> bool (truth n () || (if lfd () then rf () <> 0. else rv () <> 0L))
        | _ -> None
      in
      Option.iter (fun v ->
        (match v with
         | `F d -> if isf then n.fconst <- d else n.vconst <- convvtox (Int64.of_float d) ty.etype
         | `V v -> if isf then n.fconst <- Int64.to_float v else n.vconst <- convvtox v ty.etype);
        
        n.op <- OCONST) res

(*****************************************************************************)
(* Helpers of the typechecker (sub.c) *)
(*****************************************************************************)

let etype_of (t : typ option) = match t with Some t -> t.etype | None -> Txxx

(* a cast that makes no code: a same-size move (sub.c's nocast) *)
let nocast (t1 : typ option) (t2 : typ option) =
  b (etype_of t2) land (m ()).ncast (etype_of t1) <> 0

(* a cast that means nothing: small to large (sub.c's nilcast) *)
let nilcast (t1 : typ option) (t2 : typ option) =
  match t1, t2 with
  | Some a, Some b ->
      let e1 = a.etype and e2 = b.etype in
      e1 = e2 || ((typefd e1 && typefd e2 || typechlp e1 && typechlp e2) && ewidth e1 < ewidth e2)
  | _ -> false

(* the operator's table says t2 won't do with t1 *)
let stcompat (n : node) (t1 : typ option) (t2 : typ option) (ttab : etype -> int) =
  let i1 = etype_of t1 and i2 = etype_of t2 in
  let bb = b i2 in
  if bb land ttab i1 = 0 then true
  else (ttab == tasign && (bb = b Tstruct || bb = b Tunion) || n.op <> OCAST && bb = b Tind && i1 = Tind) && not (sametype t1 t2)

let tcompat n t1 t2 ttab =
  stcompat n t1 t2 ttab && diag (Some n) "incompatible types: \"%s\" and \"%s\" for op \"%s\"" (show_type t1) (show_type t2) (opname n.op)

let tlvalue (n : node) = n.addable = 0 && diag (Some n) "not an l-value"

let rec members (t : typ option) = match t with None -> [] | Some t -> t :: members t.down

(* a structure element by name, then in unnamed substructures *)
let rec dotsearch (s : sym) (tt : typ option) (n : node) : (typ * int) option =
  let all = members tt in
  let one = function [] -> None | [ x ] -> Some x | _ -> diag (Some n) "ambiguous structure element: %s" s.name in
  let unnamed_su t1 = t1.tsym = None && typesu t1.etype in
  match one (List.filter (fun t1 -> match t1.tsym with Some s1 -> s1 == s | None -> false) all) with
  | Some x -> Some (x, x.offset)
  | None -> (
      let bytype = if s.sclass = Ctypedef || s.sclass = Ctypestr then List.filter (fun t1 -> unnamed_su t1 && sametype s.typ (Some t1)) all else [] in
      match one bytype with
      | Some x -> Some (x, x.offset)
      | None -> one (List.filter_map (fun t1 -> if unnamed_su t1 then Option.map (fun (x, o) -> (x, o + t1.offset)) (dotsearch s t1.link n) else None) all))

(* n, an ODOT of tt at o, an addressable node or an address plus the
 * offset (sub.c's makedot) *)
let makedot (n : node) (tt : typ) o =
  n.addable <- (l n).addable;
  if n.addable = 0 then (n.right <- Some (konst (Int64.of_int o) (ty Tlong)); n.ntype <- Some tt)
  else begin
    (l n).ntype <- Some tt;
    if o = 0 then copy_into n (l n)
    else begin
      n.ntype <- Some tt;
      let pt = typ Tind (Some tt) in
      pt.width <- (ty Tind).width;
      let n1 = mkt OADD (Some (konst (Int64.of_int o) pt)) (Some (mkt OADDR n.left None (Some pt))) (Some pt) in
      n.op <- OIND; n.left <- Some n1; n.right <- None
    end
  end

(* where an unnamed substructure of lt, of type st, is *)
let rec dotoffset (st : typ) (lt : typ) (n : node) =
  let unnamed = List.filter (fun t -> t.tsym = None) (members lt.link) in
  let one l = match l with [] -> -1 | [ o ] -> o | _ -> diag (Some n) "ambiguous unnamed structure element" in
  let o = match st.tag with Some g -> one (List.filter_map (fun t -> match t.tag with Some g' when g' == g -> Some t.offset | _ -> None) unnamed) | None -> -1 in
  if o >= 0 then o
  else
    let o = one (List.filter_map (fun t -> if sametype (Some st) (Some t) then Some t.offset else None) unnamed) in
    if o >= 0 then o
    else one (List.filter_map (fun t -> if typesu t.etype then (let o = dotoffset st t n in if o >= 0 then Some (o + t.offset) else None) else None) unnamed)

(* a double's expression of float constants and floats, made float *)
let rec allfloat (n : node option) flag =
  match n with
  | None -> false
  | Some n when et n <> Tdouble -> true
  | Some n ->
      let ok =
        match n.op with
        | OCONST -> true
        | OADD | OSUB | OMUL | ODIV -> allfloat n.right flag && allfloat n.left flag
        | OCAST -> allfloat n.left flag
        | _ -> false
      in
      if ok && flag then n.ntype <- Some (ty Tfloat);
      ok

let typeext1 (st : typ option) (l : node) = match st with Some st when st.etype = Tfloat && allfloat (Some l) false -> ignore (allfloat (Some l) true) | _ -> ()

(* the extensions of an assignment (sub.c's typeext): 0 as a pointer,
 * a structure to its unnamed substructure *)
let typeext (st : typ option) (l : node) =
  match l.ntype, st with
  | Some lt, Some st ->
      if st.etype = Tind && vconst (Some l) = 0 then (l.ntype <- Some st; l.vconst <- 0L)
      else begin
        typeext1 (Some st) l;
        if typesu st.etype && typesu lt.etype then begin
          let o = dotoffset st lt l in
          if o >= 0 then (ignore (wrap l ODOT); makedot l st o)
        end
        else
          match st.link, lt.link with
          | Some sl, Some ll when st.etype = Tind && typesu sl.etype && lt.etype = Tind && typesu ll.etype ->
              let o = dotoffset sl ll l in
              if o >= 0 then begin
                l.ntype <- Some st;
                if o <> 0 then (ignore (wrap l OADD); l.right <- Some (konst (Int64.of_int o) st))
              end
          | _ -> ()
      end
  | _ -> ()

(* "the usual arithmetic conversions" (sub.c's arith): f, promoted *)
let arith (n : node) f =
  let t1 = (l n).ntype in
  let t2 = match n.right with None -> t1 | Some r -> r.ntype in
  let i = etype_of t1 and j = etype_of t2 in
  let k = arith_tab i j in
  if k = Tind then (if i = Tind then n.ntype <- t1 else if j = Tind then n.ntype <- t2)
  else n.ntype <- Some (ty (if f then promote k else k));
  let bad () = diag (Some n) "pointer addition not fully declared: %s" (show_type (link (t n)).link) in
  if n.op = OSUB && i = Tind && j = Tind then begin
    (* a difference of pointers: in elements *)
    let w = (link (t (r n))).width in
    if w < 1 || (t (l n)).link = None || (link (t (l n))).width < 1 then bad ();
    n.ntype <- Some (ty (if ewidth Tind <= ewidth Tlong then Tlong else Tvlong));
    if ewidth Tind > ewidth Tlong then (ignore (wrap n OCAST); n.ntype <- Some (ty Tlong));
    if w > 1 then begin
      ignore (wrap n ODIV);
      let c = konst (Int64.of_int w) (t n) in
      n.right <- Some c;
      let w = vlog c in
      if w >= 0 then (n.op <- OASHR; c.vconst <- Int64.of_int w)
    end
  end
  else begin
    (* a side to the result's type, an integer added to a pointer scaled *)
    let scaled (side : node) =
      let c = cast_to side n.ntype in
      if et n <> Tind then c
      else begin
        let lk = link (t n) in
        let w = if lk.width < 1 then (snap lk; if lk.width < 1 then bad () else lk.width) else lk.width in
        if w > 1 then mkt OMUL (Some c) (Some (konst (Int64.of_int w) (t n))) n.ntype else c
      end
    in
    if not (sametype n.ntype (l n).ntype) then n.left <- Some (scaled (l n));
    match n.right with Some rr when not (sametype n.ntype rr.ntype) -> n.right <- Some (scaled rr) | _ -> ()
  end

(* n may have side effects; ?: 's two sides, as C's falls into its list *)
let rec side (n : node option) =
  match n with
  | None -> false
  | Some n -> (
      match n.op with
      | OCAST | ONOT | OADDR | OIND -> side n.left
      | OCOND -> side n.left || side (Tree.r n).left || side (Tree.r n).right
      | OEQ | ONE | OLT | OGE | OGT | OLE | OADD | OSUB | OMUL | OLMUL | ODIV | OLDIV | OLSHR | OASHL | OASHR
      | OAND | OOR | OXOR | OMOD | OLMOD | OANDAND | OOROR | OCOMMA | ODOT -> side n.left || side n.right
      | OSIGN | OSIZE | OCONST | OSTRING | OLSTRING | ONAME -> false
      | _ -> true)

(* cast a constant down rather than a variable up: if(c == 'a')
 * (sub.c's relcon) *)
let relcon (l : node) (r : node) =
  if l.op = OCONST && r.op = OCAST && nilcast (Tree.l r).ntype r.ntype then
    let e = et r in
    if List.mem e [ Tchar; Tuchar; Tshort; Tushort ] && convvtox l.vconst e = l.vconst then (l.ntype <- (Tree.l r).ntype; copy_into r (Tree.l r))

(* OEQ ONE OLE OLS OLT OLO OGE OHS OGT OHI (sub.c's relindex, logrel, invrel, comrel) *)
let rels = [| OEQ; ONE; OLE; OLS; OLT; OLO; OGE; OHS; OGT; OHI |]
let relindex o = let rec go i = if rels.(i) = o then i else go (i + 1) in go 0
let relindex_opt o = if Array.mem o rels then Some (relindex o) else None
let logrel = [| OEQ; ONE; OLS; OLS; OLO; OLO; OHS; OHS; OHI; OHI |]
let invrel = [| OEQ; ONE; OGE; OHS; OGT; OHI; OLE; OLS; OLT; OLO |]
let comrel = [| ONE; OEQ; OGT; OHI; OGE; OHS; OLT; OLO; OLE; OLS |]

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

(* the operators' tables, and their unsigned forms *)
let op_table = function
  | OADD -> tadd | OSUB -> tsub | OMUL | OLMUL | ODIV | OLDIV -> tmul | OASADD | OASSUB -> tasadd
  | OASMUL | OASLMUL | OASDIV | OASLDIV -> tmul | _ -> tand
let unsigned_op o = match List.assoc_opt o [ ODIV, OLDIV; OMUL, OLMUL; OMOD, OLMOD; OASDIV, OASLDIV; OASMUL, OASLMUL; OASMOD, OASLMOD; OASHR, OLSHR; OASASHR, OASLSHR ] with Some u -> u | None -> o

exception Bad

let rec tcom n = tcomo n addrof

and tcomo (n : node) f : bool = try tcomo1 n f; false with Bad -> n.ntype <- None; true

and tcomo1 (n : node) f =
  let chk b = if b then raise Bad in
  n.addable <- 0;
  let l = n.left and r = n.right in
  let ll () = Option.get l and rr () = Option.get r in
  let both () = let o = tcom (ll ()) in chk (o || tcom (rr ())) in
  let lt () = (ll ()).ntype and rt () = (rr ()).ntype in
  let unsigned () = if typeu (et n) then n.op <- unsigned_op n.op in
  (match n.op with
   | ODOTDOT -> copy_into n (ll ()); if n.ntype = None then raise Bad
   | OCAST ->
       if n.ntype <> None then begin
         chk (if (t n).width = (ty Tlong).width then tcomo (ll ()) (addrof lor castof) else tcom (ll ()));
         chk (tcompat n (lt ()) n.ntype tcast)
       end
   | ORETURN ->
       Option.iter (fun l ->
         chk (tcom l);
         typeext n.ntype l;
         if not (tcompat n n.ntype l.ntype tasign || sametype n.ntype l.ntype) then n.left <- Some (cast_to l n.ntype)) l
   | OASI | OAS ->
       n.op <- OAS;
       both ();
       chk (tlvalue (ll ()));
       typeext (lt ()) (rr ());
       chk (tcompat n (lt ()) (rt ()) tasign);
       if not (sametype (lt ()) (rt ())) then n.right <- Some (cast_to (rr ()) (lt ()));
       n.ntype <- lt ()
   | OASADD | OASSUB | OASMUL | OASLMUL | OASDIV | OASLDIV | OASMOD | OASLMOD | OASOR | OASAND | OASXOR ->
       both ();
       chk (tlvalue (ll ()));
       if op_table n.op != tand then typeext1 (lt ()) (rr ());
       chk (tcompat n (lt ()) (rt ()) (op_table n.op));
       let tt = lt () in
       arith n false;
       while (Tree.l n).op = OCAST do n.left <- (Tree.l n).left done;
       (* x op= y in x's type, unless a float is added to an integer *)
       if not (sametype tt n.ntype) && not (not (typefd (Option.get tt).etype) && typefd (et n)) then (n.right <- Some (cast_to (Tree.r n) tt); n.ntype <- tt);
       unsigned ()
   | OASLSHR | OASASHR | OASASHL ->
       both ();
       chk (tlvalue (ll ()));
       chk (tcompat n (lt ()) (rt ()) tand);
       n.ntype <- lt ();
       n.right <- Some (cast_to (rr ()) (Some (ty Tint)));
       unsigned ()
   | OPREINC | OPREDEC | OPOSTINC | OPOSTDEC ->
       chk (tcom (ll ()));
       chk (tlvalue (ll ()));
       chk (tcompat n (lt ()) (Some (ty Tint)) tadd);
       n.ntype <- lt ();
       if et n = Tind then (let lk = link (t n) in if lk.width < 1 then (snap lk; if lk.width < 1 then ignore (diag (Some n) "inc/dec of a void pointer")))
   | OEQ | ONE | OLT | OGE | OGT | OLE ->
       both ();
       (* an equality extends both sides, an order only floats *)
       let ext = if n.op = OEQ || n.op = ONE then typeext else typeext1 in
       ext (lt ()) (rr ());
       ext (rt ()) (ll ());
       chk (tcompat n (lt ()) (rt ()) trel);
       arith n false;
       if typeu (et n) && n.op <> OEQ && n.op <> ONE then n.op <- logrel.(relindex n.op);
       n.ntype <- Some (ty Tint)
   | OCOND ->
       let rl = Tree.l (rr ()) and rr' = Tree.r (rr ()) in
       let o = tcom (ll ()) in
       let o = tcom rl || o in
       chk (tcom rr' || o);
       if et rr' = Tind && vconst (Some rl) = 0 then (rl.ntype <- rr'.ntype; rl.vconst <- 0L);
       if et rl = Tind && vconst (Some rr') = 0 then (rr'.ntype <- rl.ntype; rr'.vconst <- 0L);
       if sametype rr'.ntype rl.ntype then (rr ()).ntype <- rr'.ntype
       else (chk (tcompat (rr ()) rl.ntype rr'.ntype trel); arith (rr ()) false);
       n.ntype <- (rr ()).ntype
   | OADD | OSUB | OMUL | OLMUL | ODIV | OLDIV | OAND | OOR | OXOR | OMOD | OLMOD ->
       both ();
       chk (tcompat n (lt ()) (rt ()) (op_table n.op));
       arith n true;
       if n.op <> OADD && n.op <> OSUB then unsigned ()
   | OLSHR | OASHL | OASHR ->
       both ();
       chk (tcompat n (lt ()) (rt ()) tand);
       (* the left's type: the count an int *)
       n.right <- None;
       arith n true;
       n.right <- Some (cast_to (rr ()) (Some (ty Tint)));
       unsigned ()
   | OPOS | ONEG | OCOM ->
       (* +x as 0+x; where the machine can't, -x as 0-x, ~x as -1^x
        * (machcap looks at x's type: after x's) *)
       chk (tcom (ll ()));
       if n.op = OPOS || not ((m ()).machcap (Some n)) then begin
         let c = konst (if n.op = OCOM then -1L else 0L) (ty Tint) in
         let o = List.assoc n.op [ OPOS, OADD; ONEG, OSUB; OCOM, OXOR ] in
         n.op <- o; n.right <- l; n.left <- Some c;
         chk (tcom c);
         chk (tcompat n c.ntype (Tree.r n).ntype (if o = OXOR then tand else tsub))
       end;
       arith n true
   | ONOT ->
       chk (tcom (ll ()));
       chk (tcompat n None (lt ()) tnot);
       n.ntype <- Some (ty Tint)
   | OANDAND | OOROR ->
       both ();
       let a = tcompat n None (lt ()) tnot in
       chk (tcompat n None (rt ()) tnot || a);
       n.ntype <- Some (ty Tint)
   | OCOMMA -> both (); n.ntype <- rt ()
   | OSIGN -> diag (Some n) "signof is not in the subset"
   | OSIZE ->
       Option.iter (fun (l : node) -> if l.op <> OSTRING && l.op <> OLSTRING then chk (tcomo l 0); n.ntype <- l.ntype) l;
       if n.ntype = None then raise Bad;
       if (t n).width <= 0 then ignore (diag (Some n) "sizeof undefined type");
       if et n = Tfunc then ignore (diag (Some n) "sizeof function");
       n.op <- OCONST; n.left <- None; n.right <- None;
       n.vconst <- convvtox (Int64.of_int (t n).width) Tint;
       n.ntype <- Some (ty Tint)
   | OFUNC ->
       chk (tcomo (ll ()) 0);
       (* a pointer to a function called through it *)
       let ft = t (ll ()) in
       if ft.etype = Tind && (link ft).etype = Tfunc then n.left <- Some (mkt OIND l None ft.link);
       chk (tcompat n None (Tree.l n).ntype tfunct);
       chk (tcoma (Tree.l n) r (t (Tree.l n)).down true);
       n.ntype <- (t (Tree.l n)).link
   | ONAME ->
       if n.ntype = None then ignore (diag (Some n) "name not declared: %s" (fnname (Some n)));
       if et n = Tenum then begin
         n.op <- OCONST;
         n.ntype <- (sym n).tenum;
         if typefd (et n) then n.fconst <- (sym n).sfconst else n.vconst <- (sym n).svconst
       end
       else if n.nclass = Cexreg then ignore (diag (Some n) "extern register is not in the subset")
       else n.addable <- 1
   | OSTRING | OLSTRING ->
       (* in .string: runes 4 bytes aligned, as pswt.c's outlstring;
        * a string of other than chars, aligned on 4 *)
       let o = !outstring "" 0 in
       if n.op = OLSTRING then (if o land 3 <> 0 then ignore (!outstring "" (4 - (o land 3))))
       else if link (t n) != ty Tchar then (let o = ref o in while !o land 3 <> 0 do ignore (!outstring "\000" 1); o := !outstring "" 0 done);
       n.op <- ONAME;
       n.xoffset <- !outstring n.cstring (t n).width;
       n.addable <- 1
   | OCONST -> ()
   | ODOT ->
       chk (tcom (ll ()));
       chk (tcompat n None (lt ()) tdots);
       (match dotsearch (sym n) (t (ll ())).link n with
        | None -> ignore (diag (Some n) "not a member of struct/union: %s" (fnname (Some n)))
        | Some (tt, o) -> makedot n tt o)
   | OADDR ->
       chk (tcomo (ll ()) addrop);
       chk (tlvalue (ll ()));
       if (ll ()).op = OREGISTER then ignore (diag (Some n) "address of a register");
       n.ntype <- Some (typ Tind (lt ()));
       (t n).width <- (ty Tind).width
   | OIND ->
       chk (tcom (ll ()));
       chk (tcompat n None (lt ()) tindir);
       n.ntype <- (t (ll ())).link;
       n.addable <- 1
   | OSTRUCT -> diag (Some n) "structure constructors are not in the subset"
   | o -> diag (Some n) "unknown op in type complex: %s" (opname o));
  let tt = match n.ntype with Some tt -> tt | None -> raise Bad in
  if tt.width < 0 then (snap tt; if tt.width < 0 then ignore (diag (Some n) "structure not fully declared"));
  if typeaf tt.etype && f land addrof <> 0 then begin
    (* an array or a function, used: its address *)
    chk (tlvalue n);
    let l1 = wrap n OADDR in
    if (t l1).etype = Tarray then l1.ntype <- (t l1).link;
    n.addable <- 0;
    n.ntype <- Some (typ Tind l1.ntype);
    (t n).width <- (ty Tind).width
  end

(* the arguments against the prototype, promoted (com.c's tcoma) *)
and tcoma (l : node) (n : node option) (tt : typ option) f : bool =
  let tt = match tt with Some x when x.etype = Told || x.etype = Tdot -> None | x -> x in
  let void = Some (ty Tvoid) in
  match n with
  | None -> tt <> None && not (sametype tt void) && diag (Some l) "not enough function arguments: %s" (fnname (Some l))
  | Some ({ op = OLIST; _ } as n) ->
      let o = tcoma l n.left tt false in
      let tt = Option.map (fun (x : typ) -> match x.down with None -> ty Tvoid | Some d -> d) tt in
      o || tcoma l n.right tt true
  | Some n ->
      if f && tt <> None then ignore (tcoma l None (Option.get tt).down false);
      if tcom n || tcompat n None n.ntype targ then true
      else if sametype tt void then diag (Some n) "too many function arguments: %s" (fnname (Some l))
      else begin
        (* char and short to int, keeping the sign; an unprototyped float a double *)
        let promote e = match e with Tchar | Tshort -> Some (ty Tint) | Tuchar | Tushort -> Some (ty Tuint) | _ -> None in
        let tt =
          match tt with
          | Some x ->
              typeext tt n;
              if stcompat (node OPROTO None None) tt n.ntype tasign then
                ignore (diag (Some l) "argument prototype mismatch \"%s\" for \"%s\": %s" (show_type n.ntype) (show_type tt) (fnname (Some l)));
              (match promote x.etype with Some p -> Some p | None -> tt)
          | None -> (match promote (et n) with Some p -> Some p | None -> if et n = Tfloat then Some (ty Tdouble) else None)
        in
        (match tt with Some _ when not (sametype tt n.ntype) -> ignore (wrap n OCAST); n.ntype <- tt; n.addable <- 0 | _ -> ());
        false
      end

(*****************************************************************************)
(* Commas out of expressions (com.c's comma) *)
(*****************************************************************************)

(* the left sides of the commas in n, taken out in acc, the rest *)
let rec commas (acc : node list ref) (n : node option) : node option =
  match n with
  | None -> None
  | Some n -> (
      match n.op with
      | OREGISTER | OINDREG | OCONST | ONAME | OSTRING -> Some n
      (* claude: the left's commas first: a let, as :: evaluates !acc first *)
      | OCOMMA -> let x = Option.get (commas acc n.left) in acc := x :: !acc; commas acc n.right
      | OFUNC -> n.left <- commas acc n.left; n.right <- comargs acc n.right; Some n
      | OCOND -> n.left <- commas acc n.left; comma (Option.get (Tree.r n).left); comma (Option.get (Tree.r n).right); Some n
      | OANDAND | OOROR -> n.left <- commas acc n.left; comma (Option.get n.right); Some n
      | ORETURN -> Option.iter comma n.left; Some n
      | _ -> n.left <- commas acc n.left; if n.right <> None then n.right <- commas acc n.right; Some n)

and comargs acc (n : node option) =
  (match n with Some ({ op = OLIST; _ } as n) -> n.left <- comargs acc n.left; n.right <- comargs acc n.right | _ -> ());
  commas acc n

(* n with the commas first: (a, b) + c as a, (b + c) *)
and comma (n : node) =
  let acc = ref [] in
  let nn = Option.get (commas acc (Some n)) in
  if !acc <> [] then begin
    if nn != n then copy_into n nn;
    List.iter (fun (lhs : node) -> let n1 = wrap n OCOMMA in n.ntype <- n1.ntype; n.left <- Some lhs; n.right <- Some n1; n.lineno <- lhs.lineno) !acc
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
      let isconst = function None -> true | Some (x : node) -> x.op = OCONST in
      let common () = if isconst l && isconst r then evconst n in
      let becomes (x : node) = copy_into n x in
      (* (x op c1) op c2 as x op (c1 op c2), to fold the constants *)
      let commute () =
        let pull (a : node option) (b : node option) set_b =
          match b with
          | Some ({ op = bo; _ } as b') when bo = n.op && (Option.get a).op = OCONST ->
              if (Tree.l b').op = OCONST then (set_b b'.right; b'.right <- a; true)
              else if (Tree.r b').op = OCONST then (set_b b'.left; b'.left <- a; true)
              else false
          | _ -> false
        in
        if pull r l (fun x -> n.right <- x) || pull l r (fun x -> n.left <- x) then ccom (Some n) else common ()
      in
      let zero x = vconst x = 0 in
      match n.op with
      | OAS | OASXOR | OASAND | OASOR | OASMOD | OASLMOD | OASLSHR | OASASHR | OASASHL | OASDIV | OASLDIV | OASMUL
      | OASLMUL | OASSUB | OASADD -> ccom l; ccom r
      | OCAST ->
          ccom l;
          if not ((ll ()).op = OCONST && (evconst n; n.op = OCONST)) then
            if nocast (ll ()).ntype n.ntype && (not (typefd (et (ll ()))) || typeu (et (ll ())) && typeu (et n)) then
              ((ll ()).ntype <- n.ntype; becomes (ll ()))
      | OCOND -> ccom l; ccom r; if (ll ()).op = OCONST then becomes (if zero l then Tree.r (rr ()) else Tree.l (rr ()))
      | OREGISTER | OINDREG | OCONST | ONAME -> ()
      | OADDR | OIND ->
          ccom l;
          (* &*x and *&x as x *)
          if (ll ()).op = (if n.op = OADDR then OIND else OADDR) then ((Tree.l (ll ())).ntype <- n.ntype; becomes (Tree.l (ll ()))) else common ()
      | OEQ | ONE | OLE | OGE | OLT | OGT | OLS | OHS | OLO | OHI -> ccom l; ccom r; relcon (ll ()) (rr ()); relcon (rr ()) (ll ()); common ()
      | OASHR | OASHL | OLSHR ->
          ccom l;
          if zero l && not (side r) then becomes (ll ()) else (ccom r; if zero r then becomes (ll ()) else common ())
      | OMUL | OLMUL ->
          ccom l;
          if zero l && not (side r) then becomes (ll ())
          else if vconst l = 1 then (becomes (rr ()); ccom (Some n))
          else (ccom r; if zero r && not (side l) then becomes (rr ()) else if vconst r = 1 then becomes (ll ()) else common ())
      | ODIV | OLDIV ->
          ccom l;
          if zero l && not (side r) then becomes (ll ())
          else (ccom r; if zero r then ignore (diag (Some n) "divide check") else if vconst r = 1 then becomes (ll ()) else common ())
      | OSUB ->
          ccom r;
          if (rr ()).op = OCONST then begin
            (* x - c as x + -c *)
            n.op <- OADD;
            if typefd (et (rr ())) then (rr ()).fconst <- -. (rr ()).fconst else (rr ()).vconst <- Int64.neg (rr ()).vconst;
            ccom (Some n)
          end
          else (ccom l; common ())
      | OXOR | OOR | OADD ->
          ccom l;
          if zero l then (becomes (rr ()); ccom (Some n)) else (ccom r; if zero r then becomes (ll ()) else commute ())
      | OAND ->
          ccom l; ccom r;
          if zero l && not (side r) then becomes (ll ()) else if zero r && not (side l) then becomes (rr ()) else commute ()
      | OANDAND -> ccom l; if zero l then becomes (ll ()) else (ccom r; common ())
      | OOROR ->
          ccom l;
          if (ll ()).op = OCONST && (ll ()).vconst <> 0L then (becomes (ll ()); n.vconst <- 1L) else (ccom r; common ())
      | _ -> ccom l; ccom r; common ()

(*****************************************************************************)
(* Sums of terms, regrouped (scon.c's acom) *)
(*****************************************************************************)

let nterm = 10

(* an addition's operator: its terms are regrouped *)
let addo (n : node option) =
  match n with
  | Some n when not (typefd (et n)) && (not (typev (et n)) || ewidth Tvlong = ewidth Tind) -> (
      match n.op with
      | OCAST -> nilcast (l n).ntype n.ntype
      | ONEG | OADD | OSUB -> true
      | OMUL -> (l n).op = OCONST || (r n).op = OCONST
      | _ -> false)
  | _ -> false

let acast (tt : typ) (n : node) =
  if et n = tt.etype then n
  else begin
    let c = cast_to n (Some tt) in
    if nocast (l c).ntype (Some tt) then (copy_into c (l c); c.ntype <- Some tt);
    c
  end

type term = { mutable mult : int64; mutable tnode : node option }

let rec acom (n : node) =
  match n.op with
  | ONAME | OCONST | OSTRING | OINDREG | OREGISTER -> ()
  | ONEG -> if addo (Some n) && addo n.left then acom0 n else acom (l n)
  | OADD | OSUB | OMUL -> if addo (Some n) && (addo n.right || addo n.left) then acom0 n else (acom (l n); acom (r n))
  | _ -> Option.iter acom n.left; Option.iter acom n.right

(* the terms busted out, then put back together *)
and acom0 (n : node) =
  let tt = t n in
  let terms = Array.init nterm (fun _ -> { mult = 0L; tnode = None }) in
  let count = ref 1 in
  let rec acom1 v (n : node) =
    if v <> 0L && !count < nterm then
      match n.op with
      | _ when not (addo (Some n)) ->
          if n.op = OCONST && not (typefd (et n)) then terms.(0).mult <- Int64.add terms.(0).mult (Int64.mul v n.vconst)
          else (terms.(!count).mult <- v; terms.(!count).tnode <- Some n; incr count)
      | OCAST -> acom1 v (l n)
      | ONEG -> acom1 (Int64.neg v) (l n)
      | OADD -> acom1 v (l n); acom1 v (r n)
      | OSUB -> acom1 v (l n); acom1 (Int64.neg v) (r n)
      | _ (* OMUL *) -> if (l n).op = OCONST then acom1 (Int64.mul v (l n).vconst) (r n) else acom1 (Int64.mul v (r n).vconst) (l n)
  in
  acom1 1L n;
  if !count < nterm then acom2 n tt (Array.sub terms 0 !count);
  n.ntype <- Some tt

and acom2 (n : node) (tt : typ) (trm : term array) =
  let nt = Array.length trm in
  let j = ref false in
  for i = 1 to nt - 1 do if trm.(i).mult <> 0L then Option.iter (fun l -> j := true; acom l) trm.(i).tnode done;
  let c1 = trm.(0).mult in
  if not !j then (n.op <- OCONST; n.vconst <- c1)
  else begin
    let e = tt.etype in
    let neg x = Int64.compare x 0L < 0 in
    let abs x = if neg x then Int64.neg x else x in
    let times (r : node) c = mkt OMUL (Some r) (Some (konst c tt)) (Some tt) in
    (* the constant, with a term that is an address *)
    if c1 <> 0L then begin
      let l = ref (konst c1 tt) in
      trm.(0).mult <- 1L;
      (match List.find_opt (fun i -> trm.(i).mult = 1L && (match trm.(i).tnode with Some { op = OADDR; _ } -> true | _ -> false)) (List.init (nt - 1) succ) with
       | Some i ->
           let r = Option.get trm.(i).tnode in
           r.ntype <- Some tt;
           l := mkt OADD (Some r) (Some !l) (Some tt);
           trm.(i).mult <- 0L
       | None -> ());
      trm.(0).tnode <- Some !l
    end;
    (* the terms sorted as 5c's qsort (glibc's merge sort): acomcmp1 and
     * acomcmp2 break ties on the terms' addresses, and a merge that
     * takes the right on ties puts equal terms in reverse order, each
     * time *)
    let sort cmp =
      let rest = Array.init (nt - 1) (fun i -> trm.(nt - 1 - i)) in
      Array.stable_sort cmp rest;
      Array.blit rest 0 trm 1 (nt - 1)
    in
    sort (fun a b -> let c = Int64.compare (abs a.mult) (abs b.mult) in if c <> 0 then c else Bool.to_int (neg a.mult) - Bool.to_int (neg b.mult));
    (* factored: c1*i + c1*c2*j as c1*(i + c2*j) *)
    for i = nt - 1 downto 0 do
      let c1 = abs trm.(i).mult in
      if Int64.compare c1 1L > 0 then
        for k = i + 1 to nt - 1 do
          let c2 = abs trm.(k).mult in
          if Int64.compare c2 1L > 0 && Int64.rem c2 c1 = 0L then begin
            let r = acast tt (Option.get trm.(k).tnode) in
            let c2 = Int64.div trm.(k).mult trm.(i).mult in
            let r = if c2 <> 1L && c2 <> -1L then times r c2 else r in
            let s = mkt (if c2 = -1L then OSUB else OADD) (Some (acast tt (Option.get trm.(i).tnode))) (Some r) (Some tt) in
            trm.(i).tnode <- Some s;
            trm.(k).mult <- 0L
          end
        done
    done;
    sort (fun a b -> Int64.compare a.mult b.mult);
    (* all of it back together, the signs kept to the last *)
    let l = ref None and c2 = ref 0L in
    for i = nt - 1 downto 0 do
      let c1 = trm.(i).mult in
      if c1 <> 0L then begin
        let r = if et (Option.get trm.(i).tnode) <> e then acast tt (Option.get trm.(i).tnode) else Option.get trm.(i).tnode in
        let r, c1 = if c1 <> 1L && c1 <> -1L then times r (abs c1), (if neg c1 then -1L else 1L) else r, c1 in
        match !l with
        | None -> l := Some r; c2 := c1
        | Some ll ->
            let x =
              if neg c1 then mkt (if neg !c2 then OADD else OSUB) (Some ll) (Some r) (Some tt)
              else if neg !c2 then (c2 := 1L; mkt OSUB (Some r) (Some ll) (Some tt))
              else mkt OADD (Some ll) (Some r) (Some tt)
            in
            l := Some x
      end
    done;
    let l = Option.get !l in
    copy_into n (if neg !c2 then mkt OSUB (Some (konst 0L tt)) (Some l) (Some tt) else l)
  end

(*****************************************************************************)
(* complex: all of it, for an expression (com.c) *)
(*****************************************************************************)

let complex (n : node option) =
  Option.iter (fun n ->
    nearln := n.lineno;
    if not (tcom n) then (comma n; ccom (Some n); acom n; !xcom n)) n
