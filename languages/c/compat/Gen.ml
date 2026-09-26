(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Gen.mli *)

open Tree
open Emit
open Regs

(* the complexity of a call: more than any expression's *)
let fnx = Com64.fnx

(* what differs between 5c's and 7c's generators, beyond the
 * instructions: set by the machine's module *)
type hooks = {
  sucopy : expr -> expr -> int -> unit;       (* a structure's copy *)
  table : expr -> expr -> expr -> int -> unit;  (* a switch's table: the value, a register, its range, the default *)
  fits : expr -> int -> bool;         (* an offset folded into n's load or store *)
  neg : expr -> expr -> unit;         (* to = -from *)
  mul32 : bool;                       (* a multiplier held in 32 bits (7c's mulcon) *)
  rsb : bool;                         (* c - x as a reverse subtract (5c) *)
  by_left : bool;                     (* x op y's registers typed as x, so shifts work (7c) *)
  com64 : bool;                       (* vlong operators as calls (5c) *)
  shifts : bool;                      (* shift-and-mask simplified, a constant compared on the right (7c) *)
  zero_arg : bool;                    (* a 0 argument stored as it is (7c) *)
  asop_load : bool;                   (* x op= y: y into the result's register, x loaded after (7c) *)
  indreg_ptr : bool;                  (* a register's address computed as a pointer (7c) *)
}

let hooks : hooks option ref = ref None
let h () = Option.get !hooks

(*****************************************************************************)
(* Addressability and complexity (sgen.c's xcom) *)
(*****************************************************************************)

(* (e shift c2) & c3 shift c1, with one shift or none (sub.c's
 * simplifyshift, 7c's): c3 is an unsigned long of 64 bits *)
let simplifyshift (n : expr) =
  let kind = function Ashl -> Some 0 | Lshr -> Some 1 | Ashr -> Some 2 | _ -> None in
  let topbit v = let rec go i v = if v = 0L then i else go (i + 1) (Int64.shift_right_logical v 1) in go (-1) v in
  match n.e with
  | Binary (o, ({ e = Binary (And, ({ e = Binary (o2, x, ({ e = Const k2; _ } as c2n)); _ } as inner), ({ e = Const c3; _ } as c3n)); _ } as andn), ({ e = Const k1; _ } as c1n))
    when kind o <> None && kind o2 <> None && typechlp (et n) ->
      let s1, s2 = match kind o, kind o2 with Some a, Some b -> a, b | _ -> 0, 0 in
      let c1 = Int64.to_int (sx32 k1) and c2 = Int64.to_int (sx32 k2) in
      let k (c : expr) v = { c with e = Const v } in
      (* get rid of both shifts, the lower, or the upper *)
      let rewrite0 c3 = { andn with e = Binary (And, x, k c3n c3) } in
      let rewrite1 c3 c1 o = { n with e = Binary (o, { andn with e = Binary (And, x, k c3n c3) }, k c1n (Int64.of_int c1)) } in
      let rewrite2 c3 c1 o = { andn with e = Binary (And, { inner with e = Binary (o, x, k c2n (Int64.of_int c1)) }, k c3n c3) } in
      let shl v k = Int64.shift_left v k and shr v k = Int64.shift_right_logical v k in
      let case001 () =
        if c1 > c2 then rewrite1 (shl c3 c2) (c1 - c2) Ashl
        else (let c3 = shl c3 c1 in if c1 = c2 then rewrite0 c3 else rewrite2 c3 (c2 - c1) Lshr)
      in
      let s11 () = if c1 + c2 < 32 then rewrite1 (shl c3 c2) (c1 + c2) Lshr else n in
      let case010 () =
        let c3 = shr c3 c1 in
        if c1 = c2 then rewrite0 c3 else if c1 > c2 then rewrite2 c3 (c1 - c2) o else rewrite2 c3 (c2 - c1) Ashl
      in
      (match (s1 lsl 3) lor s2 with
       | 0o00 -> if c1 + c2 < 32 then rewrite1 (shr c3 c2) (c1 + c2) o else n
       | 0o02 -> if topbit c3 < 32 - c2 then case001 () else n
       | 0o01 -> case001 ()
       | 0o22 -> if c2 > 0 && topbit c3 < 32 - c2 then s11 () else n
       | 0o12 -> if topbit c3 < 32 - c2 then s11 () else n
       | 0o21 -> if not (topbit c3 >= 31 && c2 <= 0) then s11 () else n
       | 0o11 -> s11 ()
       | 0o20 -> if topbit c3 < 31 then case010 () else n
       | 0o10 -> case010 ()
       | _ -> n)
  | _ -> n

(* the registers a node needs, from its sides' (Sethi-Ullman) *)
let need (l : int) (r : int option) =
  let c = match r with Some r -> if r = l then r + 1 else max r l | None -> l in
  if c = 0 then 1 else c

(* addressable: see Tree's addr; complex: the registers needed. And by
 * a power of 2, a multiplication is a shift, an unsigned division too,
 * an unsigned remainder a mask *)
let rec xcom (n : expr) : expr =
  let e =
    match n.e with
    | Unary (o, a) -> Unary (o, xcom a)
    | Binary (o, a, b) -> let a = xcom a in Binary (o, a, xcom b)
    | Assign (o, a, b) -> let a = xcom a in Assign (o, a, xcom b)
    | Cond (c, a, b) -> let c = xcom c in let a = xcom a in Cond (c, a, xcom b)
    | Call (f, args) -> let f = xcom f in Call (f, map_lr xcom args)
    | Dot (a, o) -> Dot (xcom a, o)
    | e -> e
  in
  let n = { n with e; addable = Anone; complex = 0 } in
  let pow2 (x : expr) ~mask =
    match x.e with
    | Const v when Check.vlog x >= 0 -> Some (if mask then { x with e = Const (Int64.pred v) } else { x with e = Const (Int64.of_int (Check.vlog x)); t = ty Tint })
    | _ -> None
  in
  let shifts n = if (h ()).shifts then simplifyshift n else n in
  let n =
    match n.e with
    | Const _ | Fconst _ -> { n with addable = Aconst }
    | Reg _ -> { n with addable = Areg }
    | Indreg _ -> { n with addable = Aindreg }
    | Name _ -> { n with addable = Aname }
    | Unary (Addr, l) -> (match l.addable with Aname -> { n with addable = Aaddr_name } | Aindreg -> { n with addable = Aaddr_reg } | _ -> n)
    | Unary (Ind, l) -> (match l.addable with Areg | Aaddr_reg -> { n with addable = Aindreg } | Aaddr_name -> { n with addable = Aname } | _ -> n)
    | Binary (Add, l, r) -> (
        match l.addable, r.addable with
        | Aconst, (Aaddr_name | Aaddr_reg) -> { n with addable = r.addable }
        | (Aaddr_name | Aaddr_reg), Aconst -> { n with addable = l.addable }
        | _ -> n)
    | Assign (Some (Mul | Lmul), l, r) -> (match pow2 r ~mask:false with Some r -> { n with e = Assign (Some Ashl, l, r) } | None -> n)
    | Binary ((Mul | Lmul) as o, l, r) -> (
        let o, r = match pow2 r ~mask:false with Some r -> Ashl, r | None -> o, r in
        (* the constant on the left: swapped *)
        match pow2 l ~mask:false with Some l -> shifts { n with e = Binary (Ashl, r, l) } | None -> { n with e = Binary (o, l, r) })
    | Assign (Some Ldiv, l, r) -> (match pow2 r ~mask:false with Some r -> { n with e = Assign (Some Lshr, l, r) } | None -> n)
    | Binary (Ldiv, l, r) -> (match pow2 r ~mask:false with Some r -> shifts { n with e = Binary (Lshr, l, r) } | None -> n)
    | Binary ((Lshr | Ashl | Ashr), _, _) -> shifts n
    | Assign (Some Lmod, l, r) -> (match pow2 r ~mask:true with Some r -> { n with e = Assign (Some And, l, r) } | None -> n)
    | Binary (Lmod, l, r) -> (match pow2 r ~mask:true with Some r -> { n with e = Binary (And, l, r) } | None -> n)
    | _ -> n
  in
  if addressable n then n
  else begin
    let complex =
      match n.e with
      | Unary (_, a) -> need a.complex None
      | Binary (_, a, b) | Assign (_, a, b) -> need a.complex (Some b.complex)
      | Cond (c, a, b) -> need c.complex (Some (need a.complex (Some b.complex)))
      | Call (f, _) -> need f.complex None
      | Dot (a, _) -> need a.complex (Some 0)
      | _ -> 1
    in
    let n = { n with complex } in
    match (if (h ()).com64 then Com64.com64 n else None) with
    | Some n -> n
    | None -> (
        match n.e with
        | Call _ -> { n with complex = fnx }
        (* the constant on the right, as an immediate; a relation reversed (7c) *)
        | Binary ((Add | Xor | And | Or) as o, l, r) when is_const l -> { n with e = Binary (o, r, l) }
        | Binary ((Eq | Ne) as o, l, r) when (not (h ()).shifts) && is_const l -> { n with e = Binary (o, r, l) }
        | Binary (o, l, r) when is_rel o && (h ()).shifts && is_const l -> { n with e = Binary (Check.invrel o, r, l) }
        | _ -> n)
  end

(*****************************************************************************)
(* Expressions (cgen.c) *)
(*****************************************************************************)

let gmove f t = (bk ()).gmove f t
let gopcode o f1 f2 t = (bk ()).gopcode o false f1 f2 t
let op2 o f t = gopcode (Op o) (Some f) None (Some t)                  (* t = t o f *)
let op3 o f m t = gopcode (Op o) (Some f) (Some m) (Some t)            (* t = m o f *)
let compare ?(tr = false) o f m = (bk ()).gopcode (Op o) tr (Some f) (Some m) None
let gcase f m = (bk ()).gopcode Gcase false (Some f) (Some m) None
let jump () = ignore (gbranch ())
let here q = patch q !pc
let iconst n = nodconst (Int64.of_int n)

(* the heavier side first: its value's register takes nn *)
let ordered (l : expr) (r : expr) f g = if l.complex >= r.complex then (let a = f () in a, g ()) else (let b = g () in f (), b)

(* constants that fit an instruction; the linker sorts out the rest *)
let sconst (n : expr) = match n.e with Const _ -> not (typefd (et n)) | _ -> false

exception Return

(* n into nn, or for its effects when nn is None; inrel, as a
 * comparison's operand *)
let rec cgen (n : expr) (nn : expr option) = cgenrel n nn false

(* the value of a comma list, the rest generated first *)
and uncomma (n : expr) = match n.e with Binary (Comma, a, b) -> cgen a None; uncomma b | _ -> n

and effects (l : expr) = cgen l None

and cgenrel (n : expr) (nn : expr option) inrel =
  if (m ()).typecmplx (et n) then sugen n nn n.t.width
  else if addressable n then Option.iter (gmove n) nn
  else begin
    let curs = !cursafe in
    match cgen1 n nn inrel with () -> cursafe := curs | exception Return -> ()
  end

(* both sides calls: the right one first, to a temporary; the tree
 * with the temporary as its right side *)
and spill_right (n : expr) ~rel =
  let r = match n.e with Binary (_, _, r) | Assign (_, _, r) -> r | _ -> diag (Some n) "no right side" in
  let nod = regret r in
  cgenrel r (Some nod) rel;
  let nod1 = regsalloc r in
  gmove nod nod1;
  regfree nod;
  match n.e with
  | Binary (o, l, _) -> { n with e = Binary (o, l, nod1) }
  | Assign (o, l, _) -> { n with e = Assign (o, l, nod1) }
  | _ -> n

(* an lvalue in a register unless it is addressable; its release *)
and lvalue (l : expr) = if not (addressable l) then reglcgen l None else l
and unlvalue (l : expr) nod = if not (addressable l) then regfree nod

(* c ? a : b, a and b generating themselves *)
and ifelse (c : expr) a b =
  bcgen c true;
  let p1 = p () in
  a ();
  jump ();
  here p1;
  let p1 = p () in
  b ();
  here p1

and cgen1 (n : expr) (nn : expr option) inrel =
  let spill l r ok = n.complex >= fnx && l.complex >= fnx && r.complex >= fnx && ok in
  (match n.e with
   | Binary (o, l, r) when spill l r (not (List.mem o [ Comma; Andand; Oror ]) && not (is_rel o && typesu (et l))) ->
       cgen (spill_right n ~rel:false) nn; raise Return
   | Assign (_, l, r) when spill l r true -> cgen (spill_right n ~rel:false) nn; raise Return
   | _ -> ());
  let unary l f = match nn with None -> effects l | Some nn -> f nn in
  let muldiv o l r =
    match nn with
    | None -> effects l; effects r
    | Some nn when (o = Mul || o = Lmul) && mulcon n nn -> ()
    | Some nn ->
        let ty_r = if (h ()).by_left then l else r in
        let nod, nod1 =
          if l.complex >= r.complex then begin
            let nod = regalloc l (Some nn) in
            cgen l (Some nod);
            let nod1 = regalloc ty_r None in
            cgen r (Some nod1);
            op2 o nod1 nod;
            nod, nod1
          end
          else begin
            let nod = regalloc ty_r (Some nn) in
            cgen r (Some nod);
            let nod1 = regalloc l None in
            cgen l (Some nod1);
            op3 o nod nod1 nod;
            nod, nod1
          end
        in
        gmove nod nn;
        regfree nod;
        regfree nod1
  in
  (* x op c, an immediate *)
  let immediate o l (r : expr) =
    match r.e with
    | Const v when nn <> None && not (typefd (et n)) -> cgen l nn; if v <> 0L || o = And then gopcode (Op o) (Some r) None nn
    | _ -> muldiv o l r
  in
  (* l op= r: 7c's, r into the result's register and l loaded after,
   * converted if its type isn't the result's; 5c's, l into it *)
  let asop o l r =
    let into = if (h ()).asop_load then n else r in
    let nod2, nod = ordered l r (fun () -> lvalue l) (fun () -> let nod = regalloc into (if (h ()).asop_load then nn else None) in cgen r (Some nod); nod) in
    if (h ()).asop_load then begin
      let nod1 = regalloc n None in
      gmove nod2 nod1;
      let nod1 = if et nod1 <> et nod then (let nod3 = regalloc nod None in gmove nod1 nod3; regfree nod1; nod3) else nod1 in
      op3 o nod nod1 nod;
      gmove nod nod2;
      Option.iter (gmove nod) nn;
      regfree nod;
      regfree nod1
    end
    else begin
      let res = regalloc n nn in
      gmove nod2 res;
      op2 o nod res;
      gmove res nod2;
      Option.iter (gmove res) nn;
      regfree res;
      regfree nod
    end;
    unlvalue l nod2
  in
  match n.e with
  | Assign (None, l, r) ->
      if addressable l && l.complex < fnx then begin
        if nn = None && addressable r then gmove r l
        else begin
          let nod = if r.complex >= fnx && nn = None then regret r else regalloc r nn in
          cgen r (Some nod);
          gmove nod l;
          Option.iter (gmove nod) nn;
          regfree nod
        end
      end
      else if l.complex >= r.complex && addressable r then begin
        let nod1 = reglcgen l None in
        gmove r nod1;
        Option.iter (gmove r) nn;
        regfree nod1
      end
      else begin
        let nod1, nod = ordered l r (fun () -> reglcgen l None) (fun () -> let nod = regalloc r nn in cgen r (Some nod); nod) in
        gmove nod nod1;
        regfree nod;
        regfree nod1
      end
  | Binary ((Div | Mod) as o, l, r) when nn <> None && Check.vlog r >= 0 ->
      (* signed division by a power of 2 *)
      let nn = Option.get nn and t = Check.vlog r in
      cgen l (Some nn);
      compare Ge (nodconst 0L) nn;
      let p1 = p () in
      if o = Div then begin
        op2 Add (iconst ((1 lsl t) - 1)) nn;
        here p1;
        op2 Ashr (iconst t) nn
      end
      else begin
        (h ()).neg nn nn;
        op2 And (iconst ((1 lsl t) - 1)) nn;
        (h ()).neg nn nn;
        jump ();
        here p1;
        let p1 = p () in
        op2 And (iconst ((1 lsl t) - 1)) nn;
        here p1
      end
  | Binary (Sub, l, r) when (h ()).rsb && nn <> None && is_const l && not (typefd (et n)) -> cgen r nn; gopcode (Op Sub) None (Some l) nn
  | Binary ((Add | Sub | And | Or | Xor | Lshr | Ashl | Ashr) as o, l, r) -> immediate o l r
  | Binary ((Lmul | Ldiv | Lmod | Mul | Div | Mod) as o, l, r) -> muldiv o l r
  (* only 7c's front end leaves them: 5c's makes them 0-x and -1^x *)
  | Unary ((Neg | Com) as o, l) ->
      unary l (fun nn -> let nod = regalloc l (Some nn) in cgen l (Some nod); gopcode (if o = Neg then Gneg else Gcom) (Some nod) None (Some nod); gmove nod nn; regfree nod)
  | Assign (Some ((Lshr | Ashl | Ashr | And | Add | Sub | Xor | Or) as o), l, r) when sconst r && not (typefd (et n)) ->
      let nod2 = lvalue l in
      let nod = regalloc (if (h ()).by_left then l else r) nn in
      gmove nod2 nod;
      op2 o r nod;
      gmove nod nod2;
      regfree nod;
      unlvalue l nod2
  | Assign (Some o, l, r) -> asop o l r
  | Unary (Addr, l) -> unary l (fun nn -> lcgen l (Some nn))
  | Call (f, args) ->
      let f = uncomma f in
      if f.complex >= fnx then begin
        (* the function is itself computed by a call *)
        match f.e with
        | Unary (o, ll) ->
            let nod = regret ll in
            cgen ll (Some nod);
            let nod1 = regsalloc ll in
            gmove nod nod1;
            regfree nod;
            cgen { n with e = Call ({ f with e = Unary (o, nod1); complex = 1 }, args) } nn;
            raise Return
        | _ -> ignore (diag (Some f) "a call computed by a call")
      end;
      let regarg = (bk ()).regret in
      let o = !regs.(regarg) in
      gargs args;
      if not (addressable f) then (let nod = reglcgen f None in gopcode Gcall None None (Some nod); regfree nod)
      else gopcode Gcall None None (Some f);
      if o <> !regs.(regarg) then !regs.(regarg) <- !regs.(regarg) - 1;
      Option.iter (fun nn -> let nod = regret n in gmove nod nn; regfree nod) nn
  | Unary (Ind, l) ->
      unary l (fun nn ->
        let nod = regialloc n (Some nn) in
        let off = fold_offset l n (fun l -> cgen l (Some nod)) in
        let nod = regind nod n off in
        gmove nod nn;
        regfree nod)
  | Binary (o, l, r) when is_rel o -> if nn = None then (effects l; effects r) else boolgen n true nn
  | Binary ((Andand | Oror), _, _) -> boolgen n true nn; if nn = None then here (p ())
  | Unary (Not, l) -> unary l (fun _ -> boolgen n true nn)
  | Binary (Comma, l, r) -> cgen l None; cgen r nn
  | Unary (Cast, l) ->
      unary l (fun nnn ->
        if Check.nocast l.t n.t && Check.nocast n.t nnn.t then cgen l nn
        else begin
          let nod = regalloc l nn in
          cgen l (Some nod);
          let nod1 = regalloc n (Some nod) in
          if inrel then (bk ()).gmover nod nod1 else gmove nod nod1;
          gmove nod1 nnn;
          regfree nod1;
          regfree nod
        end)
  | Dot _ -> dot n nn (fun nod -> cgen nod nn)
  | Cond (c, a, b) -> ifelse c (fun () -> cgen a nn) (fun () -> cgen b nn)
  | Unary ((Postinc | Postdec | Preinc | Predec) as o, l) ->
      let v = if et l = Tind then (link l.t).width else 1 in
      let v = if o = Postdec || o = Predec then - v else v in
      let post = (o = Postinc || o = Postdec) && nn <> None in
      let nod2 = lvalue l in
      let nod = regalloc l nn in
      gmove nod2 nod;
      (* x++ into a new register, the old kept; ++x in place *)
      let into = if post then regalloc l None else nod in
      let middle = if post then Some nod else None in
      if typefd (et l) then begin
        let nod3 = regalloc l None in
        gmove (nodfconst (float_of_int (abs v))) nod3;
        gopcode (Op (if v < 0 then Sub else Add)) (Some nod3) middle (Some into);
        regfree nod3
      end
      else gopcode (Op Add) (Some (iconst v)) middle (Some into);
      gmove into nod2;
      (* in x = ++i, USED(i) *)
      if not post && nn <> None && (match l.e with Name _ -> true | _ -> false) then ignore (gins "NOP" (Some l) None);
      regfree nod;
      if post then regfree into;
      unlvalue l nod2
  | _ -> ignore (diag (Some n) "unknown op in cgen")

(* the offset of a constant at the end of the address x, folded into
 * n's load or store: the address generated with it 0 *)
and fold_offset (x : expr) (n : expr) gen =
  let rec right (x : expr) = match x.e with Binary (Add, _, b) -> right b | _ -> x in
  let rec zero (x : expr) = match x.e with Binary (Add, a, b) -> { x with e = Binary (Add, a, zero b) } | _ -> { x with e = Const 0L } in
  match (right x).e with
  | Const v when sconst (right x) && (h ()).fits n (Int64.to_int v) -> gen (zero x); Int64.to_int v
  | _ -> gen x; 0

(* a structure's member: the structure into .rathole, then the member *)
and dot (n : expr) (nn : expr option) k =
  match n.e with
  | Dot (l, off) ->
      let rat = Option.get !nodrat in
      sugen l (Some rat) l.t.width;
      if nn <> None then k { (plus rat (Int64.to_int (sx32 (Int64.of_int off)))) with t = n.t }
  | _ -> ignore (diag (Some n) "DOT and no offset")

(* the address of n, in a register, as an indirect node *)
and reglcgen (n : expr) (nn : expr option) =
  let t = regialloc n nn in
  let off =
    match n.e with
    | Unary (Ind, x) -> fold_offset x n (fun x -> lcgen { n with e = Unary (Ind, x) } (Some t))
    | Indreg (r, o) when (h ()).fits n o ->
        cgen (if (h ()).indreg_ptr then { n with e = Reg r; t = ty Tind } else { n with e = Reg r }) (Some t);
        o
    | _ -> lcgen n (Some t); 0
  in
  regind t n off

(* the address of nn as a long's, in a register (5c's reglpcgen) *)
and reglpcgen (nn : expr) f =
  let nn = { nn with t = ty Tlong } in
  if f then reglcgen nn None else (let n = regialloc nn None in lcgen nn (Some n); regind n nn 0)

(* the address of n into nn *)
and lcgen (n : expr) (nn : expr option) =
  let nn = match nn with Some nn -> nn | None -> regalloc n None in
  match n.e with
  | Binary (Comma, a, b) -> cgen a (Some a); lcgen b (Some nn)
  | Unary (Ind, a) -> cgen a (Some nn)
  | Cond (c, a, b) -> ifelse c (fun () -> lcgen a (Some nn)) (fun () -> lcgen b (Some nn))
  | _ when not (addressable n) -> ignore (diag (Some n) "unknown op in lcgen")
  | _ -> gmove { n with e = Unary (Addr, n); t = ty Tind } nn

and bcgen (n : expr) tr = boolgen n tr None

(* n as a condition: a branch taken if n is tr; into nn, 1 or 0 *)
and boolgen (n : expr) tr (nn : expr option) =
  let curs = !cursafe in
  let com () =
    Option.iter (fun nn ->
      let p1 = p () in
      gmove (nodconst 1L) nn;
      jump ();
      let p2 = p () in
      here p1;
      gmove (nodconst 0L) nn;
      here p2) nn
  in
  (* a and b, true; a or b, false: both branches to the end *)
  let caseand l r tr =
    bcgen l tr;
    let p1 = p () in
    bcgen r (not tr);
    let p2 = p () in
    here p1;
    jump ();
    here p2
  in
  let caseor l r tr =
    bcgen l (not tr);
    let p1 = p () in
    bcgen r (not tr);
    let p2 = p () in
    jump ();
    here p1;
    here p2
  in
  let rel o = if tr then Check.comrel o else o in
  (match n.e with
   | Const _ | Fconst _ ->
       jump ();
       if (Check.vconst n <> 0) = tr then (let p1 = p () in jump (); here p1);
       com ()
   | Binary (Comma, l, r) -> cgen l None; boolgen r tr nn
   | Unary (Not, l) -> boolgen l (not tr) nn
   | Cond (c, a, b) ->
       bcgen c true;
       let p1 = p () in
       bcgen a tr;
       let p2 = p () in
       jump ();
       here p1;
       let p1 = p () in
       bcgen b (not tr);
       here p2;
       let p2 = p () in
       jump ();
       here p1;
       here p2;
       com ()
   | Binary (Andand, l, r) -> (if tr then caseand else caseor) l r tr; com ()
   | Binary (Oror, l, r) -> (if tr then caseor else caseand) l r tr; com ()
   | Binary (o, l, r) when is_rel o && l.complex >= fnx && r.complex >= fnx -> boolgen (spill_right n ~rel:true) tr nn
   | Binary (o, l, r) when is_rel o ->
       let o = rel o in
       (* a constant compared: as an immediate *)
       let one_side (x : expr) c o = let nod = regalloc x nn in cgenrel x (Some nod) true; compare ~tr o c nod; regfree nod in
       if sconst l then one_side r l (Check.invrel o)
       else if sconst r then one_side l r o
       else begin
         let nod1, nod = ordered l r (fun () -> let x = regalloc l (if l.complex >= r.complex then nn else None) in cgenrel l (Some x) true; x)
                                     (fun () -> let x = regalloc r (if l.complex >= r.complex then None else nn) in cgenrel r (Some x) true; x) in
         compare ~tr o nod nod1;
         regfree nod;
         regfree nod1
       end;
       com ()
   | _ ->
       let nod = regalloc n nn in
       cgen n (Some nod);
       if typefd (et n) then compare ~tr (rel Ne) (nodfconst 0.) nod else compare (rel Ne) (nodconst 0L) nod;
       regfree nod;
       com ());
  cursafe := curs

(* structures (and vlongs on arm), n into nn, w bytes *)
and sugen (n : expr) (nn : expr option) w =
  (match nn with Some x when x == Option.get !nodrat -> if w > !nrathole then nrathole := w | _ -> ());
  let rat = Option.get !nodrat in
  match n.e, nn with
  | Unary (Ind, l), None -> effects l
  | Const _, None -> ()
  | Const v, Some nn when typev (et n) ->
      (* the two words *)
      let nod1 = reglcgen { nn with t = ty Tlong } None in
      gmove (nodconst (sx32 v)) nod1;
      gmove (nodconst (sx32 (Int64.shift_right v 32))) (plus nod1 4);
      regfree nod1
  | Dot _, _ -> dot n nn (fun nod -> sugen nod nn w)
  | Assign (None, l, r), None -> if not (addressable n) then sugen r (Some l) w
  | Assign (None, l, r), Some _ -> sugen r (Some rat) w; sugen rat (Some l) w; sugen rat nn w
  | Call _, None -> sugen n (Some rat) w
  | Call (f, args), Some nnn ->
      (* the result's address, as the first argument *)
      let a = match nnn.e with Unary (Ind, x) -> x | _ -> mk ~t:(ty Tind) ~line:!nearln (Unary (Addr, nnn)) in
      cgen (mk ~t:(ty Tvoid) (Call ({ f with t = ty Tvoid }, a :: args))) None
  | Cond (c, a, b), _ -> ifelse c (fun () -> sugen a nn w) (fun () -> sugen b nn w)
  | Binary (Comma, a, b), _ -> cgen a None; sugen b nn w
  | _, None -> ()
  | _, Some nn when n.complex >= fnx && nn.complex >= fnx ->
      (* the destination's address first, to a temporary *)
      let nnl = { nn with t = ty Tlong } in
      let nod1 = regialloc nnl None in
      lcgen nnl (Some nod1);
      let nod2 = regsalloc nnl in
      gmove nod1 nod2;
      regfree nod1;
      let nod2 = { nod2 with t = typ Tind (Some nn.t) } in
      sugen n (Some { nod2 with e = Unary (Ind, nod2); complex = 1; t = nn.t }) w
  | _, Some nn -> (h ()).sucopy n nn w

(*****************************************************************************)
(* Multiplication by a constant (swt.c's mulcon) *)
(*****************************************************************************)

and mulcon (n : expr) (nn : expr) =
  match n.e with
  | Binary (_, a, b) -> (
      let l, r = if is_const a then b, a else a, b in
      match r.e with
      | Const rv -> (
          let v = convvtox rv (et n) in
          let v = if (h ()).mul32 then sx32 v else v in
          match Multiply.mulcon0 (Int64.to_int v) with
          | Some code when not (typefd (et n)) && v = rv ->
              let code = if String.length code > 1 && code.[1] = 'i' then String.sub code 2 (String.length code - 2) else code in
              let nod1 = regalloc n (Some nn) in
              cgen l (Some nod1);
              let nod2 = regalloc n None in
              let pick k = if k then nod2 else nod1 in
              (* two letters an operation: a shift by the letter's rank, or + -,
               * then which registers, as bits *)
              for i = 0 to (String.length code / 2) - 1 do
                let d = Char.code code.[(2 * i) + 1] - 48 in
                match code.[2 * i] with
                | ('+' | '-') as c -> op3 (if c = '+' then Add else Sub) (pick (d land 1 <> 0)) (pick (d land 2 <> 0)) (pick (d land 4 <> 0))
                | c -> op3 Ashl (iconst (Char.code c - 97)) (pick (d land 1 <> 0)) (pick (d land 2 <> 0))
              done;
              regfree nod2;
              if Int64.compare v 0L < 0 then (gmove nod1 nod1; (h ()).neg nod1 nn) else gmove nod1 nn;
              regfree nod1;
              true
          | _ -> false)
      | _ -> false)
  | _ -> false

(*****************************************************************************)
(* Arguments (txt.c's gargs) *)
(*****************************************************************************)

(* the calls first, to temporaries; then the arguments, the first in a
 * register if it fits one *)
and gargs (args : expr list) =
  let regs0 = !cursafe in
  let temps = map_lr (fun (n : expr) ->
    if n.complex >= fnx then begin
      let s = regsalloc n in
      cgen (mk ~t:n.t (Assign (None, s, n))) None;
      s
    end
    else n) args in
  curarg := 0;
  List.iter2 (fun (n : expr) (src : expr) ->
    if (m ()).typecmplx (et n) then (let tn2 = regaalloc n in sugen src (Some tn2) n.t.width)
    else if !curarg = 0 && (m ()).typeword (et n) then cgen src (Some (regaalloc1 n))
    else if (h ()).zero_arg && Check.vconst n = 0 then gmove n (regaalloc n)
    else begin
      let tn1 = regalloc n None in
      cgen src (Some tn1);
      gmove tn1 (regaalloc n);
      regfree tn1
    end) args temps;
  cursafe := regs0

(*****************************************************************************)
(* Statements (pgen.c) *)
(*****************************************************************************)

(* a switch's cases, the last first, and the one of the switch's
 * start, which ends the list (pswt.c's casf) *)
type case = { cval : int64; cdef : bool; clabel : int; cisv : bool }

let cases : case list option ref = ref None
let breakpc = ref (-1)
let continpc = ref (-1)
let nbreak = ref 0
let ncontin = ref 0
let canreach = ref true

(* the result registers that hold no value, as NOPs for the optimizer *)
let noretval ~r ~f =
  if r then (gins "NOP" None None).to_ <- Some (Ix_asm.Asm.Reg (bk ()).regret);
  if f then (gins "NOP" None None).to_ <- Some (Ix_asm.Asm.FReg (bk ()).fregret)

(* a statement no label enters (sub.c's deadhead) *)
let rec deadhead (s : stmt) caseok =
  match s with
  | Block l -> List.for_all (fun s -> deadhead s caseok) l
  | Label _ -> false
  | Case _ -> caseok
  | Switch (_, s) -> deadhead s true
  | While (_, s) | Dowhile (s, _) | For (_, _, _, s) -> deadhead s caseok
  | If (_, a, b) -> deadhead a caseok && (match b with Some b -> deadhead b caseok | None -> true)
  | _ -> true

(* a condition, as a branch taken when false; with the if's sides, true
 * if it is a constant whose other side is dead code *)
let bcomplex (n : expr) (sides : (stmt * stmt option) option) =
  let n = Check.complex n in
  Check.tcompat n untyped n.t tnot;
  match sides with
  | Some (a, b) when is_const n && deadhead a false && (match b with Some b -> deadhead b false | None -> true) -> n, true
  | _ -> boolgen (Com64.bool64 n) true None; n, false

let add_case c = cases := Some (c :: Option.get !cases)

(* a vlong's constant, or a long's (7c's nodgconst) *)
let nodgconst v (t : typ) = if typev t.etype then { (nodconst v) with t = ty Tvlong } else nodconst (sx32 v)

(* the sorted cases' dispatch: a table when dense, compares when few,
 * else a binary search (swt.c's swit1 and swit2) *)
let swit (q : (int64 * int) array) def (n : expr) =
  let tn = regalloc (regnode ()) None in
  let c v = nodgconst v n.t in
  let rec swit2 lo nc =
    let value i = fst q.(lo + i) and label i = snd q.(lo + i) in
    let span = if nc >= 3 then sx (Int64.sub (value (nc - 1)) (value 0)) else 0L in
    if nc >= 3 && Int64.compare span 0L > 0 && Int64.compare span (Int64.of_int (nc * 2)) < 0 then begin
      let v = ref (value 0) in
      if !v <> 0L then op2 Sub (c !v) n;
      (h ()).table n tn (c (Int64.sub (value (nc - 1)) !v)) def;
      (* a BCASE per value, the missing ones to the default *)
      for i = 0 to nc - 1 do
        while value i <> !v do
          let q = nextpc () in q.as_ <- "BCASE"; patch q def;
          v := Int64.succ !v
        done;
        let q = nextpc () in q.as_ <- "BCASE"; patch q (label i);
        v := Int64.succ !v
      done;
      patch (gbranch ()) def
    end
    else if nc < 5 then begin
      for i = 0 to nc - 1 do compare Eq (c (value i)) n; patch (p ()) (label i) done;
      patch (gbranch ()) def
    end
    else begin
      let i = nc / 2 in
      compare Gt (c (value i)) n;
      let sp = p () in
      compare Eq (c (value i)) n;
      patch (p ()) (label i);
      swit2 lo i;
      here sp;
      swit2 (lo + i + 1) (nc - i - 1)
    end
  in
  swit2 0 (Array.length q);
  regfree tn

(* the cases, sorted, to the machine's dispatch (pswt.c's doswit) *)
let doswit (n : expr) =
  let all = Option.get !cases in
  let cs = List.filter (fun c -> not c.cdef) (List.rev (List.tl (List.rev all))) in
  let def = List.fold_left (fun d c -> if c.cdef then c.clabel else d) 0 all in
  let isv = typev (et n) in
  let q = List.map (fun c -> (if isv then c.cval else sx32 c.cval), c.clabel) (List.filter (fun c -> not c.cisv || isv) cs) in
  let q = Array.of_list (List.stable_sort (fun (a, _) (b, _) -> Stdlib.compare a b) q) in
  for i = 0 to Array.length q - 2 do
    if fst q.(i) = fst q.(i + 1) then ignore (diag (Some n) "duplicate cases in switch %Ld" (fst q.(i)))
  done;
  let def = if def = 0 then (incr nbreak; !breakpc) else def in
  if isv && ewidth Tind <= ewidth Tlong then ignore (diag (Some n) "64-bit switches on 32-bit machines are not in the subset");
  swit q def n

(* a label's last forward goto (5c's n->label) *)
let labels : (label * prog) list ref = ref []
let pending (l : label) = List.assq_opt l !labels

let goto target = patch (gbranch ()) target

(* a loop's or a switch's targets, restored after; can the end be
 * reached: if it is broken out of *)
let scoped ~contin f =
  let scc = !continpc and sbc = !breakpc and snbreak = !nbreak and sncontin = !ncontin in
  nbreak := 0;
  if contin then ncontin := 0;
  f ();
  continpc := scc;
  breakpc := sbc;
  canreach := !nbreak <> 0;
  nbreak := snbreak;
  if contin then ncontin := sncontin

let rec gen (s : stmt) =
  match s with
  | Block l -> List.iter gen l
  | Expr { e = Binary (Comma, a, b); _ } -> gen (Expr a); gen (Expr b)
  | Expr n -> cgen (Check.complex n) None
  | Return (x, rt) ->
      canreach := false;
      (match x with
       | None -> noretval ~r:true ~f:true
       | Some x ->
           let l = uncomma (Check.complex ~ret:rt x) in
           if (m ()).typecmplx rt.etype then begin
             cgen { (mk ~t:rt (Assign (None, Option.get !nodret, l))) with complex = l.complex } None;
             noretval ~r:true ~f:true
           end
           else begin
             let nod = regret { l with t = rt } in
             cgen l (Some nod);
             regfree nod;
             noretval ~r:(typefd rt.etype) ~f:(not (typefd rt.etype))
           end);
      ignore (greturn ())
  | Label l ->
      canreach := true;
      l.lpc <- !pc;
      Option.iter here (pending l);
      (* no self reference *)
      goto (!pc + 1)
  | Goto l ->
      canreach := false;
      if not l.defined then ignore (diag None "label undefined: %s" l.lsym.name)
      else if !suppress = 0 then begin
        let q = gbranch () in
        if l.lpc <> 0 then patch q l.lpc
        else begin
          (* the previous goto branches to this one, as 5c's *)
          Option.iter (fun prev -> patch prev (!pc - 1)) (pending l);
          labels := (l, q) :: List.filter (fun (x, _) -> x != l) !labels
        end
      end
  | Case x ->
      canreach := true;
      if !cases = None then ignore (diag None "case/default outside a switch");
      (match x with
       | None -> add_case { cval = 0L; cdef = true; clabel = !pc; cisv = false }
       | Some x -> (
           match Check.complex x with
           | { e = Const v; _ } as l when (m ()).typeswitch (et l) -> add_case { cval = v; cdef = false; clabel = !pc; cisv = typev (et l) }
           | l -> ignore (diag (Some l) "case expression must be integer constant")))
  | Switch (x, body) ->
      let l = Check.complex x in
      if not ((m ()).typeswitch (et l)) then ignore (diag (Some l) "switch expression must be integer");
      let sp = gbranch () in
      let cn = !cases in
      cases := Some [ { cval = 0L; cdef = false; clabel = 0; cisv = false } ];
      scoped ~contin:false (fun () ->
        breakpc := !pc;
        let spb = gbranch () in
        gen body;
        if !canreach then (goto !breakpc; incr nbreak);
        here sp;
        (* always signed *)
        let nod = { (regalloc l None) with t = ty (if typev (et l) then Tvlong else Tlong) } in
        cgen l (Some nod);
        doswit nod;
        regfree nod;
        here spb);
      cases := cn
  | While (c, body) | Dowhile (body, c) ->
      let dw = match s with Dowhile _ -> true | _ -> false in
      let sp = gbranch () in
      scoped ~contin:false (fun () ->
        continpc := !pc;
        let spc = gbranch () in
        breakpc := !pc;
        let spb = gbranch () in
        here spc;
        if not dw then here sp;
        test c;
        if dw then here sp;
        gen body;
        goto !continpc;
        here spb)
  | For (init, c, step, body) ->
      gen init;
      let sp = gbranch () in
      scoped ~contin:true (fun () ->
        continpc := !pc;
        let spc = gbranch () in
        breakpc := !pc;
        let spb = gbranch () in
        here spc;
        gen step;
        here sp;
        Option.iter test c;
        canreach := true;
        gen body;
        if !canreach then (goto !continpc; incr ncontin);
        here spb)
  | Continue ->
      if !continpc < 0 then ignore (diag None "continue not in a loop")
      else (goto !continpc; incr ncontin; canreach := false)
  | Break ->
      if !breakpc < 0 then ignore (diag None "break not in a loop")
      (* an unreachable break makes no branch *)
      else if !canreach then (goto !breakpc; incr nbreak; canreach := false)
  | If (c, a, b) ->
      let c, dead = bcomplex c (Some (a, b)) in
      if dead then begin
        (* a constant: the dead side generated, and thrown away *)
        let f = match c.e with Fconst f -> f = 0. | Const v -> v = 0L | _ -> false in
        canreach := true;
        if f then (supgen (Some a); canreach := true; Option.iter gen b)
        else (gen a; let oldreach = !canreach in canreach := true; supgen b; canreach := oldreach)
      end
      else begin
        let sp = ref (p ()) in
        canreach := true;
        gen a;
        let oldreach = !canreach in
        canreach := true;
        Option.iter (fun b -> let q = gbranch () in here !sp; sp := q; gen b) b;
        here !sp;
        canreach := !canreach || oldreach
      end
  | Used l | Set l ->
      let set = match s with Set _ -> true | _ -> false in
      List.iter (fun x ->
        match Check.complex x with
        | { e = Name _; _ } as n when set -> ignore (gins "NOP" None (Some n))
        | { e = Name _ | Unary (Addr, _); _ } as n -> ignore (gins "NOP" (Some n) None)
        | _ -> ()) l

(* a loop's test, its false branch to the break *)
and test (l : expr) =
  let l, _ = bcomplex l None in
  patch (p ()) !breakpc;
  if not (is_const l) || Check.vconst l = 0 then incr nbreak

(* generated then thrown away: its strings and labels stay *)
and supgen (s : stmt option) =
  Option.iter (fun s ->
    incr suppress;
    let spc = !pc and sp = !progs in
    gen s;
    progs := sp;
    pc := spc;
    decr suppress) s

(*****************************************************************************)
(* A function (pgen.c's codgen) *)
(*****************************************************************************)

let codgen (fn : sym) (body : stmt) =
  cursafe := 0;
  curarg := 0;
  maxargsafe := 0;
  labels := [];
  let sp = gpseudo "TEXT" fn (iconst !Declare.stkoff) in
  sp.pseudo <- `Text (if !Pre.profile then 0 else 1);
  let ret = link (Option.get !Declare.thisfn) in
  (* the first argument arrives in a register: a structure's result's
   * address, or the first parameter if it fits one *)
  if (m ()).typecmplx ret.etype then begin
    let retname () = match (Option.get !nodret).e with Unary (Ind, x) -> x | _ -> assert false in
    if (match (retname ()).t.link with Some l -> l != ret | None -> true) then
      nodret := Some (Check.complex (mk (Unary (Ind, { (retname ()) with t = typ Tind (Some ret) }))));
    let nod1 = retname () in
    gmove (nodreg nod1 (bk ()).regret) nod1
  end
  else begin
    match !Declare.firstarg, !Declare.firstargtype with
    | Some s, Some ft when (m ()).typeword ft.etype ->
        let nod1 = xcom (name_of s ft Cparam (Declare.align 0 ft Aarg1)) in
        gmove (nodreg nod1 (bk ()).regret) nod1
    | _ -> ()
  end;
  canreach := true;
  gen body;
  if !canreach && ret.etype <> Tvoid then ignore (diag None "no return at end of function: %s" fn.name);
  noretval ~r:true ~f:true;
  ignore (greturn ());
  if not (arm ()) then maxargsafe := Declare.round !maxargsafe 8;
  sp.to_ <- add_off sp.to_ !maxargsafe
