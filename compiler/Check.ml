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
let xcom : (expr -> expr) ref = ref Fun.id

(* a node of type t, at the line diagnosed *)
let mkt t e = mk ~t ~line:!nearln e
let konst v t = mkt t (Const v)
let cast_to (x : expr) t = mkt t (Unary (Cast, x))

(*****************************************************************************)
(* Constants (sub.c's vconst, log2; scon.c's evconst) *)
(*****************************************************************************)

(* the value of a small integral constant, or -159 *)
let vconst (n : expr) =
  match n.e with
  | Fconst f when typefd (et n) -> if f > 100. || f < -100. then -159 else let i = Float.to_int f in if Float.of_int i <> f then -159 else i
  | Const v when typei (et n) || et n = Tind -> let i = Int64.to_int32 v in if Int64.of_int32 i <> v then -159 else Int32.to_int i
  | _ -> -159

let log2 (v : int64) = let rec go i = if i >= 64 then -1 else if Int64.shift_left 1L i = v then i else go (i + 1) in go 0
let vlog (n : expr) = match n.e with Const v when not (typefd (et n)) -> log2 v | _ -> -1

let int_ops = [ Add, Int64.add; Sub, Int64.sub; Mul, Int64.mul; Lmul, Int64.mul; Div, Int64.div; Ldiv, Int64.unsigned_div;
                Mod, Int64.rem; Lmod, Int64.unsigned_rem; And, Int64.logand; Or, Int64.logor; Xor, Int64.logxor;
                Lshr, (fun a b -> Int64.shift_right_logical a (Int64.to_int b)); Ashr, (fun a b -> Int64.shift_right a (Int64.to_int b));
                Ashl, (fun a b -> Int64.shift_left a (Int64.to_int b)) ]
let float_ops = [ Add, ( +. ); Sub, ( -. ); Mul, ( *. ); Div, ( /. ) ]

(* a relation, on floats or signed integers; the unsigned ones on
 * unsigned_compare *)
let relate o a b = match o with Lt -> a < b | Gt -> a > b | Le -> a <= b | Ge -> a >= b | Eq -> a = b | _ -> a <> b
let unsigned_rels = [ Lo, Lt; Hi, Gt; Ls, Le; Hs, Ge ]

let fval (x : expr) = match x.e with Fconst f -> f | _ -> 0.
let ival (x : expr) = match x.e with Const v -> v | _ -> 0L

