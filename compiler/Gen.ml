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

(* the complexity of a call: more than any expression's *)
let fnx = 100

(* the addressable: a name, a register, a constant... (5c's INDEXED) *)
let indexed = 9

(* what differs between 5c's and 7c's generators, beyond the
 * instructions: set by the machine's module *)
type hooks = {
  sucopy : node -> node -> int -> unit;       (* a structure's copy *)
  swit : (int64 * int) array -> int -> node -> unit;   (* a switch's dispatch *)
  fits : node -> int -> bool;         (* an offset folded into n's load or store *)
  neg : node -> node -> unit;         (* to = -from *)
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
(* 64-bit arithmetic as calls, where the machine can't (com64.c) *)
(*****************************************************************************)

let fvns : (string * etype, node) Hashtbl.t = Hashtbl.create 64

(* libc's function name, as a node of a function returning et *)
let fvn name et =
  match Hashtbl.find_opt fvns (name, et) with
  | Some n -> n
  | None ->
      let n = node ONAME None None in
      n.nsym <- Some (lookup name);
      n.ntype <- Some (typ Tfunc (Some (ty et))); n.netype <- et; n.nclass <- Cglobl; n.addable <- 10;
      Hashtbl.replace fvns (name, et) n;
      n

let vbinops = [ OADD, "_addv"; OSUB, "_subv"; OMUL, "_mulv"; OLMUL, "_mulv"; ODIV, "_divv"; OLDIV, "_divvu"; OMOD, "_modv";
                OLMOD, "_modvu"; OASHL, "_lshv"; OASHR, "_rshav"; OLSHR, "_rshlv"; OAND, "_andv"; OOR, "_orv"; OXOR, "_xorv" ]
let asops = [ OASADD, OADD; OASSUB, OSUB; OASMUL, OMUL; OASLMUL, OLMUL; OASDIV, ODIV; OASLDIV, OLDIV; OASMOD, OMOD;
              OASLMOD, OLMOD; OASASHL, OASHL; OASASHR, OASHR; OASLSHR, OLSHR; OASAND, OAND; OASOR, OOR; OASXOR, OXOR ]
let is_rel o = Check.relindex_opt o <> None

(* a type's letters in the conversions' names: _sc2v, _v2sc *)
let vcodes = [ Tchar, "sc"; Tuchar, "uc"; Tshort, "sh"; Tushort, "uh"; Tint, "si"; Tuint, "ui"; Tlong, "sl"; Tulong, "ul";
               Tfloat, "f"; Tdouble, "d"; Tind, "p" ]

(* _vasop's code for the type of the left side *)
let etconv t = match List.assoc_opt t [ Tchar, 1; Tuchar, 2; Tshort, 3; Tushort, 4; Tlong, 5; Tulong, 6; Tvlong, 7; Tuvlong, 8; Tint, 9; Tuint, 10 ] with Some c -> c | None -> 0

let testv () = fvn "_testv" Tlong

let addr_of (x : node) = let a = node OADDR (Some x) None in a.ntype <- Some (typ Tind x.ntype); a.complex <- x.complex; a

(* n as a call to libc, where vlongs are the machine's (true if done) *)
let com64 (n : node) =
  let mc = (m ()).machcap (Some n) in
  let call a args = n.left <- Some a; n.right <- args; n.complex <- fnx; n.op <- OFUNC; true in
  let test (x : node) = let f = node OFUNC (Some (testv ())) (Some x) in f.complex <- fnx; f.ntype <- Some (ty Tlong); f in
  let isv (x : node option) = match x with Some { ntype = Some t; _ } -> typev t.etype | _ -> false in
  let l = n.left and r = n.right in
  let lv = isv l and rv = isv r in
  let logical = n.op = OANDAND || n.op = OOROR in
  match n.ntype with
  | None -> false
  | Some nt ->
      if lv && is_rel n.op then
        mc || (ignore (call (fvn ("_" ^ String.lowercase_ascii (opname n.op) ^ "v") Tlong) (Some (node OLIST l r))); n.ntype <- Some (ty Tlong); true)
      else if lv && (logical || n.op = OCOND || n.op = ONOT) then begin
        mc || begin
          if rv && logical then n.right <- Some (test (Option.get r));
          mc || (n.left <- Some (test (Option.get l)); n.complex <- fnx; true)
        end
      end
      else if rv && (mc || logical || n.op = OCOND) then ((if not mc && logical then n.right <- Some (test (Option.get r))); true)
      else if typev nt.etype then
        mc ||
        match n.op with
        | OFUNC -> n.complex <- fnx; true
        | ORETURN | OAS | OIND | OLIST | OCOMMA -> true
        | OPOSTINC | OPOSTDEC | OPREINC | OPREDEC ->
            let name = List.assoc n.op [ OPOSTINC, "_vpp"; OPOSTDEC, "_vmm"; OPREINC, "_ppv"; OPREDEC, "_mmv" ] in
            call (fvn name Tvlong) (Some (node OLIST (Some (addr_of (Option.get l))) r))
        | ONEG -> call (fvn "_negv" Tvlong) l
        | OCOM -> call (fvn "_comv" Tvlong) l
        | OCAST -> (
            let lt = et (Option.get l) in
            match List.assoc_opt lt vcodes with
            | Some code when List.mem lt [ Tchar; Tuchar; Tshort; Tushort ] ->
                (* a small one as a long first *)
                let c = node OCAST l None in
                c.ntype <- Some (ty Tlong); c.complex <- (Option.get l).complex;
                call (fvn ("_" ^ code ^ "2v") Tvlong) (Some c)
            | Some code -> call (fvn ("_" ^ code ^ "2v") Tvlong) l
            | None -> diag (Some n) "unknown %s->vlong cast" (show_type (Option.get l).ntype))
        | o when List.mem_assoc o vbinops -> call (fvn (List.assoc o vbinops) Tvlong) (Some (node OLIST l r))
        | o when List.mem_assoc o asops ->
            (* x op= y: _vasop(&x, fn, type, y) *)
            let a = fvn (List.assoc (List.assoc o asops) vbinops) Tvlong in
            let rec lhs (x : node) = if x.op = OFUNC then lhs (Tree.r x) else x in
            let x = lhs (Option.get l) in
            let c = node OCONST None None in
            c.vconst <- Int64.of_int (etconv (et x)); c.ntype <- Some (ty Tlong); c.addable <- 20;
            let args = node OLIST (Some (addr_of x)) (Some (node OLIST (Some { (addr_of a) with complex = 0 }) (Some (node OLIST (Some c) r)))) in
            call (fvn "_vasop" Tvlong) (Some args)
        | o -> diag (Some n) "unknown vlong %s" (opname o)
      else if n.op = OCAST && lv then
        mc ||
        (* _v2uh is _v2ul, as com64.c has it; a pointer is an unsigned long *)
        match nt.etype with
        | Tushort | Tind -> call (fvn "_v2ul" (if nt.etype = Tind then Tulong else Tushort)) l
        | t -> (match List.assoc_opt t vcodes with Some code -> call (fvn ("_v2" ^ code) t) l | None -> diag (Some n) "unknown vlong->%s cast" (show_type n.ntype))
      else false

(* a vlong tested as a condition *)
let bool64 (n : node) =
  if not ((m ()).machcap None) && typev (et n) then begin
    let n1 = dup n in
    n.right <- Some n1; n.left <- Some (testv ()); n.complex <- fnx; n.addable <- 0; n.op <- OFUNC; n.ntype <- Some (ty Tlong)
  end

(*****************************************************************************)
(* Addressability and complexity (sgen.c's xcom) *)
(*****************************************************************************)

(* (e shift c2) & c3 shift c1, with one shift or none (sub.c's
 * simplifyshift, 7c's): c3 is an unsigned long of 64 bits *)
let simplifyshift (n : node) =
  let kind (x : node) = match x.op with OASHL -> Some 0 | OLSHR -> Some 1 | OASHR -> Some 2 | _ -> None in
  let topbit v = let rec go i v = if v = 0L then i else go (i + 1) (Int64.shift_right_logical v 1) in go (-1) v in
  let is_const (x : node option) = match x with Some { op = OCONST; _ } -> true | _ -> false in
  match kind n with
  | Some s1 when typechlp (et n) && is_const n.right && (Tree.l n).op = OAND && is_const (Tree.l n).right
                 && is_const (Tree.l (Tree.l n)).right && kind (Tree.l (Tree.l n)) <> None ->
      let s2 = Option.get (kind (Tree.l (Tree.l n))) in
      let i32 v = Int64.to_int (sx32 v) in
      let c1 = i32 (Tree.r n).vconst and c2 = i32 (Tree.r (Tree.l (Tree.l n))).vconst and c3 = (Tree.r (Tree.l n)).vconst in
      (* get rid of both shifts, the lower, or the upper *)
      let rewrite0 c3 = copy_into n (Tree.l n); n.left <- (Tree.l n).left; (Tree.r n).vconst <- c3 in
      let rewrite1 c3 c1 o = let a = Tree.l n in a.left <- (Tree.l a).left; (Tree.r a).vconst <- c3; (Tree.r n).vconst <- Int64.of_int c1; n.op <- o in
      let rewrite2 c3 c1 o = copy_into n (Tree.l n); (Tree.r n).vconst <- c3; (Tree.r (Tree.l n)).vconst <- Int64.of_int c1; (Tree.l n).op <- o in
      let shl v k = Int64.shift_left v k and shr v k = Int64.shift_right_logical v k in
      let o = n.op in
      let case001 () =
        if c1 > c2 then rewrite1 (shl c3 c2) (c1 - c2) OASHL
        else (let c3 = shl c3 c1 in if c1 = c2 then rewrite0 c3 else rewrite2 c3 (c2 - c1) OLSHR)
      in
      let s11 () = if c1 + c2 < 32 then rewrite1 (shl c3 c2) (c1 + c2) OLSHR in
      let case010 () =
        let c3 = shr c3 c1 in
        if c1 = c2 then rewrite0 c3 else if c1 > c2 then rewrite2 c3 (c1 - c2) o else rewrite2 c3 (c2 - c1) OASHL
      in
      (match (s1 lsl 3) lor s2 with
       | 0o00 -> if c1 + c2 < 32 then rewrite1 (shr c3 c2) (c1 + c2) o
       | 0o02 -> if topbit c3 < 32 - c2 then case001 ()
       | 0o01 -> case001 ()
       | 0o22 -> if c2 > 0 && topbit c3 < 32 - c2 then s11 ()
       | 0o12 -> if topbit c3 < 32 - c2 then s11 ()
       | 0o21 -> if not (topbit c3 >= 31 && c2 <= 0) then s11 ()
       | 0o11 -> s11 ()
       | 0o20 -> if topbit c3 < 31 then case010 ()
       | 0o10 -> case010 ()
       | _ -> ())
  | _ -> ()

(* addressable: 20 a constant, 10 a name, 11 a register, 12 an indirect
 * register; 2 $name, 3 $(reg)+offset. complex: the registers needed.
 * And by a power of 2, a multiplication is a shift, an unsigned
 * division too, an unsigned remainder a mask *)
let rec xcom (n : node) =
  let l = n.left and r = n.right in
  n.addable <- 0;
  n.complex <- 0;
  Option.iter xcom l;
  Option.iter xcom r;
  let a (x : node option) = match x with Some x -> x.addable | None -> 0 in
  let pow2 (x : node option) o' ~mask =
    let x = Option.get x in
    let t = Check.vlog x in
    if t >= 0 then begin
      n.op <- o';
      if mask then x.vconst <- Int64.pred x.vconst else (x.vconst <- Int64.of_int t; x.ntype <- Some (ty Tint))
    end;
    t >= 0
  in
  let shifts () = if (h ()).shifts then simplifyshift n in
  (match n.op with
   | OCONST -> n.addable <- 20
   | OREGISTER -> n.addable <- 11
   | OINDREG -> n.addable <- 12
   | ONAME -> n.addable <- 10
   | OADDR -> if a l = 10 then n.addable <- 2 else if a l = 12 then n.addable <- 3
   | OIND -> if a l = 11 || a l = 3 then n.addable <- 12 else if a l = 2 then n.addable <- 10
   | OADD ->
       if a l = 20 && (a r = 2 || a r = 3) then n.addable <- a r;
       if a r = 20 && (a l = 2 || a l = 3) then n.addable <- a l
   | OASLMUL | OASMUL -> ignore (pow2 r OASASHL ~mask:false)
   | OMUL | OLMUL ->
       ignore (pow2 r OASHL ~mask:false);
       (* the constant on the left: swapped *)
       if pow2 l OASHL ~mask:false then (n.left <- r; n.right <- l; shifts ())
   | OASLDIV -> ignore (pow2 r OASLSHR ~mask:false)
   | OLDIV -> if pow2 r OLSHR ~mask:false then shifts ()
   | OLSHR | OASHL | OASHR -> shifts ()
   | OASLMOD -> ignore (pow2 r OASAND ~mask:true)
   | OLMOD -> ignore (pow2 r OAND ~mask:true)
   | _ -> ());
  if n.addable < 10 then begin
    (* claude: l and r as they are now: OMUL's swap changes them *)
    let l = n.left and r = n.right in
    (match l with Some l -> n.complex <- l.complex | None -> ());
    (match r with Some r -> n.complex <- (if r.complex = n.complex then r.complex + 1 else max r.complex n.complex) | None -> ());
    if n.complex = 0 then n.complex <- 1;
    let lconst () = (Option.get l).op = OCONST in
    if not ((h ()).com64 && com64 n) then
      match n.op with
      | OFUNC -> n.complex <- fnx
      (* the constant on the right, as an immediate; a relation reversed (7c) *)
      | OADD | OXOR | OAND | OOR -> if lconst () then (n.left <- r; n.right <- l)
      | (OEQ | ONE) when not (h ()).shifts -> if lconst () then (n.left <- r; n.right <- l)
      | o when is_rel o && (h ()).shifts -> if lconst () then (n.left <- r; n.right <- l; n.op <- Check.invrel.(Check.relindex o))
      | _ -> ()
  end

(*****************************************************************************)
(* Expressions (cgen.c) *)
(*****************************************************************************)

let gmove f t = (bk ()).gmove f t
let gopcode o f1 f2 t = (bk ()).gopcode o false f1 f2 t
let op2 o f t = gopcode o (Some f) None (Some t)                  (* t = t o f *)
let op3 o f m t = gopcode o (Some f) (Some m) (Some t)            (* t = m o f *)
let compare ?(tr = false) o f m = (bk ()).gopcode o tr (Some f) (Some m) None
let jump () = ignore (gbranch OGOTO)
let here q = patch q !pc
let iconst n = nodconst (Int64.of_int n)

(* the heavier side first: its value's register takes nn *)
let ordered (l : node) (r : node) f g = if l.complex >= r.complex then (let a = f () in a, g ()) else (let b = g () in f (), b)

exception Return

(* n into nn, or for its effects when nn is None; inrel, as a
 * comparison's operand *)
let rec cgen (n : node) (nn : node option) = cgenrel n nn false

(* the value of a comma list, the rest generated first *)
and uncomma (n : node option) = match n with Some ({ op = OCOMMA; _ } as n) -> cgen (Tree.l n) None; uncomma n.right | n -> n

and effects (l : node option) = Option.iter (fun l -> cgen l None) l

and cgenrel (n : node) (nn : node option) inrel =
  match n.ntype with
  | None -> ()
  | Some nt when (m ()).typecmplx nt.etype -> sugen n nn nt.width
  | Some _ when n.addable >= indexed -> Option.iter (gmove n) nn
  | Some _ ->
      let curs = !cursafe in
      (match cgen1 n nn inrel with () -> cursafe := curs | exception Return -> ())

(* both sides calls: the right one first, to a temporary; the tree
 * with the temporary as its right side *)
and spill_right (n : node) ~rel =
  let r = Tree.r n in
  let nod = regret r in
  cgenrel r (Some nod) rel;
  let nod1 = regsalloc r in
  gmove nod nod1;
  regfree nod;
  { n with right = Some nod1 }

(* an lvalue in a register unless it is addressable; its release *)
and lvalue (l : node) = if l.addable < indexed then reglcgen l None else l
and unlvalue (l : node) nod = if l.addable < indexed then regfree nod

(* c ? a : b, a and b generating themselves *)
and ifelse (c : node) a b =
  bcgen c true;
  let p1 = p () in
  a ();
  jump ();
  here p1;
  let p1 = p () in
  b ();
  here p1

and cgen1 (n : node) (nn : node option) inrel =
  let o = n.op in
  let l () = Tree.l n and r () = Tree.r n in
  if n.complex >= fnx && (l ()).complex >= fnx && (match n.right with Some r -> r.complex >= fnx | None -> false)
     && not (List.mem o [ OFUNC; OCOMMA; OANDAND; OOROR; OCOND; ODOT ]) && not (is_rel o && typesu (et (l ()))) then begin
    cgen (spill_right n ~rel:false) nn;
    raise Return
  end;
  let unary f = match nn with None -> effects n.left | Some nn -> f nn in
  let muldiv () =
    match nn with
    | None -> effects n.left; effects n.right
    | Some nn when (o = OMUL || o = OLMUL) && mulcon n nn -> ()
    | Some nn ->
        let l = l () and r = r () in
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
  let immediate () =
    if nn <> None && (r ()).op = OCONST && not (typefd (et n)) then begin
      cgen (l ()) nn;
      if (r ()).vconst <> 0L || o = OAND then gopcode o n.right None nn
    end
    else muldiv ()
  in
  (* l op= r: 7c's, r into the result's register and l loaded after,
   * converted if its type isn't the result's; 5c's, l into it *)
  let asop () =
    let l = l () and r = r () in
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
  match o with
  | OAS ->
      let l = l () and r = r () in
      if l.addable >= indexed && l.complex < fnx then begin
        if nn = None && r.addable >= indexed then gmove r l
        else begin
          let nod = if r.complex >= fnx && nn = None then regret r else regalloc r nn in
          cgen r (Some nod);
          gmove nod l;
          Option.iter (gmove nod) nn;
          regfree nod
        end
      end
      else if l.complex >= r.complex && r.addable >= indexed then begin
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
  | ODIV | OMOD when nn <> None && Check.vlog (r ()) >= 0 ->
      (* signed division by a power of 2 *)
      let nn = Option.get nn and t = Check.vlog (r ()) in
      cgen (l ()) (Some nn);
      compare OGE (nodconst 0L) nn;
      let p1 = p () in
      if o = ODIV then begin
        op2 OADD (iconst ((1 lsl t) - 1)) nn;
        here p1;
        op2 OASHR (iconst t) nn
      end
      else begin
        (h ()).neg nn nn;
        op2 OAND (iconst ((1 lsl t) - 1)) nn;
        (h ()).neg nn nn;
        jump ();
        here p1;
        let p1 = p () in
        op2 OAND (iconst ((1 lsl t) - 1)) nn;
        here p1
      end
  | OSUB when (h ()).rsb && nn <> None && (l ()).op = OCONST && not (typefd (et n)) -> cgen (r ()) nn; gopcode o None n.left nn
  | OADD | OSUB | OAND | OOR | OXOR | OLSHR | OASHL | OASHR -> immediate ()
  | OLMUL | OLDIV | OLMOD | OMUL | ODIV | OMOD -> muldiv ()
  (* only 7c's front end leaves them: 5c's makes them 0-x and -1^x *)
  | ONEG | OCOM -> unary (fun nn -> let nod = regalloc (l ()) (Some nn) in cgen (l ()) (Some nod); op2 o nod nod; gmove nod nn; regfree nod)
  | OASLSHR | OASASHL | OASASHR | OASAND | OASADD | OASSUB | OASXOR | OASOR
    when (r ()).op = OCONST && not (typefd (et (r ()))) && not (typefd (et n)) ->
      let l = l () in
      let nod2 = lvalue l in
      let nod = regalloc (if (h ()).by_left then l else r ()) nn in
      gmove nod2 nod;
      op2 o (r ()) nod;
      gmove nod nod2;
      regfree nod;
      unlvalue l nod2
  | OASLSHR | OASASHL | OASASHR | OASAND | OASADD | OASSUB | OASXOR | OASOR | OASLMUL | OASLDIV | OASLMOD | OASMUL
  | OASDIV | OASMOD -> asop ()
  | OADDR -> unary (fun nn -> lcgen (l ()) (Some nn))
  | OFUNC ->
      let l = Option.get (uncomma n.left) in
      if l.complex >= fnx then begin
        (* the function is itself computed by a call *)
        let ll = Tree.l l in
        let nod = regret ll in
        cgen ll (Some nod);
        let nod1 = regsalloc ll in
        gmove nod nod1;
        regfree nod;
        cgen { n with left = Some { l with left = Some nod1; complex = 1 } } nn;
        raise Return
      end;
      let regarg = (bk ()).regret in
      let o = !regs.(regarg) in
      gargs n.right;
      if l.addable < indexed then (let nod = reglcgen l None in gopcode OFUNC None None (Some nod); regfree nod)
      else gopcode OFUNC None None (Some l);
      if o <> !regs.(regarg) then !regs.(regarg) <- !regs.(regarg) - 1;
      Option.iter (fun nn -> let nod = regret n in gmove nod nn; regfree nod) nn
  | OIND ->
      unary (fun nn ->
        let nod = regialloc n (Some nn) in
        fold_offset (l ()) nod n (fun () -> cgen (l ()) (Some nod));
        regind nod n;
        gmove nod nn;
        regfree nod)
  | o when is_rel o -> if nn = None then (effects n.left; effects n.right) else boolgen n true nn
  | OANDAND | OOROR -> boolgen n true nn; if nn = None then here (p ())
  | ONOT -> unary (fun _ -> boolgen n true nn)
  | OCOMMA -> cgen (l ()) None; cgen (r ()) nn
  | OCAST ->
      unary (fun nnn ->
        let l = l () in
        if Check.nocast l.ntype n.ntype && Check.nocast n.ntype nnn.ntype then cgen l nn
        else begin
          let nod = regalloc l nn in
          cgen l (Some nod);
          let nod1 = regalloc n (Some nod) in
          if inrel then (bk ()).gmover nod nod1 else gmove nod nod1;
          gmove nod1 nnn;
          regfree nod1;
          regfree nod
        end)
  | ODOT -> dot n nn (fun nod -> cgen nod nn)
  | OCOND -> ifelse (l ()) (fun () -> cgen (Tree.l (r ())) nn) (fun () -> cgen (Tree.r (r ())) nn)
  | OPOSTINC | OPOSTDEC | OPREINC | OPREDEC ->
      let l = l () in
      let v = if et l = Tind then (link (t l)).width else 1 in
      let v = if o = OPOSTDEC || o = OPREDEC then - v else v in
      let post = (o = OPOSTINC || o = OPOSTDEC) && nn <> None in
      let nod2 = lvalue l in
      let nod = regalloc l nn in
      gmove nod2 nod;
      (* x++ into a new register, the old kept; ++x in place *)
      let into = if post then regalloc l None else nod in
      let middle = if post then Some nod else None in
      if typefd (et l) then begin
        let nod3 = regalloc l None in
        gmove (nodfconst (float_of_int (abs v))) nod3;
        gopcode (if v < 0 then OSUB else OADD) (Some nod3) middle (Some into);
        regfree nod3
      end
      else gopcode OADD (Some (iconst v)) middle (Some into);
      gmove into nod2;
      (* in x = ++i, USED(i) *)
      if not post && nn <> None && l.op = ONAME then ignore (gins "NOP" (Some l) None);
      regfree nod;
      if post then regfree into;
      unlvalue l nod2
  | o -> ignore (diag (Some n) "unknown op in cgen: %s" (opname o))

(* a constant offset at the end of an address folded into the load or
 * store (the constant zeroed while the rest is generated) *)
and fold_offset (x : node) (t : node) (n : node) gen =
  let rec right (x : node) = if x.op = OADD then right (Tree.r x) else x in
  let r = right x in
  if sconst r && (h ()).fits n (Int64.to_int r.vconst + t.xoffset) then begin
    let v = r.vconst in
    r.vconst <- 0L;
    gen ();
    t.xoffset <- t.xoffset + Int64.to_int v;
    r.vconst <- v
  end
  else gen ()

(* a structure's member: the structure into .rathole, then the member *)
and dot (n : node) (nn : node option) k =
  let l = Tree.l n in
  let rat = Option.get !nodrat in
  sugen l (Some rat) (t l).width;
  if nn <> None then
    match n.right with
    | Some ({ op = OCONST; _ } as r) -> k { rat with xoffset = rat.xoffset + Int64.to_int (sx32 r.vconst); ntype = n.ntype }
    | _ -> ignore (diag (Some n) "DOT and no offset")

(* constants that fit an instruction; the linker sorts out the rest *)
and sconst (n : node) = n.op = OCONST && not (typefd (et n))

(* the address of n, in a register, as an indirect node *)
and reglcgen (n : node) (nn : node option) =
  let t = regialloc n nn in
  (match n.op with
   | OIND -> fold_offset (Tree.l n) t n (fun () -> lcgen n (Some t))
   | OINDREG when (h ()).fits n (t.xoffset + n.xoffset) ->
       let v = n.xoffset and ty0 = n.ntype in
       n.op <- OREGISTER;
       if (h ()).indreg_ptr then (n.ntype <- Some (ty Tind); n.xoffset <- 0);
       cgen n (Some t);
       t.xoffset <- t.xoffset + v;
       n.op <- OINDREG;
       if (h ()).indreg_ptr then (n.ntype <- ty0; n.xoffset <- v)
   | _ -> lcgen n (Some t));
  regind t n;
  t

(* the address of nn as a long's, in a register (5c's reglpcgen) *)
and reglpcgen (nn : node) f =
  let ty0 = nn.ntype in
  nn.ntype <- Some (ty Tlong);
  let n = if f then reglcgen nn None else (let n = regialloc nn None in lcgen nn (Some n); regind n nn; n) in
  nn.ntype <- ty0;
  n

(* the address of n into nn *)
and lcgen (n : node) (nn : node option) =
  if n.ntype <> None then begin
    let nn = match nn with Some nn -> nn | None -> regalloc n None in
    match n.op with
    | OCOMMA -> cgen (Tree.l n) n.left; lcgen (Tree.r n) (Some nn)
    | OIND -> cgen (Tree.l n) (Some nn)
    | OCOND -> ifelse (Tree.l n) (fun () -> lcgen (Tree.l (Tree.r n)) (Some nn)) (fun () -> lcgen (Tree.r (Tree.r n)) (Some nn))
    | _ when n.addable < indexed -> ignore (diag (Some n) "unknown op in lcgen: %s" (opname n.op))
    | _ -> gmove { n with op = OADDR; left = Some n; right = None; ntype = Some (ty Tind) } nn
  end

and bcgen (n : node) tr = if n.ntype = None then jump () else boolgen n tr None

(* n as a condition: a branch taken if n is tr; into nn, 1 or 0 *)
and boolgen (n : node) tr (nn : node option) =
  let curs = !cursafe in
  let l () = Tree.l n and r () = Tree.r n in
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
  let caseand tr =
    bcgen (l ()) tr;
    let p1 = p () in
    bcgen (r ()) (not tr);
    let p2 = p () in
    here p1;
    jump ();
    here p2
  in
  let caseor tr =
    bcgen (l ()) (not tr);
    let p1 = p () in
    bcgen (r ()) (not tr);
    let p2 = p () in
    jump ();
    here p1;
    here p2
  in
  let rel o = if tr then Check.comrel.(Check.relindex o) else o in
  (match n.op with
   | OCONST ->
       jump ();
       if (Check.vconst (Some n) <> 0) = tr then (let p1 = p () in jump (); here p1);
       com ()
   | OCOMMA -> cgen (l ()) None; boolgen (r ()) tr nn
   | ONOT -> boolgen (l ()) (not tr) nn
   | OCOND ->
       bcgen (l ()) true;
       let p1 = p () in
       bcgen (Tree.l (r ())) tr;
       let p2 = p () in
       jump ();
       here p1;
       let p1 = p () in
       bcgen (Tree.r (r ())) (not tr);
       here p2;
       let p2 = p () in
       jump ();
       here p1;
       here p2;
       com ()
   | OANDAND -> (if tr then caseand else caseor) tr; com ()
   | OOROR -> (if tr then caseor else caseand) tr; com ()
   | o when is_rel o && (l ()).complex >= fnx && (r ()).complex >= fnx -> boolgen (spill_right n ~rel:true) tr nn
   | o when is_rel o ->
       let o = rel o and l = l () and r = r () in
       (* a constant compared: as an immediate *)
       let one_side (x : node) c o = let nod = regalloc x nn in cgenrel x (Some nod) true; compare ~tr o c nod; regfree nod in
       if sconst l then one_side r l Check.invrel.(Check.relindex o)
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
       if typefd (et n) then compare ~tr (rel ONE) (nodfconst 0.) nod else compare (rel ONE) (nodconst 0L) nod;
       regfree nod;
       com ());
  cursafe := curs

(* structures (and vlongs on arm), n into nn, w bytes *)
and sugen (n : node) (nn : node option) w =
  if n.ntype <> None then begin
    (match nn with Some x when x == Option.get !nodrat -> if w > !nrathole then nrathole := w | _ -> ());
    let rat = Option.get !nodrat in
    match n.op, nn with
    | (OIND | OCONST), None -> effects n.left
    | OCONST, Some nn when typev (et n) ->
        (* the two words *)
        let t0 = nn.ntype in
        nn.ntype <- Some (ty Tlong);
        let nod1 = reglcgen nn None in
        nn.ntype <- t0;
        gmove (nodconst (sx32 n.vconst)) nod1;
        nod1.xoffset <- nod1.xoffset + 4;
        gmove (nodconst (sx32 (Int64.shift_right n.vconst 32))) nod1;
        regfree nod1
    | ODOT, _ -> dot n nn (fun nod -> sugen nod nn w)
    | OSTRUCT, _ -> diag (Some n) "structure constructors are not in the subset"
    | OAS, None -> if n.addable < indexed then sugen (Tree.r n) n.left w
    | OAS, Some _ -> sugen (Tree.r n) (Some rat) w; sugen rat n.left w; sugen rat nn w
    | OFUNC, None -> sugen n (Some rat) w
    | OFUNC, Some nnn ->
        (* the result's address, as the first argument *)
        let a = if nnn.op <> OIND then (let a = node1 OADDR (Some nnn) None in a.ntype <- Some (ty Tind); a) else Tree.l nnn in
        let f = node OFUNC n.left (Some (node OLIST (Some a) n.right)) in
        f.ntype <- Some (ty Tvoid);
        (Tree.l f).ntype <- Some (ty Tvoid);
        cgen f None
    | OCOND, _ -> ifelse (Tree.l n) (fun () -> sugen (Tree.l (Tree.r n)) nn w) (fun () -> sugen (Tree.r (Tree.r n)) nn w)
    | OCOMMA, _ -> cgen (Tree.l n) None; sugen (Tree.r n) nn w
    | _, None -> ()
    | _, Some nn when n.complex >= fnx && nn.complex >= fnx ->
        (* the destination's address first, to a temporary *)
        let t0 = nn.ntype in
        nn.ntype <- Some (ty Tlong);
        let nod1 = regialloc nn None in
        lcgen nn (Some nod1);
        let nod2 = regsalloc nn in
        nn.ntype <- t0;
        gmove nod1 nod2;
        regfree nod1;
        nod2.ntype <- Some (typ Tind t0);
        sugen n (Some { nod2 with op = OIND; left = Some nod2; right = None; complex = 1; ntype = t0 }) w
    | _, Some nn -> (h ()).sucopy n nn w
  end

(*****************************************************************************)
(* Multiplication by a constant (swt.c's mulcon) *)
(*****************************************************************************)

and mulcon (n : node) (nn : node) =
  let l, r = if (Tree.l n).op = OCONST then Tree.r n, Tree.l n else Tree.l n, Tree.r n in
  let v = convvtox r.vconst (et n) in
  let v = if (h ()).mul32 then sx32 v else v in
  match Multiply.mulcon0 (Int64.to_int v) with
  | Some code when not (typefd (et n)) && r.op = OCONST && v = r.vconst ->
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
        | ('+' | '-') as c -> op3 (if c = '+' then OADD else OSUB) (pick (d land 1 <> 0)) (pick (d land 2 <> 0)) (pick (d land 4 <> 0))
        | c -> op3 OASHL (iconst (Char.code c - 97)) (pick (d land 1 <> 0)) (pick (d land 2 <> 0))
      done;
      regfree nod2;
      if Int64.compare v 0L < 0 then (gmove nod1 nod1; (h ()).neg nod1 nn) else gmove nod1 nn;
      regfree nod1;
      true
  | _ -> false

(*****************************************************************************)
(* Arguments (txt.c's gargs) *)
(*****************************************************************************)

(* the calls first, to temporaries; then the arguments, the first in a
 * register if it fits one *)
and gargs (n : node option) =
  let regs0 = !cursafe in
  let rec args (n : node option) = match n with None -> [] | Some ({ op = OLIST; _ } as n) -> args n.left @ args n.right | Some n -> [ n ] in
  let temps = List.map (fun (n : node) ->
    if n.complex >= fnx then begin
      let s = regsalloc n in
      let nod = node OAS (Some s) (Some n) in
      nod.ntype <- n.ntype;
      cgen nod None;
      s
    end
    else n) (args n) in
  curarg := 0;
  List.iter2 (fun (n : node) (src : node) ->
    if (m ()).typecmplx (et n) then (let tn2 = regaalloc n in sugen src (Some tn2) (t n).width)
    else if !curarg = 0 && (m ()).typeword (et n) then cgen src (Some (regaalloc1 n))
    else if (h ()).zero_arg && Check.vconst (Some n) = 0 then gmove n (regaalloc n)
    else begin
      let tn1 = regalloc n None in
      cgen src (Some tn1);
      gmove tn1 (regaalloc n);
      regfree tn1
    end) (args n) temps;
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

let noretval k =
  if k land 1 <> 0 then (gins "NOP" None None).to_ <- Some (Ix_asm.Asm.Reg (bk ()).regret);
  if k land 2 <> 0 then (gins "NOP" None None).to_ <- Some (Ix_asm.Asm.FReg (bk ()).fregret)

(* a statement no label enters (sub.c's deadhead) *)
let rec deadhead (n : node option) caseok =
  match n with
  | None -> true
  | Some n -> (
      match n.op with
      | OLIST -> deadhead n.left caseok && deadhead n.right caseok
      | OLABEL -> false
      | OCASE -> caseok && deadhead n.right caseok
      | OSWITCH -> deadhead n.right true
      | OWHILE | ODWHILE | OFOR -> deadhead n.right caseok
      | OIF -> deadhead (Tree.r n).left caseok && deadhead (Tree.r n).right caseok
      | _ -> true)

let deadheads (c : node) = deadhead c.left false && deadhead c.right false

(* a condition, as a branch taken when false; true if it is a constant
 * whose other side is dead code *)
let bcomplex (n : node) (c : node option) =
  Check.complex (Some n);
  if n.ntype <> None && Check.tcompat n None n.ntype tnot then n.ntype <- None;
  if n.ntype = None then (jump (); false)
  else if c <> None && n.op = OCONST && deadheads (Option.get c) then true
  else (bool64 n; boolgen n true None; false)

let add_case c = cases := Some (c :: Option.get !cases)

(* the cases, sorted, to the machine's dispatch (pswt.c's doswit) *)
let doswit (n : node) =
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
  (h ()).swit q def n

(* a label's last forward goto (5c's n->label) *)
let labels : (node * prog) list ref = ref []
let pending (l : node) = List.assq_opt l !labels

let goto target = patch (gbranch OGOTO) target

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

let rec gen (n : node option) =
  match n with
  | None -> ()
  | Some n ->
      nearln := n.lineno;
      match n.op with
      | OLIST | OCOMMA -> gen n.left; gen n.right
      | ORETURN ->
          canreach := false;
          Check.complex (Some n);
          if n.ntype <> None then begin
            (match uncomma n.left with
             | None -> noretval 3
             | Some l when (m ()).typecmplx (et n) ->
                 let nod = node OAS !nodret (Some l) in
                 nod.ntype <- n.ntype; nod.complex <- l.complex;
                 cgen nod None;
                 noretval 3
             | Some l ->
                 let nod = regret n in
                 cgen l (Some nod);
                 regfree nod;
                 noretval (if typefd (et n) then 1 else 2));
            ignore (gbranch ORETURN)
          end
      | OLABEL ->
          canreach := true;
          Option.iter (fun (l : node) -> l.pc <- !pc; Option.iter here (pending l)) n.left;
          (* no self reference *)
          goto (!pc + 1);
          gen n.right
      | OGOTO -> (
          canreach := false;
          match n.left with
          | Some l when l.complex = 0 -> ignore (diag None "label undefined: %s" (sym l).name)
          | Some l when !suppress = 0 ->
              let q = gbranch OGOTO in
              if l.pc <> 0 then patch q l.pc
              else begin
                (* the previous goto branches to this one, as 5c's *)
                Option.iter (fun prev -> patch prev (!pc - 1)) (pending l);
                labels := (l, q) :: List.filter (fun (x, _) -> x != l) !labels
              end
          | _ -> ())
      | OCASE ->
          canreach := true;
          if !cases = None then ignore (diag (Some n) "case/default outside a switch");
          (match n.left with
           | None -> add_case { cval = 0L; cdef = true; clabel = !pc; cisv = false }
           | Some l ->
               Check.complex (Some l);
               if l.ntype <> None then begin
                 if l.op <> OCONST || not ((m ()).typeswitch (et l)) then ignore (diag (Some n) "case expression must be integer constant")
                 else add_case { cval = l.vconst; cdef = false; clabel = !pc; cisv = typev (et l) }
               end);
          gen n.right
      | OSWITCH ->
          let l = Tree.l n in
          Check.complex (Some l);
          if l.ntype <> None then begin
            if not ((m ()).typeswitch (et l)) then ignore (diag (Some n) "switch expression must be integer");
            let sp = gbranch OGOTO in
            let cn = !cases in
            cases := Some [ { cval = 0L; cdef = false; clabel = 0; cisv = false } ];
            scoped ~contin:false (fun () ->
              breakpc := !pc;
              let spb = gbranch OGOTO in
              gen n.right;
              if !canreach then (goto !breakpc; incr nbreak);
              here sp;
              let nod = regalloc l None in
              (* always signed *)
              nod.ntype <- Some (ty (if typev (et l) then Tvlong else Tlong));
              cgen l (Some nod);
              doswit nod;
              regfree nod;
              here spb);
            cases := cn
          end
      | OWHILE | ODWHILE ->
          let l = Tree.l n in
          let sp = gbranch OGOTO in
          scoped ~contin:false (fun () ->
            continpc := !pc;
            let spc = gbranch OGOTO in
            breakpc := !pc;
            let spb = gbranch OGOTO in
            here spc;
            if n.op = OWHILE then here sp;
            test l;
            if n.op = ODWHILE then here sp;
            gen n.right;
            goto !continpc;
            here spb)
      | OFOR ->
          let l = Tree.l n in
          gen (Tree.r l).left;
          let sp = gbranch OGOTO in
          scoped ~contin:true (fun () ->
            continpc := !pc;
            let spc = gbranch OGOTO in
            breakpc := !pc;
            let spb = gbranch OGOTO in
            here spc;
            gen (Tree.r l).right;
            here sp;
            Option.iter test l.left;
            canreach := true;
            gen n.right;
            if !canreach then (goto !continpc; incr ncontin);
            here spb)
      | OCONTINUE ->
          if !continpc < 0 then ignore (diag (Some n) "continue not in a loop")
          else (goto !continpc; incr ncontin; canreach := false)
      | OBREAK ->
          if !breakpc < 0 then ignore (diag (Some n) "break not in a loop")
          (* an unreachable break makes no branch *)
          else if !canreach then (goto !breakpc; incr nbreak; canreach := false)
      | OIF ->
          let l = Tree.l n and r = Tree.r n in
          if bcomplex l n.right then begin
            (* a constant: the dead side generated, and thrown away *)
            let f = if typefd (et l) then l.fconst = 0. else l.vconst = 0L in
            canreach := true;
            if f then (supgen r.left; canreach := true; gen r.right)
            else (gen r.left; let oldreach = !canreach in canreach := true; supgen r.right; canreach := oldreach)
          end
          else begin
            let sp = ref (p ()) in
            canreach := true;
            gen r.left;
            let oldreach = !canreach in
            canreach := true;
            if r.right <> None then (let q = gbranch OGOTO in here !sp; sp := q; gen r.right);
            here !sp;
            canreach := !canreach || oldreach
          end
      | OSET | OUSED -> usedset n.left n.op
      | _ -> Check.complex (Some n); cgen n None

(* a loop's test, its false branch to the break *)
and test (l : node) =
  ignore (bcomplex l None);
  patch (p ()) !breakpc;
  if l.op <> OCONST || Check.vconst (Some l) = 0 then incr nbreak

(* generated then thrown away: its strings and labels stay *)
and supgen (n : node option) =
  if n <> None then begin
    incr suppress;
    let spc = !pc and sp = !progs in
    gen n;
    progs := sp;
    pc := spc;
    decr suppress
  end

and usedset (n : node option) o =
  match n with
  | Some ({ op = OLIST; _ } as n) -> usedset n.left o; usedset n.right o
  | Some n ->
      Check.complex (Some n);
      if n.op = OADDR || n.op = ONAME then ignore (if o = OSET && n.op = ONAME then gins "NOP" None (Some n) else gins "NOP" (Some n) None)
  | None -> ()

(*****************************************************************************)
(* A function (pgen.c's codgen) *)
(*****************************************************************************)

let codgen (body : node) (fn : node) =
  cursafe := 0;
  curarg := 0;
  maxargsafe := 0;
  labels := [];
  let rec name (n : node) = if n.op = ONAME then n else name (Tree.l n) in
  let n1 = name fn in
  nearln := fn.lineno;
  let sp = gpseudo "TEXT" (sym n1) (iconst !Declare.stkoff) in
  sp.pseudo <- `Text (if !Pre.profile then 0 else 1);
  let ret = link (Option.get !Declare.thisfn) in
  (* the first argument arrives in a register: a structure's result's
   * address, or the first parameter if it fits one *)
  if (m ()).typecmplx ret.etype then begin
    let n1 = Tree.l (Option.get !nodret) in
    if n1.ntype = None || link (t n1) != ret then begin
      n1.ntype <- Some (typ Tind (Some ret));
      n1.netype <- Tind;
      let r = node OIND (Some n1) None in
      Check.complex (Some r);
      nodret := Some r
    end;
    let nod1 = dup (Tree.l (Option.get !nodret)) in
    gmove (nodreg nod1 (bk ()).regret) nod1
  end
  else begin
    match !Declare.firstarg, !Declare.firstargtype with
    | Some s, Some ft when (m ()).typeword ft.etype ->
        let nod1 = node ONAME None None in
        nod1.nsym <- Some s; nod1.ntype <- Some ft; nod1.nclass <- Cparam;
        nod1.xoffset <- Declare.align 0 ft Declare.aarg1; nod1.netype <- ft.etype;
        xcom nod1;
        gmove (nodreg nod1 (bk ()).regret) nod1
    | _ -> ()
  end;
  canreach := true;
  gen (Some body);
  if !canreach && ret.etype <> Tvoid then ignore (diag None "no return at end of function: %s" (sym n1).name);
  noretval 3;
  ignore (gbranch ORETURN);
  if (bk ()).arch = Ix_asm.Asm.Arm64 then maxargsafe := Declare.round !maxargsafe 8;
  sp.to_ <- add_off sp.to_ !maxargsafe