(* n of constants, a constant; or n *)
let evconst (n : expr) =
  let isf = typefd (et n) in
  let l, r = match n.e with Unary (_, a) -> a, a | Binary (_, a, b) -> a, b | _ -> n, n in
  let lf = fval l and rf = fval r and lv = ival l and rv = ival r in
  let lfd = typefd (et l) in
  let bool b = Some (`V (if b then 1L else 0L)) in
  let truth = if lfd then lf <> 0. else lv <> 0L in
  let res =
    match n.e with
    | Unary (Neg, _) -> Some (if isf then `F (-. lf) else `V (Int64.neg lv))
    | Unary (Com, _) -> Some (`V (Int64.lognot lv))
    | Unary (Cast, _) when et n = Tvoid -> None
    | Unary (Cast, _) -> Some (if isf then `F (if lfd then lf else Int64.to_float lv) else if lfd then `V (Int64.of_float lf) else `V (convvtox lv (et n)))
    | Const v -> Some (`V v)
    | Fconst f -> Some (`F f)
    | Binary ((Div | Ldiv | Mod | Lmod), _, b) when vconst b = 0 -> None
    | Binary (o, _, _) when isf && List.mem_assoc o float_ops -> Some (`F ((List.assoc o float_ops) lf rf))
    | Binary (o, _, _) when List.mem_assoc o int_ops -> Some (`V ((List.assoc o int_ops) lv rv))
    | Binary (o, _, _) when List.mem_assoc o unsigned_rels -> bool (relate (List.assoc o unsigned_rels) (Int64.unsigned_compare lv rv) 0)
    | Binary ((Lt | Gt | Le | Ge | Eq | Ne) as o, _, _) -> bool (if lfd then relate o lf rf else relate o lv rv)
    | Unary (Not, _) -> bool (not truth)
    | Binary (Andand, _, _) -> bool (truth && (if lfd then rf <> 0. else rv <> 0L))
    | Binary (Oror, _, _) -> bool (truth || (if lfd then rf <> 0. else rv <> 0L))
    | _ -> None
  in
  match res with
  | None -> n
  | Some (`F d) -> { n with e = (if isf then Fconst d else Const (convvtox (Int64.of_float d) (et n))) }
  | Some (`V v) -> { n with e = (if isf then Fconst (Int64.to_float v) else Const (convvtox v (et n))) }

(*****************************************************************************)
(* Helpers of the typechecker (sub.c) *)
(*****************************************************************************)

(* a cast that makes no code: a same-size move (sub.c's nocast) *)
let nocast (t1 : typ) (t2 : typ) = ncast t1.etype t2.etype

(* a cast that means nothing: small to large (sub.c's nilcast) *)
let nilcast (a : typ) (b : typ) =
  let e1 = a.etype and e2 = b.etype in
  e1 = e2 || ((typefd e1 && typefd e2 || typechlp e1 && typechlp e2) && ewidth e1 < ewidth e2)

(* the operator's table says t2 won't do with t1 *)
let stcompat ?(cast = false) (t1 : typ) (t2 : typ) ttab =
  let i1 = t1.etype and i2 = t2.etype in
  not (ttab i1 i2) || (ttab == tasign && typesu i2 || not cast && i2 = Tind && i1 = Tind) && not (same t1 t2)

let op_name (n : expr) =
  match n.e with
  | Unary (o, _) -> unop_name o
  | Binary (o, _, _) -> binop_name o
  | Assign (o, _, _) -> "AS" ^ (match o with Some o -> binop_name o | None -> "")
  | Call _ -> "FUNC"
  | Elem _ | Dot _ -> "DOT"
  | Cond _ -> "COND"
  | _ -> "?"

let tcompat (n : expr) t1 t2 ttab =
  let cast = match n.e with Unary (Cast, _) -> true | _ -> false in
  if stcompat ~cast t1 t2 ttab then
    ignore (diag (Some n) "incompatible types: \"%s\" and \"%s\" for op \"%s\"" (show_type (Some t1)) (show_type (Some t2)) (op_name n))

let lvalue (n : expr) = match n.e with Name _ | Unary (Ind, _) -> true | _ -> false
let tlvalue (n : expr) = if not (lvalue n) then ignore (diag (Some n) "not an l-value")

let rec members (t : typ option) = match t with None -> [] | Some t -> t :: members t.down

(* a structure element by name, then in unnamed substructures *)
let rec dotsearch (s : sym) (tt : typ option) (n : expr) : (typ * int) option =
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

(* the member of l, of type tt at o: l itself, an indirection through
 * its address plus o, or a Dot when l is no l-value (sub.c's makedot) *)
let makedot (n : expr) (l : expr) (tt : typ) o =
  if not (lvalue l) then { n with e = Dot (l, o); t = tt }
  else begin
    let l = { l with t = tt } in
    if o = 0 then l
    else begin
      let pt = typ Tind (Some tt) in
      pt.width <- (ty Tind).width;
      { n with e = Unary (Ind, mkt pt (Binary (Add, konst (Int64.of_int o) pt, mkt pt (Unary (Addr, l))))); t = tt }
    end
  end

(* where an unnamed substructure of lt, of type st, is *)
let rec dotoffset (st : typ) (lt : typ) (n : expr) =
  let unnamed = List.filter (fun t -> t.tsym = None) (members lt.link) in
  let one l = match l with [] -> -1 | [ o ] -> o | _ -> diag (Some n) "ambiguous unnamed structure element" in
  let o = match st.tag with Some g -> one (List.filter_map (fun t -> match t.tag with Some g' when g' == g -> Some t.offset | _ -> None) unnamed) | None -> -1 in
  if o >= 0 then o
  else
    let o = one (List.filter_map (fun t -> if same st t then Some t.offset else None) unnamed) in
    if o >= 0 then o
    else one (List.filter_map (fun t -> if typesu t.etype then (let o = dotoffset st t n in if o >= 0 then Some (o + t.offset) else None) else None) unnamed)

(* a double's expression of float constants and floats; made float *)
let rec allfloat (n : expr) =
  et n <> Tdouble
  || (match n.e with
      | Const _ | Fconst _ -> true
      | Binary ((Add | Sub | Mul | Div), a, b) -> allfloat b && allfloat a
      | Unary (Cast, a) -> allfloat a
      | _ -> false)

let rec tofloat (n : expr) =
  if et n <> Tdouble then n
  else
    let e = match n.e with Binary (o, a, b) -> Binary (o, tofloat a, tofloat b) | Unary (Cast, a) -> Unary (Cast, tofloat a) | e -> e in
    { n with e; t = ty Tfloat }

let typeext1 (st : typ) (l : expr) = if st.etype = Tfloat && allfloat l then tofloat l else l

(* the extensions of an assignment (sub.c's typeext): 0 as a pointer,
 * a structure to its unnamed substructure *)
let typeext (st : typ) (l : expr) =
  let lt = l.t in
  if st.etype = Tind && vconst l = 0 then { l with t = st; e = Const 0L }
  else begin
    let l = typeext1 st l in
    if typesu st.etype && typesu lt.etype then begin
      let o = dotoffset st lt l in
      if o >= 0 then makedot l l st o else l
    end
    else
      match st.link, lt.link with
      | Some sl, Some ll when st.etype = Tind && typesu sl.etype && lt.etype = Tind && typesu ll.etype ->
          let o = dotoffset sl ll l in
          if o < 0 then l
          else if o = 0 then { l with t = st }
          else { l with e = Binary (Add, { l with t = st }, konst (Int64.of_int o) st); t = st }
      | _ -> l
  end

(* "the usual arithmetic conversions" (sub.c's arith): the type of t1
 * op t2, promoted if f, and the conversion of a side to it, an integer
 * added to a pointer scaled *)
let arith_type (n : expr) (t1 : typ) (t2 : typ) f =
  let i = t1.etype and j = t2.etype in
  let t = match arith_tab i j with Tind -> if i = Tind then t1 else t2 | k -> ty (if f then promote k else k) in
  let bad () = diag (Some n) "pointer addition not fully declared: %s" (show_type (link t).link) in
  let scaled (side : expr) =
    if same t side.t then side
    else begin
      let c = cast_to side t in
      if t.etype <> Tind then c
      else begin
        let lk = link t in
        let w = if lk.width < 1 then (snap lk; if lk.width < 1 then bad () else lk.width) else lk.width in
        if w > 1 then mkt t (Binary (Mul, c, konst (Int64.of_int w) t)) else c
      end
    end
  in
  t, scaled

(* l op r's type, and l and r converted to it; a unary operator's *)
let arith n (l : expr) (r : expr) f = let t, scaled = arith_type n l.t r.t f in let l = scaled l in t, l, scaled r
let arith1 n (l : expr) f = let t, scaled = arith_type n l.t l.t f in t, scaled l

(* a difference of pointers, in elements *)
let ptrdiff (n : expr) (l : expr) (r : expr) =
  let w = (link r.t).width in
  if w < 1 || l.t.link = None || (link l.t).width < 1 then ignore (diag (Some n) "pointer addition not fully declared: %s" (show_type (link l.t).link));
  let d = { n with e = Binary (Sub, l, r); t = ty (if ewidth Tind <= ewidth Tlong then Tlong else Tvlong) } in
  let d = if ewidth Tind > ewidth Tlong then { d with e = Unary (Cast, d); t = ty Tlong } else d in
  if w <= 1 then d
  else
    let c = konst (Int64.of_int w) d.t in
    match vlog c with
    | k when k >= 0 -> { d with e = Binary (Ashr, d, { c with e = Const (Int64.of_int k) }) }
    | _ -> { d with e = Binary (Div, d, c) }

(* n may have side effects; ?: 's two sides, as C's falls into its list *)
let rec side (n : expr) =
  match n.e with
  | Unary ((Cast | Not | Addr | Ind), a) | Dot (a, _) -> side a
  | Cond (c, a, b) -> side c || side a || side b
  | Binary (o, a, b) when not (List.mem o [ Lo; Ls; Hi; Hs ]) -> side a || side b
  | Sizeof _ | Sizeof_type _ | Const _ | Fconst _ | Str _ | Lstr _ | Name _ -> false
  | _ -> true

(* cast a constant down rather than a variable up: if(c == 'a')
 * (sub.c's relcon) *)
let relcon (l : expr) (r : expr) =
  match l.e, r.e with
  | Const v, Unary (Cast, x) when nilcast x.t r.t && List.mem (et r) [ Tchar; Tuchar; Tshort; Tushort ] && convvtox v (et r) = v -> { l with t = x.t }, x
  | _ -> l, r

(* a relation with its operands swapped, negated, unsigned *)
let invrel = function Lt -> Gt | Le -> Ge | Gt -> Lt | Ge -> Le | Lo -> Hi | Ls -> Hs | Hi -> Lo | Hs -> Ls | o -> o
let comrel = function Eq -> Ne | Ne -> Eq | Lt -> Ge | Le -> Gt | Gt -> Le | Ge -> Lt | Lo -> Hs | Ls -> Hi | Hi -> Ls | Hs -> Lo | o -> o
let logrel = function Le -> Ls | Lt -> Lo | Ge -> Hs | Gt -> Hi | o -> o

(*****************************************************************************)
(* Typechecking (com.c's tcom) *)
(*****************************************************************************)

(* the operators' tables, and their unsigned forms *)
let binop_table = function Add -> tadd | Sub -> tsub | Mul | Lmul | Div | Ldiv -> tmul | _ -> tand
let asop_table = function Add | Sub -> tasadd | Mul | Lmul | Div | Ldiv -> tmul | _ -> tand
let unsigned_op = function Div -> Ldiv | Mul -> Lmul | Mod -> Lmod | Ashr -> Lshr | o -> o

(* the typing of n, the conversions made nodes; ~addr: an array or a
 * function used is its address *)
let rec tcom ?(addr = true) (n : expr) : expr =
  let n = tcom1 n in
  let tt = n.t in
  if tt.width < 0 then (snap tt; if tt.width < 0 then ignore (diag (Some n) "structure not fully declared"));
  if typeaf tt.etype && addr then begin
    (* an array or a function, used: its address *)
    tlvalue n;
    let inner = if tt.etype = Tarray then { n with t = link tt } else n in
    let pt = typ Tind (Some inner.t) in
    pt.width <- (ty Tind).width;
    { n with e = Unary (Addr, inner); t = pt }
  end
  else n

and tcom1 (n : expr) : expr =
  let unsigned t o = if typeu t.etype then unsigned_op o else o in
  match n.e with
  | Typed x -> x
  | Unary (Cast, l) ->
      let l = tcom l in
      tcompat n l.t n.t tcast;
      { n with e = Unary (Cast, l) }
  | Assign (None, l, r) ->
      let l = tcom l in
      let r = tcom r in
      tlvalue l;
      let r = typeext l.t r in
      tcompat n l.t r.t tasign;
      { n with e = Assign (None, l, (if same l.t r.t then r else cast_to r l.t)); t = l.t }
  | Assign (Some ((Ashl | Ashr | Lshr) as o), l, r) ->
      let l = tcom l in
      let r = tcom r in
      tlvalue l;
      tcompat n l.t r.t tand;
      { n with e = Assign (Some (unsigned l.t o), l, cast_to r (ty Tint)); t = l.t }
  | Assign (Some o, l, r) ->
      let l = tcom l in
      let r = tcom r in
      tlvalue l;
      let r = if asop_table o != tand then typeext1 l.t r else r in
      tcompat n l.t r.t (asop_table o);
      let tt = l.t in
      let t, l', r = arith n l r false in
      let rec uncast (x : expr) = match x.e with Unary (Cast, a) -> uncast a | _ -> x in
      (* x op= y in x's type, unless a float is added to an integer *)
      let t, r = if not (same tt t) && not (not (typefd tt.etype) && typefd t.etype) then tt, cast_to r tt else t, r in
      { n with e = Assign (Some (unsigned t o), uncast l', r); t }
  | Unary ((Preinc | Predec | Postinc | Postdec) as o, l) ->
      let l = tcom l in
      tlvalue l;
      tcompat n l.t (ty Tint) tadd;
      if et l = Tind then (let lk = link l.t in if lk.width < 1 then (snap lk; if lk.width < 1 then ignore (diag (Some n) "inc/dec of a void pointer")));
      { n with e = Unary (o, l); t = l.t }
  | Binary ((Eq | Ne | Lt | Ge | Gt | Le) as o, l, r) ->
      let l = tcom l in
      let r = tcom r in
      (* an equality extends both sides, an order only floats *)
      let ext = if o = Eq || o = Ne then typeext else typeext1 in
      let r = ext l.t r in
      let l = ext r.t l in
      tcompat n l.t r.t trel;
      let t, l, r = arith n l r false in
      let o = if typeu t.etype && o <> Eq && o <> Ne then logrel o else o in
      { n with e = Binary (o, l, r); t = ty Tint }
  | Cond (c, a, b) ->
      let c = tcom c in
      let a = tcom a in
      let b = tcom b in
      let a = if et b = Tind && vconst a = 0 then { a with t = b.t; e = Const 0L } else a in
      let b = if et a = Tind && vconst b = 0 then { b with t = a.t; e = Const 0L } else b in
      if same b.t a.t then { n with e = Cond (c, a, b); t = b.t }
      else begin
        tcompat n a.t b.t trel;
        let t, a, b = arith n a b false in
        { n with e = Cond (c, a, b); t }
      end
  | Binary ((Add | Sub | Mul | Lmul | Div | Ldiv | And | Or | Xor | Mod | Lmod) as o, l, r) ->
      let l = tcom l in
      let r = tcom r in
      tcompat n l.t r.t (binop_table o);
      if o = Sub && et l = Tind && et r = Tind then ptrdiff n l r
      else begin
        let t, l, r = arith n l r true in
        { n with e = Binary ((if o <> Add && o <> Sub then unsigned t o else o), l, r); t }
      end
  | Binary ((Lshr | Ashl | Ashr) as o, l, r) ->
      let l = tcom l in
      let r = tcom r in
      tcompat n l.t r.t tand;
      (* the left's type: the count an int *)
      let t, l = arith1 n l true in
      { n with e = Binary (unsigned t o, l, cast_to r (ty Tint)); t }
  | Unary ((Pos | Neg | Com) as o, l) ->
      (* +x as 0+x; where the machine can't, -x as 0-x, ~x as -1^x
       * (machcap looks at x's type: after x's) *)
      let l = tcom l in
      if o = Pos || not ((m ()).machcap (Some { n with e = Unary (o, l) })) then begin
        let bo = match o with Pos -> Add | Neg -> Sub | _ -> Xor in
        let c = konst (if o = Com then -1L else 0L) (ty Tint) in
        let n = { n with e = Binary (bo, c, l) } in
        tcompat n c.t l.t (if bo = Xor then tand else tsub);
        let t, c, l = arith n c l true in
        { n with e = Binary (bo, c, l); t }
      end
      else
        let t, l = arith1 n l true in
        { n with e = Unary (o, l); t }
  | Unary (Not, l) ->
      let l = tcom l in
      tcompat n untyped l.t tnot;
      { n with e = Unary (Not, l); t = ty Tint }
  | Binary ((Andand | Oror) as o, l, r) ->
      let l = tcom l in
      let r = tcom r in
      tcompat n untyped l.t tnot;
      tcompat n untyped r.t tnot;
      { n with e = Binary (o, l, r); t = ty Tint }
  | Binary (Comma, l, r) ->
      let l = tcom l in
      let r = tcom r in
      { n with e = Binary (Comma, l, r); t = r.t }
  | Sizeof l -> sizeof n (match l.e with Str _ | Lstr _ -> l.t | _ -> (tcom ~addr:false l).t)
  | Sizeof_type t -> sizeof n t
  | Call (f, args) ->
      let f = tcom ~addr:false f in
      (* a pointer to a function called through it *)
      let f = if et f = Tind && (link f.t).etype = Tfunc then mkt (link f.t) (Unary (Ind, f)) else f in
      tcompat n untyped f.t tfunct;
      let args = tcoma f args f.t.down in
      { n with e = Call (f, args); t = link f.t }
  | Name (s, c, _) ->
      if n.t == untyped then ignore (diag (Some n) "name not declared: %s" s.name);
      if et n = Tenum then begin
        let t = Option.get s.tenum in
        { n with e = (if typefd t.etype then Fconst s.sfconst else Const s.svconst); t }
      end
      else if c = Cexreg then diag (Some n) "extern register is not in the subset"
      else n
  | Str str | Lstr str ->
      (* in .string: runes 4 bytes aligned, as pswt.c's outlstring;
       * a string of other than chars, aligned on 4 *)
      let o = !outstring "" 0 in
      (match n.e with
       | Lstr _ -> if o land 3 <> 0 then ignore (!outstring "" (4 - (o land 3)))
       | _ -> if link n.t != ty Tchar then (let o = ref o in while !o land 3 <> 0 do ignore (!outstring "\000" 1); o := !outstring "" 0 done));
      { n with e = Name (lookup ".string", Cstatic, !outstring str n.t.width) }
  | Const _ | Fconst _ | Reg _ | Indreg _ -> n
  | Elem (l, s) ->
      let l = tcom l in
      tcompat n untyped l.t tdots;
      (match dotsearch s l.t.link n with
       | None -> diag (Some n) "not a member of struct/union: %s" s.name
       | Some (tt, o) -> makedot n l tt o)
  | Unary (Addr, l) ->
      let l = tcom ~addr:false l in
      tlvalue l;
      (match l.e with Reg _ -> ignore (diag (Some n) "address of a register") | _ -> ());
      let t = typ Tind (Some l.t) in
      t.width <- (ty Tind).width;
      { n with e = Unary (Addr, l); t }
  | Unary (Ind, l) ->
      let l = tcom l in
      tcompat n untyped l.t tindir;
      { n with e = Unary (Ind, l); t = link l.t }
  (* made by the typing: typed already *)
  | Dot _ | Binary ((Lo | Ls | Hi | Hs), _, _) -> n

and sizeof (n : expr) (t : typ) =
  if t.width <= 0 then ignore (diag (Some n) "sizeof undefined type");
  if t.etype = Tfunc then ignore (diag (Some n) "sizeof function");
  { n with e = Const (convvtox (Int64.of_int t.width) Tint); t = ty Tint }

(* the arguments against the prototype, promoted (com.c's tcoma) *)
and tcoma (f : expr) (args : expr list) (tt : typ option) : expr list =
  let norm tt = match tt with Some x when x.etype = Told || x.etype = Tdot -> None | x -> x in
  let void = ty Tvoid in
  let enough tt =
    match norm tt with
    | Some x when not (same x void) -> ignore (diag (Some f) "not enough function arguments: %s" (fnname f))
    | _ -> ()
  in
  let rec go tt args =
    let tt = norm tt in
    match args with
    | [] -> enough tt; []
    | [ a ] -> Option.iter (fun (x : typ) -> enough x.down) tt; [ arg tt a ]
    | a :: rest ->
        let a = arg tt a in
        a :: go (Option.map (fun (x : typ) -> Option.value x.down ~default:void) tt) rest
  and arg tt (a : expr) =
    let a = tcom a in
    tcompat a untyped a.t targ;
    (match tt with Some x when same x void -> ignore (diag (Some a) "too many function arguments: %s" (fnname f)) | _ -> ());
    (* char and short to int, keeping the sign; an unprototyped float a double *)
    let promote e = match e with Tchar | Tshort -> Some (ty Tint) | Tuchar | Tushort -> Some (ty Tuint) | _ -> None in
    let a, target =
      match tt with
      | Some x ->
          let a = typeext x a in
          if stcompat x a.t tasign then
            ignore (diag (Some f) "argument prototype mismatch \"%s\" for \"%s\": %s" (show_type (Some a.t)) (show_type (Some x)) (fnname f));
          a, (match promote x.etype with Some p -> Some p | None -> Some x)
      | None -> a, (match promote (et a) with Some p -> Some p | None -> if et a = Tfloat then Some (ty Tdouble) else None)
    in
    match target with Some t when not (same t a.t) -> { a with e = Unary (Cast, a); t; addable = Anone } | _ -> a
  in
  go tt args

and fnname (f : expr) = match f.e with Name (s, _, _) -> s.name | _ -> "<indirect>"

(*****************************************************************************)
(* Commas out of expressions (com.c's comma) *)
(*****************************************************************************)

(* the left sides of the commas in n taken out, in acc (the last
 * first); what is left *)
let rec commas (acc : expr list ref) (n : expr) : expr =
  let c = commas acc in
  match n.e with
  | Reg _ | Indreg _ | Const _ | Fconst _ | Name _ | Str _ | Lstr _ -> n
  | Binary (Comma, a, b) -> let x = c a in acc := x :: !acc; c b
  | Call (f, args) -> let f = c f in { n with e = Call (f, map_lr c args) }
  | Cond (x, a, b) -> let x = c x in let a = comma a in { n with e = Cond (x, a, comma b) }
  | Binary ((Andand | Oror) as o, a, b) -> let a = c a in { n with e = Binary (o, a, comma b) }
  | Binary (o, a, b) -> let a = c a in { n with e = Binary (o, a, c b) }
  | Assign (o, a, b) -> let a = c a in { n with e = Assign (o, a, c b) }
  | Unary (o, a) -> { n with e = Unary (o, c a) }
  | Dot (a, o) -> { n with e = Dot (c a, o) }
  | _ -> n

(* n with the commas first: (a, b) + c as a, (b + c) *)
and comma (n : expr) : expr =
  let acc = ref [] in
  let nn = commas acc n in
  List.fold_left (fun cur (lhs : expr) -> { cur with e = Binary (Comma, lhs, cur); line = lhs.line }) nn !acc

(*****************************************************************************)
(* The general rewrite (com.c's ccom): no-op casts, zeros, constants *)
(*****************************************************************************)

let rec ccom (n : expr) : expr =
  let zero x = vconst x = 0 in
  let common (n : expr) =
    match n.e with
    | Unary (_, a) when is_const a -> evconst n
    | Binary (_, a, b) when is_const a && is_const b -> evconst n
    | _ -> n
  in
  (* (x op c1) op c2 as x op (c1 op c2), to fold the constants *)
  let commute (n : expr) =
    match n.e with
    | Binary (o, ({ e = Binary (o', bl, br); _ } as b), a) when o' = o && is_const a && is_const bl -> ccom { n with e = Binary (o, { b with e = Binary (o, bl, a) }, br) }
    | Binary (o, ({ e = Binary (o', bl, br); _ } as b), a) when o' = o && is_const a && is_const br -> ccom { n with e = Binary (o, { b with e = Binary (o, a, br) }, bl) }
    | Binary (o, a, ({ e = Binary (o', bl, br); _ } as b)) when o' = o && is_const a && is_const bl -> ccom { n with e = Binary (o, br, { b with e = Binary (o, bl, a) }) }
    | Binary (o, a, ({ e = Binary (o', bl, br); _ } as b)) when o' = o && is_const a && is_const br -> ccom { n with e = Binary (o, bl, { b with e = Binary (o, a, br) }) }
    | _ -> common n
  in
  let bin o l r = { n with e = Binary (o, l, r) } in
  match n.e with
  | Assign (o, l, r) -> let l = ccom l in { n with e = Assign (o, l, ccom r) }
  | Unary (Cast, l) ->
      let l = ccom l in
      let n = { n with e = Unary (Cast, l) } in
      let folded = if is_const l then evconst n else n in
      if is_const folded then folded
      else if nocast l.t n.t && (not (typefd (et l)) || typeu (et l) && typeu (et n)) then { l with t = n.t }
      else n
  | Cond (c, a, b) ->
      let c = ccom c in
      let a = ccom a in
      let b = ccom b in
      if is_const c then (if zero c then b else a) else { n with e = Cond (c, a, b) }
  | Reg _ | Indreg _ | Const _ | Fconst _ | Name _ -> n
  | Unary ((Addr | Ind) as o, l) -> (
      (* &*x and *&x as x *)
      match o, (ccom l) with
      | Addr, { e = Unary (Ind, x); _ } | Ind, { e = Unary (Addr, x); _ } -> { x with t = n.t }
      | _, l -> common { n with e = Unary (o, l) })
  | Binary (o, l, r) when is_rel o ->
      let l = ccom l in
      let r = ccom r in
      let l, r = relcon l r in
      let r, l = relcon r l in
      common (bin o l r)
  | Binary ((Ashr | Ashl | Lshr) as o, l, r) ->
      let l = ccom l in
      if zero l && not (side r) then l else (let r = ccom r in if zero r then l else common (bin o l r))
  | Binary ((Mul | Lmul) as o, l, r) ->
      let l = ccom l in
      if zero l && not (side r) then l
      else if vconst l = 1 then ccom r
      else
        let r = ccom r in
        if zero r && not (side l) then r else if vconst r = 1 then l else common (bin o l r)
  | Binary ((Div | Ldiv) as o, l, r) ->
      let l = ccom l in
      if zero l && not (side r) then l
      else
        let r = ccom r in
        if zero r then diag (Some n) "divide check" else if vconst r = 1 then l else common (bin o l r)
  | Binary (Sub, l, r) -> (
      (* x - c as x + -c *)
      match (ccom r) with
      | { e = Const v; _ } as r -> ccom (bin Add l { r with e = Const (Int64.neg v) })
      | { e = Fconst f; _ } as r -> ccom (bin Add l { r with e = Fconst (-. f) })
      | r -> let l = ccom l in common (bin Sub l r))
  | Binary ((Xor | Or | Add) as o, l, r) ->
      let l = ccom l in
      if zero l then ccom r else (let r = ccom r in if zero r then l else commute (bin o l r))
  | Binary (And, l, r) ->
      let l = ccom l in
      let r = ccom r in
      if zero l && not (side r) then l else if zero r && not (side l) then r else commute (bin And l r)
  | Binary (Andand, l, r) -> let l = ccom l in if zero l then l else common (bin Andand l (ccom r))
  | Binary (Oror, l, r) -> (
      match (ccom l) with
      | { e = Const v; _ } as l when v <> 0L -> { l with e = Const 1L }
      | l -> common (bin Oror l (ccom r)))
  | Binary (o, l, r) -> let l = ccom l in common (bin o l (ccom r))
  | Unary (o, l) -> common { n with e = Unary (o, ccom l) }
  | Call (f, args) -> let f = ccom f in { n with e = Call (f, map_lr ccom args) }
  | Dot (l, o) -> { n with e = Dot (ccom l, o) }
  | _ -> n

(*****************************************************************************)
(* Sums of terms, regrouped (scon.c's acom) *)
(*****************************************************************************)

let nterm = 10

(* an addition's operator: its terms are regrouped *)
let addo (n : expr) =
  not (typefd (et n)) && (not (typev (et n)) || ewidth Tvlong = ewidth Tind)
  && (match n.e with
      | Unary (Cast, a) -> nilcast a.t n.t
      | Unary (Neg, _) | Binary ((Add | Sub), _, _) -> true
      | Binary (Mul, a, b) -> is_const a || is_const b
      | _ -> false)

let acast (tt : typ) (n : expr) =
  if et n = tt.etype then n
  else if nocast n.t tt then { n with t = tt }
  else cast_to n tt

type term = { mutable mult : int64; mutable tnode : expr option }

let rec acom (n : expr) : expr =
  match n.e with
  | Name _ | Const _ | Fconst _ | Str _ | Lstr _ | Indreg _ | Reg _ -> n
  | Unary (Neg, a) when addo n && addo a -> acom0 n
  | Binary ((Add | Sub | Mul), a, b) when addo n && (addo b || addo a) -> acom0 n
  | Unary (o, a) -> { n with e = Unary (o, acom a) }
  | Binary (o, a, b) -> let a = acom a in { n with e = Binary (o, a, acom b) }
  | Assign (o, a, b) -> let a = acom a in { n with e = Assign (o, a, acom b) }
  | Cond (c, a, b) -> let c = acom c in let a = acom a in { n with e = Cond (c, a, acom b) }
  | Call (f, args) -> let f = acom f in { n with e = Call (f, map_lr acom args) }
  | Dot (a, o) -> { n with e = Dot (acom a, o) }
  | _ -> n

(* the terms busted out, then put back together *)
and acom0 (n : expr) =
  let tt = n.t in
  let c = ref 0L and terms = ref [] and count = ref 1 in
  let rec acom1 v (n : expr) =
    if v <> 0L && !count < nterm then
      if not (addo n) then
        match n.e with
        | Const k when not (typefd (et n)) -> c := Int64.add !c (Int64.mul v k)
        | _ -> terms := { mult = v; tnode = Some n } :: !terms; incr count
      else
        match n.e with
        | Unary (Cast, a) -> acom1 v a
        | Unary (Neg, a) -> acom1 (Int64.neg v) a
        | Binary (Add, a, b) -> acom1 v a; acom1 v b
        | Binary (Sub, a, b) -> acom1 v a; acom1 (Int64.neg v) b
        | Binary (_, a, b) (* Mul *) -> if is_const a then acom1 (Int64.mul v (ival a)) b else acom1 (Int64.mul v (ival b)) a
        | _ -> ()
  in
  acom1 1L n;
  if !count < nterm then acom2 n tt (Array.of_list ({ mult = !c; tnode = None } :: List.rev !terms)) else n

and acom2 (n : expr) (tt : typ) (trm : term array) =
  let nt = Array.length trm in
  let j = ref false in
  for i = 1 to nt - 1 do if trm.(i).mult <> 0L then Option.iter (fun l -> j := true; trm.(i).tnode <- Some (acom l)) trm.(i).tnode done;
  let c1 = trm.(0).mult in
  if not !j then { n with e = Const c1 }
  else begin
    let e = tt.etype in
    let neg x = Int64.compare x 0L < 0 in
    let abs x = if neg x then Int64.neg x else x in
    let times (r : expr) c = mkt tt (Binary (Mul, r, konst c tt)) in
    let node i = Option.get trm.(i).tnode in
    (* the constant, with a term that is an address *)
    if c1 <> 0L then begin
      let l = ref (konst c1 tt) in
      trm.(0).mult <- 1L;
      (match List.find_opt (fun i -> trm.(i).mult = 1L && (match trm.(i).tnode with Some { e = Unary (Addr, _); _ } -> true | _ -> false)) (List.init (nt - 1) succ) with
       | Some i ->
           l := mkt tt (Binary (Add, { (node i) with t = tt }, !l));
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
            let r = acast tt (node k) in
            let c2 = Int64.div trm.(k).mult trm.(i).mult in
            let r = if c2 <> 1L && c2 <> -1L then times r c2 else r in
            trm.(i).tnode <- Some (mkt tt (Binary ((if c2 = -1L then Sub else Add), acast tt (node i), r)));
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
        let r = if et (node i) <> e then acast tt (node i) else node i in
        let r, c1 = if c1 <> 1L && c1 <> -1L then times r (abs c1), (if neg c1 then -1L else 1L) else r, c1 in
        match !l with
        | None -> l := Some r; c2 := c1
        | Some ll ->
            l := Some (if neg c1 then mkt tt (Binary ((if neg !c2 then Add else Sub), ll, r))
                       else if neg !c2 then (c2 := 1L; mkt tt (Binary (Sub, r, ll)))
                       else mkt tt (Binary (Add, ll, r)))
      end
    done;
    let l = Option.get !l in
    if neg !c2 then mkt tt (Binary (Sub, konst 0L tt, l)) else l
  end

(*****************************************************************************)
(* complex: all of it, for an expression (com.c) *)
(*****************************************************************************)

(* ~ret: a function's result, converted to its type rt *)
let complex ?ret (n : expr) : expr =
  nearln := n.line;
  let n =
    match ret with
    | None -> tcom n
    | Some rt ->
        let l = typeext rt (tcom n) in
        if stcompat rt l.t tasign then
          ignore (diag (Some l) "incompatible types: \"%s\" and \"%s\" for op \"RETURN\"" (show_type (Some rt)) (show_type (Some l.t)));
        if same rt l.t then l else cast_to l rt
  in
  !xcom (acom (ccom (comma n)))
