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

(* the machine's hooks that need the generator (a block copy, a
 * switch's dispatch): set by the machine's module *)
type hooks = {
  sucopy : node -> node -> int -> unit;
  swit : (int64 * int) array -> int -> node -> unit;
  imm_range : int;                    (* an offset folded into a load: |v| < this *)
}

let hooks : hooks option ref = ref None
let h () = Option.get !hooks

(*****************************************************************************)
(* 64-bit arithmetic as calls, where the machine can't (com64.c) *)
(*****************************************************************************)

let fvns : (string, node) Hashtbl.t = Hashtbl.create 64
let fntypes : (etype, typ) Hashtbl.t = Hashtbl.create 16

let fvn name et =
  match Hashtbl.find_opt fvns name with
  | Some n -> n
  | None ->
      let n = node ONAME None None in
      n.nsym <- Some (lookup name);
      let ft = match Hashtbl.find_opt fntypes et with Some t -> t | None -> let t = typ Tfunc (Some (ty et)) in Hashtbl.replace fntypes et t; t in
      n.ntype <- Some ft; n.netype <- et; n.nclass <- Cglobl; n.addable <- 10; n.complex <- 0;
      Hashtbl.replace fvns name n;
      n

(* _vasop's code for the type of the left side *)
let etconv = function
  | Tchar -> 1 | Tuchar -> 2 | Tshort -> 3 | Tushort -> 4 | Tlong -> 5 | Tulong -> 6 | Tvlong -> 7 | Tuvlong -> 8
  | Tint -> 9 | Tuint -> 10 | _ -> 0

let binop_fn = function
  | OADD | OASADD -> Some "_addv" | OSUB | OASSUB -> Some "_subv" | OMUL | OLMUL | OASMUL | OASLMUL -> Some "_mulv"
  | ODIV | OASDIV -> Some "_divv" | OLDIV | OASLDIV -> Some "_divvu" | OMOD | OASMOD -> Some "_modv"
  | OLMOD | OASLMOD -> Some "_modvu" | OASHL | OASASHL -> Some "_lshv" | OASHR | OASASHR -> Some "_rshav"
  | OLSHR | OASLSHR -> Some "_rshlv" | OAND | OASAND -> Some "_andv" | OOR | OASOR -> Some "_orv"
  | OXOR | OASXOR -> Some "_xorv" | _ -> None

let rel_fn = function
  | OEQ -> Some "_eqv" | ONE -> Some "_nev" | OLE -> Some "_lev" | OLT -> Some "_ltv" | OGE -> Some "_gev"
  | OGT -> Some "_gtv" | OHI -> Some "_hiv" | OHS -> Some "_hsv" | OLO -> Some "_lov" | OLS -> Some "_lsv" | _ -> None

let to_v = function
  | Tchar -> Some ("_sc2v", true) | Tuchar -> Some ("_uc2v", true) | Tshort -> Some ("_sh2v", true) | Tushort -> Some ("_uh2v", true)
  | Tint -> Some ("_si2v", false) | Tuint -> Some ("_ui2v", false) | Tlong -> Some ("_sl2v", false) | Tulong -> Some ("_ul2v", false)
  | Tfloat -> Some ("_f2v", false) | Tdouble -> Some ("_d2v", false) | Tind -> Some ("_p2v", false) | _ -> None

(* _v2uh is _v2ul, as com64.c has it *)
let of_v = function
  | Tdouble -> Some ("_v2d", Tdouble) | Tfloat -> Some ("_v2f", Tfloat) | Tlong -> Some ("_v2sl", Tlong) | Tulong -> Some ("_v2ul", Tulong)
  | Tint -> Some ("_v2si", Tint) | Tuint -> Some ("_v2ui", Tuint) | Tshort -> Some ("_v2sh", Tshort) | Tushort -> Some ("_v2ul", Tushort)
  | Tchar -> Some ("_v2sc", Tchar) | Tuchar -> Some ("_v2uc", Tuchar) | Tind -> Some ("_v2ul", Tulong) | _ -> None

let testv () = fvn "_testv" Tlong

(* true if n is done (a call now, or the machine's) *)
let com64 (n : node) =
  let mc = (m ()).machcap in
  let call a args = n.left <- Some a; n.right <- args; n.complex <- fnx; n.op <- OFUNC; true in
  let test (x : node) = let f = node OFUNC (Some (testv ())) (Some x) in f.complex <- fnx; f.ntype <- Some (ty Tlong); f in
  match n.ntype with
  | None -> false
  | Some nt ->
      let l = n.left and r = n.right in
      let isv = function Some (x : node) -> (match x.ntype with Some t -> typev t.etype | None -> false) | None -> false in
      let lv = isv l and rv = isv r in
      let bop name = call (fvn name Tvlong) (Some (node OLIST l r)) in
      if lv && rel_fn n.op <> None then begin
        if mc (Some n) then true
        else (ignore (call (fvn (Option.get (rel_fn n.op)) Tlong) (Some (node OLIST l r))); n.ntype <- Some (ty Tlong); true)
      end
      else if lv && (match n.op with OANDAND | OOROR | OCOND | ONOT -> true | _ -> false) then begin
        if mc (Some n) then true
        else begin
          if rv && (n.op = OANDAND || n.op = OOROR) then n.right <- Some (test (Option.get r));
          if mc (Some n) then true
          else (n.left <- Some (test (Option.get l)); n.complex <- fnx; true)
        end
      end
      else if rv && mc (Some n) then true
      else if rv && (n.op = OANDAND || n.op = OOROR) then (n.right <- Some (test (Option.get r)); true)
      else if rv && n.op = OCOND then true
      else if typev nt.etype then begin
        if mc (Some n) then true
        else
          match n.op with
          | OFUNC -> n.complex <- fnx; true
          | ORETURN | OAS | OIND | OLIST | OCOMMA -> true
          | OPOSTINC | OPOSTDEC | OPREINC | OPREDEC ->
              let name = match n.op with OPOSTINC -> "_vpp" | OPOSTDEC -> "_vmm" | OPREINC -> "_ppv" | _ -> "_mmv" in
              let ll = Option.get l in
              let a = node OADDR l None in
              a.ntype <- Some (typ Tind ll.ntype); a.complex <- ll.complex;
              call (fvn name Tvlong) (Some (node OLIST (Some a) r))
          | ONEG -> call (fvn "_negv" Tvlong) l
          | OCOM -> call (fvn "_comv" Tvlong) l
          | OCAST -> (
              match to_v (et (Option.get l)) with
              | Some (name, true) ->
                  let ll = Option.get l in
                  let c = node OCAST l None in
                  c.ntype <- Some (ty Tlong); c.complex <- ll.complex;
                  call (fvn name Tvlong) (Some c)
              | Some (name, false) -> call (fvn name Tvlong) l
              | None -> diag (Some n) "unknown %s->vlong cast" (show_type (Option.get l).ntype))
          | o when binop_fn o <> None && (match o with OADD | OSUB | OMUL | OLMUL | ODIV | OLDIV | OMOD | OLMOD | OASHL | OASHR | OLSHR | OAND | OOR | OXOR -> true | _ -> false) ->
              bop (Option.get (binop_fn o))
          | o when binop_fn o <> None ->
              (* x op= y: _vasop(&x, fn, type, y) *)
              let a = fvn (Option.get (binop_fn o)) Tvlong in
              let rec lhs (x : node) = if x.op = OFUNC then lhs (Tree.r x) else x in
              let ll = lhs (Option.get l) in
              let c = node OCONST None None in
              c.vconst <- Int64.of_int (etconv (et ll)); c.ntype <- Some (ty Tlong); c.addable <- 20;
              let rr = node OLIST (Some c) r in
              let fa = node OADDR (Some a) None in
              fa.ntype <- Some (typ Tind a.ntype);
              let rr = node OLIST (Some fa) (Some rr) in
              let la = node OADDR (Some ll) None in
              la.ntype <- Some (typ Tind ll.ntype); la.complex <- ll.complex;
              call (fvn "_vasop" Tvlong) (Some (node OLIST (Some la) (Some rr)))
          | o -> diag (Some n) "unknown vlong %s" (opname o)
      end
      else if n.op = OCAST && lv then begin
        if mc (Some n) then true
        else
          match of_v nt.etype with
          | Some (name, ret) -> call (fvn name ret) l
          | None -> diag (Some n) "unknown vlong->%s cast" (show_type n.ntype)
      end
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

(* addressable: 20 a constant, 10 a name, 11 a register, 12 an indirect
 * register; 2 $name, 3 $(reg)+offset. complex: the registers needed *)
let rec xcom (n : node) =
  let l = n.left and r = n.right in
  n.addable <- 0;
  n.complex <- 0;
  let both () = Option.iter xcom l; Option.iter xcom r in
  let pow2 (x : node) = Check.vlog x in
  let a (x : node option) = match x with Some x -> x.addable | None -> 0 in
  (match n.op with
   | OCONST -> n.addable <- 20
   | OREGISTER -> n.addable <- 11
   | OINDREG -> n.addable <- 12
   | ONAME -> n.addable <- 10
   | OADDR -> both (); if a l = 10 then n.addable <- 2; if a l = 12 then n.addable <- 3
   | OIND -> both (); if a l = 11 || a l = 3 then n.addable <- 12; if a l = 2 then n.addable <- 10
   | OADD ->
       both ();
       if a l = 20 && (a r = 2 || a r = 3) then n.addable <- a r;
       if a r = 20 && (a l = 2 || a l = 3) then n.addable <- a l
   | OASLMUL | OASMUL -> both (); let t = pow2 (Option.get r) in if t >= 0 then (n.op <- OASASHL; (Option.get r).vconst <- Int64.of_int t; (Option.get r).ntype <- Some (ty Tint))
   | OMUL | OLMUL ->
       both ();
       let t = pow2 (Option.get r) in
       if t >= 0 then (n.op <- OASHL; (Option.get r).vconst <- Int64.of_int t; (Option.get r).ntype <- Some (ty Tint));
       let t = pow2 (Option.get l) in
       if t >= 0 then begin
         n.op <- OASHL;
         n.left <- r; n.right <- l;
         (Option.get l).vconst <- Int64.of_int t; (Option.get l).ntype <- Some (ty Tint)
       end
   | OASLDIV -> both (); let t = pow2 (Option.get r) in if t >= 0 then (n.op <- OASLSHR; (Option.get r).vconst <- Int64.of_int t; (Option.get r).ntype <- Some (ty Tint))
   | OLDIV -> both (); let t = pow2 (Option.get r) in if t >= 0 then (n.op <- OLSHR; (Option.get r).vconst <- Int64.of_int t; (Option.get r).ntype <- Some (ty Tint))
   | OASLMOD -> both (); if pow2 (Option.get r) >= 0 then (n.op <- OASAND; (Option.get r).vconst <- Int64.pred (Option.get r).vconst)
   | OLMOD -> both (); if pow2 (Option.get r) >= 0 then (n.op <- OAND; (Option.get r).vconst <- Int64.pred (Option.get r).vconst)
   | _ -> both ());
  if n.addable < 10 then begin
    (* claude: l and r as they are now: OMUL's swap changes them *)
    let l = n.left and r = n.right in
    (match l with Some l -> n.complex <- l.complex | None -> ());
    (match r with
     | Some r -> if r.complex = n.complex then n.complex <- r.complex + 1 else if r.complex > n.complex then n.complex <- r.complex
     | None -> ());
    if n.complex = 0 then n.complex <- 1;
    if not (com64 n) then
      match n.op with
      | OFUNC -> n.complex <- fnx
      | OADD | OXOR | OAND | OOR | OEQ | ONE ->
          (* the constant on the right, as an immediate *)
          if (Option.get l).op = OCONST then (n.left <- r; n.right <- l)
      | _ -> ()
  end

(*****************************************************************************)
(* Expressions (cgen.c) *)
(*****************************************************************************)

let gmove f t = (bk ()).gmove f t
let gopcode o f1 f2 t = (bk ()).gopcode o false f1 f2 t
let gopcodet o tr f1 f2 t = (bk ()).gopcode o tr f1 f2 t
let rel_tab o = let i = Check.relindex o in i

exception Return

let rec cgen (n : node) (nn : node option) = cgenrel n nn false

and nullwarn (l : node option) (r : node option) =
  Option.iter (fun l -> cgen l None) l;
  Option.iter (fun r -> cgen r None) r

and cgenrel (n : node) (nn : node option) inrel =
  match n.ntype with
  | None -> ()
  | Some nt when typesuv nt.etype -> sugen n nn nt.width
  | Some _ ->
      let o = n.op in
      if n.addable >= indexed then begin
        match nn with
        | None -> (match o with OINDEX -> nullwarn n.left n.right | _ -> ())
        | Some nn -> gmove n nn
      end
      else begin
        let curs = !cursafe in
        match cgen1 n nn inrel with
        | () -> cursafe := curs
        | exception Return -> ()
      end

and cgen1 (n : node) (nn : node option) inrel =
  let o = n.op in
  let l () = Tree.l n and r () = Tree.r n in
  (* both sides calls: the right one first, to a temporary *)
  if n.complex >= fnx && (l ()).complex >= fnx && (match n.right with Some r -> r.complex >= fnx | None -> false)
     && not (match o with OFUNC | OCOMMA | OANDAND | OOROR | OCOND | ODOT -> true | _ -> false) then begin
    let nod = regret (r ()) in
    cgen (r ()) (Some nod);
    let nod1 = regsalloc (r ()) in
    gopcode OAS (Some nod) None (Some nod1);
    regfree nod;
    let nod = dup n in
    nod.right <- Some nod1;
    cgen nod nn;
    raise Return
  end;
  let nnv () = Option.get nn in
  let muldiv () =
    match nn with
    | None -> nullwarn n.left n.right
    | Some nn ->
        if (o = OMUL || o = OLMUL) && mulcon n nn then ()
        else begin
          let l = l () and r = r () in
          let nod, nod1 =
            if l.complex >= r.complex then begin
              let nod = regalloc l (Some nn) in
              cgen l (Some nod);
              let nod1 = regalloc r None in
              cgen r (Some nod1);
              gopcode o (Some nod1) None (Some nod);
              nod, nod1
            end
            else begin
              let nod = regalloc r (Some nn) in
              cgen r (Some nod);
              let nod1 = regalloc l None in
              cgen l (Some nod1);
              gopcode o (Some nod) (Some nod1) (Some nod);
              nod, nod1
            end
          in
          gopcode OAS (Some nod) None (Some nn);
          regfree nod;
          regfree nod1
        end
  in
  let immediate () =
    if nn <> None && (r ()).op = OCONST && not (typefd (et n)) then begin
      cgen (l ()) nn;
      if (r ()).vconst = 0L && o <> OAND then () else gopcode o n.right None nn
    end
    else muldiv ()
  in
  (* l op= r *)
  let asop () =
    let l = l () and r = r () in
    let nod2, nod1 =
      if l.complex >= r.complex then begin
        let nod2 = if l.addable < indexed then reglcgen l None else l in
        let nod1 = regalloc r None in
        cgen r (Some nod1);
        nod2, nod1
      end
      else begin
        let nod1 = regalloc r None in
        cgen r (Some nod1);
        let nod2 = if l.addable < indexed then reglcgen l None else l in
        nod2, nod1
      end
    in
    let nod = regalloc n nn in
    gmove nod2 nod;
    gopcode o (Some nod1) None (Some nod);
    gmove nod nod2;
    if nn <> None then gopcode OAS (Some nod) None nn;
    regfree nod;
    regfree nod1;
    if l.addable < indexed then regfree nod2
  in
  match o with
  | OAS ->
      let l = l () and r = r () in
      if l.op = OBIT then diag (Some n) "bitfields are not in the subset"
      else if l.addable >= indexed && l.complex < fnx then begin
        if nn <> None || r.addable < indexed then begin
          let nod = if r.complex >= fnx && nn = None then regret r else regalloc r nn in
          cgen r (Some nod);
          gmove nod l;
          (match nn with Some nn -> gmove nod nn | None -> ());
          regfree nod
        end
        else gmove r l
      end
      else if l.complex >= r.complex then begin
        let nod1 = reglcgen l None in
        if r.addable >= indexed then begin
          gmove r nod1;
          (match nn with Some nn -> gmove r nn | None -> ());
          regfree nod1
        end
        else begin
          let nod = regalloc r nn in
          cgen r (Some nod);
          gmove nod nod1;
          regfree nod;
          regfree nod1
        end
      end
      else begin
        let nod = regalloc r nn in
        cgen r (Some nod);
        let nod1 = reglcgen l None in
        gmove nod nod1;
        regfree nod;
        regfree nod1
      end
  | ODIV | OMOD ->
      let t = if nn <> None then Check.vlog (Tree.r n) else -1 in
      if t >= 0 then begin
        (* signed division by a power of 2 *)
        let nn = nnv () in
        cgen (l ()) (Some nn);
        gopcode OGE (Some (nodconst 0L)) (Some nn) None;
        let p1 = p () in
        let mask = nodconst (Int64.of_int ((1 lsl t) - 1)) in
        if o = ODIV then begin
          gopcode OADD (Some mask) None (Some nn);
          patch p1 !pc;
          gopcode OASHR (Some (nodconst (Int64.of_int t))) None (Some nn)
        end
        else begin
          gopcode OSUB (Some nn) (Some (nodconst 0L)) (Some nn);
          gopcode OAND (Some mask) None (Some nn);
          gopcode OSUB (Some nn) (Some (nodconst 0L)) (Some nn);
          ignore (gbranch OGOTO);
          patch p1 !pc;
          let p1 = p () in
          gopcode OAND (Some (nodconst (Int64.of_int ((1 lsl t) - 1)))) None (Some nn);
          patch p1 !pc
        end
      end
      else muldiv ()
  | OSUB ->
      if nn <> None && (l ()).op = OCONST && not (typefd (et n)) then (cgen (r ()) nn; gopcode o None n.left nn)
      else immediate ()
  | OADD | OAND | OOR | OXOR | OLSHR | OASHL | OASHR -> immediate ()
  | OLMUL | OLDIV | OLMOD | OMUL -> muldiv ()
  | OASLSHR | OASASHL | OASASHR | OASAND | OASADD | OASSUB | OASXOR | OASOR ->
      let l = l () and r = r () in
      if l.op = OBIT then diag (Some n) "bitfields are not in the subset"
      else if r.op = OCONST && not (typefd (et r)) && not (typefd (et n)) then begin
        let nod2 = if l.addable < indexed then reglcgen l None else l in
        let nod = regalloc r nn in
        gopcode OAS (Some nod2) None (Some nod);
        gopcode o (Some r) None (Some nod);
        gopcode OAS (Some nod) None (Some nod2);
        regfree nod;
        if l.addable < indexed then regfree nod2
      end
      else asop ()
  | OASLMUL | OASLDIV | OASLMOD | OASMUL | OASDIV | OASMOD ->
      if (l ()).op = OBIT then diag (Some n) "bitfields are not in the subset" else asop ()
  | OADDR -> (match nn with None -> nullwarn n.left None | Some nn -> lcgen (l ()) (Some nn))
  | OFUNC ->
      let l = l () in
      if l.complex >= fnx then begin
        (* the function is itself computed by a call *)
        if l.op <> OIND then ignore (diag (Some n) "bad function call");
        let ll = Tree.l l in
        let nod = regret ll in
        cgen ll (Some nod);
        let nod1 = regsalloc ll in
        gopcode OAS (Some nod) None (Some nod1);
        regfree nod;
        let nod2 = dup l in
        nod2.left <- Some nod1; nod2.complex <- 1;
        let nod = dup n in
        nod.left <- Some nod2;
        cgen nod nn;
        raise Return
      end;
      let regarg = (bk ()).regret in
      let o = !regs.(regarg) in
      gargs n.right;
      if l.addable < indexed then begin
        let nod = reglcgen l None in
        gopcode OFUNC None None (Some nod);
        regfree nod
      end
      else gopcode OFUNC None None (Some l);
      if o <> !regs.(regarg) then !regs.(regarg) <- !regs.(regarg) - 1;
      (match nn with
       | Some nn -> let nod = regret n in gopcode OAS (Some nod) None (Some nn); regfree nod
       | None -> ())
  | OIND -> (
      match nn with
      | None -> nullwarn n.left None
      | Some nn ->
          let nod = regialloc n (Some nn) in
          let rec right (x : node) = if x.op = OADD then right (Tree.r x) else x in
          let r = right (l ()) in
          let lim = (h ()).imm_range in
          if sconst r && (let v = Int64.to_int r.vconst + nod.xoffset in v > - lim && v < lim) then begin
            let v = r.vconst in
            r.vconst <- 0L;
            cgen (l ()) (Some nod);
            nod.xoffset <- nod.xoffset + Int64.to_int v;
            r.vconst <- v
          end
          else cgen (l ()) (Some nod);
          regind nod n;
          gopcode OAS (Some nod) None (Some nn);
          regfree nod)
  | OEQ | ONE | OLE | OLT | OGE | OGT | OLO | OLS | OHI | OHS -> (
      match nn with None -> nullwarn n.left n.right | Some _ -> boolgen n true nn)
  | OANDAND | OOROR -> boolgen n true nn; if nn = None then patch (p ()) !pc
  | ONOT -> (match nn with None -> nullwarn n.left None | Some _ -> boolgen n true nn)
  | OCOMMA -> cgen (l ()) None; cgen (r ()) nn
  | OCAST -> (
      match nn with
      | None -> nullwarn n.left None
      | Some nnn ->
          let l = l () in
          if Check.nocast l.ntype n.ntype && Check.nocast n.ntype nnn.ntype then cgen l nn
          else begin
            let nod = regalloc l nn in
            cgen l (Some nod);
            let nod1 = regalloc n (Some nod) in
            if inrel then (bk ()).gmover nod nod1 else gopcode OAS (Some nod) None (Some nod1);
            gopcode OAS (Some nod1) None nn;
            regfree nod1;
            regfree nod
          end)
  | ODOT ->
      let l = l () in
      let rat = Option.get !nodrat in
      sugen l (Some rat) (t l).width;
      (match nn with
       | Some _ ->
           let nod = dup rat in
           (match n.right with
            | Some ({ op = OCONST; _ } as r) ->
                nod.xoffset <- nod.xoffset + Int64.to_int (sx32 r.vconst);
                nod.ntype <- n.ntype;
                cgen nod nn
            | _ -> ignore (diag (Some n) "DOT and no offset"))
       | None -> ())
  | OCOND ->
      bcgen (l ()) true;
      let p1 = p () in
      cgen (Tree.l (r ())) nn;
      ignore (gbranch OGOTO);
      patch p1 !pc;
      let p1 = p () in
      cgen (Tree.r (r ())) nn;
      patch p1 !pc
  | OPOSTINC | OPOSTDEC | OPREINC | OPREDEC ->
      let l = l () in
      let v = if et l = Tind then (link (t l)).width else 1 in
      let v = if o = OPOSTDEC || o = OPREDEC then - v else v in
      if l.op = OBIT then diag (Some n) "bitfields are not in the subset"
      else if (o = OPOSTINC || o = OPOSTDEC) && nn <> None then begin
        let nod2 = if l.addable < indexed then reglcgen l None else l in
        let nod = regalloc l nn in
        gopcode OAS (Some nod2) None (Some nod);
        let nod1 = regalloc l None in
        if typefd (et l) then begin
          let nod3 = regalloc l None in
          if v < 0 then (gopcode OAS (Some (nodfconst (float_of_int (- v)))) None (Some nod3); gopcode OSUB (Some nod3) (Some nod) (Some nod1))
          else (gopcode OAS (Some (nodfconst (float_of_int v))) None (Some nod3); gopcode OADD (Some nod3) (Some nod) (Some nod1));
          regfree nod3
        end
        else gopcode OADD (Some (nodconst (Int64.of_int v))) (Some nod) (Some nod1);
        gopcode OAS (Some nod1) None (Some nod2);
        regfree nod;
        regfree nod1;
        if l.addable < indexed then regfree nod2
      end
      else begin
        let nod2 = if l.addable < indexed then reglcgen l None else l in
        let nod = regalloc l nn in
        gopcode OAS (Some nod2) None (Some nod);
        if typefd (et l) then begin
          let nod3 = regalloc l None in
          if v < 0 then (gopcode OAS (Some (nodfconst (float_of_int (- v)))) None (Some nod3); gopcode OSUB (Some nod3) None (Some nod))
          else (gopcode OAS (Some (nodfconst (float_of_int v))) None (Some nod3); gopcode OADD (Some nod3) None (Some nod));
          regfree nod3
        end
        else gopcode OADD (Some (nodconst (Int64.of_int v))) None (Some nod);
        gopcode OAS (Some nod) None (Some nod2);
        (* in x = ++i, USED(i) *)
        if nn <> None && l.op = ONAME then ignore (gins "NOP" (Some l) None);
        regfree nod;
        if l.addable < indexed then regfree nod2
      end
  | o -> ignore (diag (Some n) "unknown op in cgen: %s" (opname o))

(* constants that fit an instruction; the linker sorts out the rest *)
and sconst (n : node) = n.op = OCONST && not (typefd (et n))

(* the address of n, in a register, as an indirect node *)
and reglcgen (n : node) (nn : node option) =
  let t = regialloc n nn in
  let lim = (h ()).imm_range in
  let rec right (x : node) = if x.op = OADD then right (Tree.r x) else x in
  (match n.op with
   | OIND when (let r = right (Tree.l n) in sconst r && (let v = Int64.to_int r.vconst + t.xoffset in v > - lim && v < lim)) ->
       let r = right (Tree.l n) in
       let v = r.vconst in
       r.vconst <- 0L;
       lcgen n (Some t);
       t.xoffset <- t.xoffset + Int64.to_int v;
       r.vconst <- v
   | OINDREG when n.xoffset > - lim && n.xoffset < lim ->
       let v = n.xoffset in
       n.op <- OREGISTER;
       cgen n (Some t);
       t.xoffset <- t.xoffset + v;
       n.op <- OINDREG
   | _ -> lcgen n (Some t));
  regind t n;
  t

and reglpcgen (nn : node) f =
  let ty0 = nn.ntype in
  nn.ntype <- Some (ty Tlong);
  let n =
    if f then reglcgen nn None
    else (let n = regialloc nn None in lcgen nn (Some n); regind n nn; n)
  in
  nn.ntype <- ty0;
  n

(* the address of n into nn *)
and lcgen (n : node) (nn : node option) =
  match n.ntype with
  | None -> ()
  | Some _ ->
      let nn = match nn with Some nn -> nn | None -> regalloc n None in
      match n.op with
      | OCOMMA -> cgen (Tree.l n) n.left; lcgen (Tree.r n) (Some nn)
      | OIND -> cgen (Tree.l n) (Some nn)
      | OCOND ->
          bcgen (Tree.l n) true;
          let p1 = p () in
          lcgen (Tree.l (Tree.r n)) (Some nn);
          ignore (gbranch OGOTO);
          patch p1 !pc;
          let p1 = p () in
          lcgen (Tree.r (Tree.r n)) (Some nn);
          patch p1 !pc
      | _ ->
          if n.addable < indexed then ignore (diag (Some n) "unknown op in lcgen: %s" (opname n.op))
          else begin
            let nod = dup n in
            nod.op <- OADDR; nod.left <- Some n; nod.right <- None; nod.ntype <- Some (ty Tind);
            gopcode OAS (Some nod) None (Some nn)
          end

and bcgen (n : node) tr = if n.ntype = None then ignore (gbranch OGOTO) else boolgen n tr None

(* n as a condition: a branch taken if n is tr; into nn, 1 or 0 *)
and boolgen (n : node) tr (nn : node option) =
  let curs = !cursafe in
  let l () = Tree.l n and r () = Tree.r n in
  let com () =
    match nn with
    | Some _ ->
        let p1 = p () in
        gopcode OAS (Some (nodconst 1L)) None nn;
        ignore (gbranch OGOTO);
        let p2 = p () in
        patch p1 !pc;
        gopcode OAS (Some (nodconst 0L)) None nn;
        patch p2 !pc
    | None -> ()
  in
  let caseand tr =
    bcgen (l ()) tr;
    let p1 = p () in
    bcgen (r ()) (not tr);
    let p2 = p () in
    patch p1 !pc;
    ignore (gbranch OGOTO);
    patch p2 !pc;
    com ()
  in
  let caseor tr =
    bcgen (l ()) (not tr);
    let p1 = p () in
    bcgen (r ()) (not tr);
    let p2 = p () in
    ignore (gbranch OGOTO);
    patch p1 !pc;
    patch p2 !pc;
    com ()
  in
  (match n.op with
   | OCONST ->
       let v = Check.vconst (Some n) <> 0 in
       let v = if tr then v else not v in
       ignore (gbranch OGOTO);
       if v then (let p1 = p () in ignore (gbranch OGOTO); patch p1 !pc);
       com ()
   | OCOMMA -> cgen (l ()) None; boolgen (r ()) tr nn
   | ONOT -> boolgen (l ()) (not tr) nn
   | OCOND ->
       bcgen (l ()) true;
       let p1 = p () in
       bcgen (Tree.l (r ())) tr;
       let p2 = p () in
       ignore (gbranch OGOTO);
       patch p1 !pc;
       let p1 = p () in
       bcgen (Tree.r (r ())) (not tr);
       patch p2 !pc;
       let p2 = p () in
       ignore (gbranch OGOTO);
       patch p1 !pc;
       patch p2 !pc;
       com ()
   | OANDAND -> if tr then caseand tr else caseor tr
   | OOROR -> if tr then caseor tr else caseand tr
   | OEQ | ONE | OLE | OLT | OGE | OGT | OHI | OHS | OLO | OLS ->
       let o = if tr then Check.comrel.(rel_tab n.op) else n.op in
       let l = l () and r = r () in
       if l.complex >= fnx && r.complex >= fnx then begin
         let nod = regret r in
         cgenrel r (Some nod) true;
         let nod1 = regsalloc r in
         gopcode OAS (Some nod) None (Some nod1);
         regfree nod;
         let nod = dup n in
         nod.right <- Some nod1;
         boolgen nod tr nn
       end
       else begin
         if sconst l then begin
           let nod = regalloc r nn in
           cgenrel r (Some nod) true;
           let o = Check.invrel.(rel_tab o) in
           gopcodet o tr (Some l) (Some nod) None;
           regfree nod
         end
         else if sconst r then begin
           let nod = regalloc l nn in
           cgenrel l (Some nod) true;
           gopcodet o tr (Some r) (Some nod) None;
           regfree nod
         end
         else begin
           let nod, nod1 =
             if l.complex >= r.complex then begin
               let nod1 = regalloc l nn in
               cgenrel l (Some nod1) true;
               let nod = regalloc r None in
               cgenrel r (Some nod) true;
               nod, nod1
             end
             else begin
               let nod = regalloc r nn in
               cgenrel r (Some nod) true;
               let nod1 = regalloc l None in
               cgenrel l (Some nod1) true;
               nod, nod1
             end
           in
           gopcodet o tr (Some nod) (Some nod1) None;
           regfree nod;
           regfree nod1
         end;
         com ()
       end
   | _ ->
       let nod = regalloc n nn in
       cgen n (Some nod);
       let o = if tr then Check.comrel.(rel_tab ONE) else ONE in
       if typefd (et n) then gopcodet o tr (Some (nodfconst 0.)) (Some nod) None
       else gopcode o (Some (nodconst 0L)) (Some nod) None;
       regfree nod;
       com ());
  cursafe := curs

(* structures (and vlongs on arm), n into nn, w bytes *)
and sugen (n : node) (nn : node option) w =
  if n.ntype <> None then begin
    (match nn with Some x when x == Option.get !nodrat -> if w > !nrathole then nrathole := w | _ -> ());
    let copy () = match nn with None -> () | Some nn -> sucopy n nn w in
    match n.op with
    | OIND when nn = None -> nullwarn n.left None
    | OCONST when typev (et n) -> (
        match nn with
        | None -> nullwarn n.left None
        | Some nn ->
            let t0 = nn.ntype in
            nn.ntype <- Some (ty Tlong);
            let nod1 = reglcgen nn None in
            nn.ntype <- t0;
            gopcode OAS (Some (nodconst (sx32 n.vconst))) None (Some nod1);
            nod1.xoffset <- nod1.xoffset + 4;
            gopcode OAS (Some (nodconst (sx32 (Int64.shift_right n.vconst 32)))) None (Some nod1);
            regfree nod1)
    | ODOT ->
        let l = Tree.l n in
        let rat = Option.get !nodrat in
        sugen l (Some rat) (t l).width;
        (match nn with
         | Some _ ->
             let nod1 = dup rat in
             (match n.right with
              | Some ({ op = OCONST; _ } as r) ->
                  nod1.xoffset <- nod1.xoffset + Int64.to_int (sx32 r.vconst);
                  nod1.ntype <- n.ntype;
                  sugen nod1 nn w
              | _ -> ignore (diag (Some n) "DOT and no offset"))
         | None -> ())
    | OSTRUCT -> diag (Some n) "structure constructors are not in the subset"
    | OAS -> (
        match nn with
        | None -> if n.addable < indexed then sugen (Tree.r n) n.left w
        | Some _ ->
            let rat = Option.get !nodrat in
            sugen (Tree.r n) (Some rat) w;
            sugen rat n.left w;
            sugen rat nn w)
    | OFUNC -> (
        match nn with
        | None -> sugen n (Some (Option.get !nodrat)) w
        | Some nnn ->
            (* the result's address, as the first argument *)
            let a =
              if nnn.op <> OIND then (let a = node1 OADDR (Some nnn) None in a.ntype <- Some (ty Tind); a.addable <- 0; a)
              else Tree.l nnn
            in
            let f = node OFUNC n.left (Some (node OLIST (Some a) n.right)) in
            f.ntype <- Some (ty Tvoid);
            (Tree.l f).ntype <- Some (ty Tvoid);
            cgen f None)
    | OCOND ->
        bcgen (Tree.l n) true;
        let p1 = p () in
        sugen (Tree.l (Tree.r n)) nn w;
        ignore (gbranch OGOTO);
        patch p1 !pc;
        let p1 = p () in
        sugen (Tree.r (Tree.r n)) nn w;
        patch p1 !pc
    | OCOMMA -> cgen (Tree.l n) None; sugen (Tree.r n) nn w
    | _ -> copy ()
  end

and sucopy (n : node) (nn : node) w =
  if n.complex >= fnx && nn.complex >= fnx then begin
    (* the destination's address first, to a temporary *)
    let t0 = nn.ntype in
    nn.ntype <- Some (ty Tlong);
    let nod1 = regialloc nn None in
    lcgen nn (Some nod1);
    let nod2 = regsalloc nn in
    nn.ntype <- t0;
    gopcode OAS (Some nod1) None (Some nod2);
    regfree nod1;
    nod2.ntype <- Some (typ Tind t0);
    let nod1 = dup nod2 in
    nod1.op <- OIND; nod1.left <- Some nod2; nod1.right <- None; nod1.complex <- 1; nod1.ntype <- t0;
    sugen n (Some nod1) w
  end
  else (h ()).sucopy n nn w

(*****************************************************************************)
(* Multiplication by a constant (swt.c's mulcon) *)
(*****************************************************************************)

and mulcon (n : node) (nn : node) =
  if typefd (et n) then false
  else begin
    let l, r = if (Tree.l n).op = OCONST then Tree.r n, Tree.l n else Tree.l n, Tree.r n in
    if r.op <> OCONST then false
    else begin
      let v = convvtox r.vconst (et n) in
      if v <> r.vconst then false
      else
        match Multiply.mulcon0 (Int64.to_int v) with
        | None -> false
        | Some code ->
            let code = if String.length code > 1 && code.[1] = 'i' then String.sub code 2 (String.length code - 2) else code in
            let nod1 = regalloc n (Some nn) in
            cgen l (Some nod1);
            let nod2 = regalloc n None in
            let pick k = if k then nod2 else nod1 in
            let rec go i =
              if i >= String.length code then begin
                regfree nod2;
                if Int64.compare v 0L < 0 then (gopcode OAS (Some nod1) None (Some nod1); gopcode OSUB (Some nod1) (Some (nodconst 0L)) (Some nn))
                else gopcode OAS (Some nod1) None (Some nn);
                regfree nod1
              end
              else begin
                let d = Char.code code.[i + 1] - 48 in
                (match code.[i] with
                 | ('+' | '-') as c ->
                     (* r, n, l in the digit's bits *)
                     gopcode (if c = '+' then OADD else OSUB) (Some (pick (d land 1 <> 0))) (Some (pick (d land 2 <> 0))) (Some (pick (d land 4 <> 0)))
                 | c ->
                     let s = Char.code c - 97 in
                     if s < 0 || s >= 32 then ignore (diag (Some n) "mulcon unknown op: %c" c)
                     else gopcode OASHL (Some (nodconst (Int64.of_int s))) (Some (pick (d land 1 <> 0))) (Some (pick (d land 2 <> 0))));
                go (i + 2)
              end
            in
            go 0;
            true
    end
  end

(*****************************************************************************)
(* Arguments (txt.c's gargs) *)
(*****************************************************************************)

(* the calls first, to temporaries; then the arguments, the first in a
 * register if it fits one *)
and gargs (n : node option) =
  let regs0 = !cursafe in
  let temps = ref [] in
  let rec pass1 (n : node option) =
    match n with
    | None -> ()
    | Some ({ op = OLIST; _ } as n) -> pass1 n.left; pass1 n.right
    | Some n ->
        if n.complex >= fnx then begin
          let s = regsalloc n in
          let nod = node OAS (Some s) (Some n) in
          nod.ntype <- n.ntype;
          cgen nod None;
          temps := !temps @ [ s ]
        end
  in
  pass1 n;
  curarg := 0;
  let next () = match !temps with s :: rest -> temps := rest; s | [] -> assert false in
  let rec pass2 (n : node option) =
    match n with
    | None -> ()
    | Some ({ op = OLIST; _ } as n) -> pass2 n.left; pass2 n.right
    | Some n ->
        let src () = if n.complex >= fnx then next () else n in
        if typesuv (et n) then begin
          let tn2 = regaalloc n in
          sugen (src ()) (Some tn2) (t n).width
        end
        else if !curarg = 0 && typechlp (et n) then begin
          let tn1 = regaalloc1 n in
          cgen (src ()) (Some tn1)
        end
        else begin
          let tn1 = regalloc n None in
          cgen (src ()) (Some tn1);
          let tn2 = regaalloc n in
          gopcode OAS (Some tn1) None (Some tn2);
          regfree tn1
        end
  in
  pass2 n;
  cursafe := regs0

(*****************************************************************************)
(* Statements (pgen.c) *)
(*****************************************************************************)

type case = { cval : int64; cdef : bool; clabel : int; cisv : bool }

let cases : case list option ref = ref None
let breakpc = ref (-1)
let continpc = ref (-1)
let nbreak = ref 0
let ncontin = ref 0
let canreach = ref true

let noretval k =
  if k land 1 <> 0 then (let q = gins "NOP" None None in q.to_ <- Some (Ix_asm.Asm.Reg (bk ()).regret));
  if k land 2 <> 0 then (let q = gins "NOP" None None in q.to_ <- Some (Ix_asm.Asm.FReg (bk ()).fregret))

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
  if n.ntype = None then (ignore (gbranch OGOTO); false)
  else if c <> None && n.op = OCONST && deadheads (Option.get c) then true
  else (bool64 n; boolgen n true None; false)

let rec uncomma (n : node option) =
  match n with Some ({ op = OCOMMA; _ } as n) -> cgen (Tree.l n) None; uncomma n.right | n -> n

let casf () = cases := Some ({ cval = 0L; cdef = false; clabel = 0; cisv = false } :: Option.get !cases)
let set_case c = match !cases with Some (_ :: rest) -> cases := Some (c :: rest) | _ -> ()

(* the cases, sorted, to the machine's dispatch (pswt.c's doswit) *)
let doswit (n : node) =
  let cs = List.filter (fun c -> not c.cdef) (List.rev (List.tl (List.rev (Option.get !cases)))) in
  let def = List.fold_left (fun d c -> if c.cdef then c.clabel else d) 0 (Option.get !cases) in
  let isv = typev (et n) in
  let q = List.map (fun c -> (if isv then c.cval else Int64.of_int32 (Int64.to_int32 c.cval)), c.clabel) (List.filter (fun c -> not c.cisv || isv) cs) in
  let q = Array.of_list (List.stable_sort (fun (a, _) (b, _) -> compare a b) q) in
  for i = 0 to Array.length q - 2 do
    if fst q.(i) = fst q.(i + 1) then ignore (diag (Some n) "duplicate cases in switch %Ld" (fst q.(i)))
  done;
  let def = if def = 0 then (incr nbreak; !breakpc) else def in
  if isv && ewidth Tind <= ewidth Tlong then ignore (diag (Some n) "64-bit switches on 32-bit machines are not in the subset");
  (h ()).swit q def n

(* a label's last forward goto (5c's n->label) *)
let labels : (node * prog) list ref = ref []
let pending (l : node) = List.assq_opt l !labels

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
            match uncomma n.left with
            | None -> noretval 3; ignore (gbranch ORETURN)
            | Some l ->
                if (m ()).typecmplx (et n) then begin
                  let nod = node OAS !nodret (Some l) in
                  nod.ntype <- n.ntype; nod.complex <- l.complex;
                  cgen nod None;
                  noretval 3
                end
                else begin
                  let nod = regret n in
                  cgen l (Some nod);
                  regfree nod;
                  noretval (if typefd (et n) then 1 else 2)
                end;
                ignore (gbranch ORETURN)
          end
      | OLABEL ->
          canreach := true;
          (match n.left with
           | Some l -> l.pc <- !pc; (match pending l with Some q -> patch q !pc | None -> ())
           | None -> ());
          (* no self reference *)
          let q = gbranch OGOTO in
          patch q !pc;
          gen n.right
      | OGOTO -> (
          canreach := false;
          match n.left with
          | None -> ()
          | Some l ->
              if l.complex = 0 then ignore (diag None "label undefined: %s" (sym l).name)
              else if !suppress = 0 then begin
                let q = gbranch OGOTO in
                if l.pc <> 0 then patch q l.pc
                else begin
                  (* the previous goto branches to this one, as 5c's *)
                  (match pending l with Some prev -> patch prev (!pc - 1) | None -> ());
                  labels := (l, q) :: List.filter (fun (x, _) -> x != l) !labels
                end
              end)
      | OCASE ->
          canreach := true;
          if !cases = None then ignore (diag (Some n) "case/default outside a switch");
          (match n.left with
           | None -> casf (); set_case { cval = 0L; cdef = true; clabel = !pc; cisv = false }
           | Some l ->
               Check.complex (Some l);
               if l.ntype <> None then begin
                 if l.op <> OCONST || not ((m ()).typeswitch (et l)) then ignore (diag (Some n) "case expression must be integer constant")
                 else (casf (); set_case { cval = l.vconst; cdef = false; clabel = !pc; cisv = typev (et l) })
               end);
          gen n.right
      | OSWITCH ->
          let l = Tree.l n in
          Check.complex (Some l);
          if l.ntype <> None then begin
            if not ((m ()).typeswitch (et l)) then ignore (diag (Some n) "switch expression must be integer");
            let sp = gbranch OGOTO in
            let cn = !cases in
            cases := Some [];
            casf ();
            let sbc = !breakpc in
            breakpc := !pc;
            let snbreak = !nbreak in
            nbreak := 0;
            let spb = gbranch OGOTO in
            gen n.right;
            if !canreach then (let q = gbranch OGOTO in patch q !breakpc; incr nbreak);
            patch sp !pc;
            let nod = regalloc l None in
            (* always signed *)
            nod.ntype <- Some (ty (if typev (et l) then Tvlong else Tlong));
            cgen l (Some nod);
            doswit nod;
            regfree nod;
            patch spb !pc;
            cases := cn;
            breakpc := sbc;
            canreach := !nbreak <> 0;
            nbreak := snbreak
          end
      | OWHILE | ODWHILE ->
          let l = Tree.l n in
          let sp = gbranch OGOTO in
          let scc = !continpc in
          continpc := !pc;
          let spc = gbranch OGOTO in
          let sbc = !breakpc in
          breakpc := !pc;
          let snbreak = !nbreak in
          nbreak := 0;
          let spb = gbranch OGOTO in
          patch spc !pc;
          if n.op = OWHILE then patch sp !pc;
          ignore (bcomplex l None);
          patch (p ()) !breakpc;
          if l.op <> OCONST || Check.vconst (Some l) = 0 then incr nbreak;
          if n.op = ODWHILE then patch sp !pc;
          gen n.right;
          let q = gbranch OGOTO in
          patch q !continpc;
          patch spb !pc;
          continpc := scc;
          breakpc := sbc;
          canreach := !nbreak <> 0;
          nbreak := snbreak
      | OFOR ->
          let l = Tree.l n in
          gen (Tree.r l).left;
          let sp = gbranch OGOTO in
          let scc = !continpc in
          continpc := !pc;
          let spc = gbranch OGOTO in
          let sbc = !breakpc in
          breakpc := !pc;
          let snbreak = !nbreak in
          nbreak := 0;
          let sncontin = !ncontin in
          ncontin := 0;
          let spb = gbranch OGOTO in
          patch spc !pc;
          gen (Tree.r l).right;
          patch sp !pc;
          (match l.left with
           | Some test ->
               ignore (bcomplex test None);
               patch (p ()) !breakpc;
               if test.op <> OCONST || Check.vconst (Some test) = 0 then incr nbreak
           | None -> ());
          canreach := true;
          gen n.right;
          if !canreach then (let q = gbranch OGOTO in patch q !continpc; incr ncontin);
          patch spb !pc;
          continpc := scc;
          breakpc := sbc;
          canreach := !nbreak <> 0;
          nbreak := snbreak;
          ncontin := sncontin
      | OCONTINUE ->
          if !continpc < 0 then ignore (diag (Some n) "continue not in a loop")
          else (let q = gbranch OGOTO in patch q !continpc; incr ncontin; canreach := false)
      | OBREAK ->
          if !breakpc < 0 then ignore (diag (Some n) "break not in a loop")
          (* an unreachable break makes no branch *)
          else if !canreach then (let q = gbranch OGOTO in patch q !breakpc; incr nbreak; canreach := false)
      | OIF ->
          let l = Tree.l n and r = Tree.r n in
          if bcomplex l n.right then begin
            let f = if typefd (et l) then l.fconst = 0. else l.vconst = 0L in
            if f then (canreach := true; supgen r.left; canreach := true; gen r.right)
            else begin
              canreach := true;
              gen r.left;
              let oldreach = !canreach in
              canreach := true;
              supgen r.right;
              canreach := oldreach
            end
          end
          else begin
            let sp = ref (p ()) in
            canreach := true;
            if r.left <> None then gen r.left;
            let oldreach = !canreach in
            canreach := true;
            if r.right <> None then begin
              let q = gbranch OGOTO in
              patch !sp !pc;
              sp := q;
              gen r.right
            end;
            patch !sp !pc;
            canreach := !canreach || oldreach
          end
      | OSET | OUSED -> usedset n.left n.op
      | _ -> Check.complex (Some n); cgen n None

(* generated then thrown away: its strings and labels stay *)
and supgen (n : node option) =
  match n with
  | None -> ()
  | Some _ ->
      incr suppress;
      let spc = !pc and sp = !progs in
      gen n;
      progs := sp;
      pc := spc;
      decr suppress

and usedset (n : node option) o =
  match n with
  | Some ({ op = OLIST; _ } as n) -> usedset n.left o; usedset n.right o
  | Some n ->
      Check.complex (Some n);
      (match n.op with
       | OADDR -> ignore (gins "NOP" (Some n) None)
       | ONAME -> if o = OSET then ignore (gins "NOP" None (Some n)) else ignore (gins "NOP" (Some n) None)
       | _ -> ())
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
  let sp = gpseudo "TEXT" (sym n1) (nodconst (Int64.of_int !Declare.stkoff)) in
  sp.pseudo <- `Text (if !Pre.profile then 0 else 1);
  let thisfn = Option.get !Declare.thisfn in
  let ret = link thisfn in
  if (m ()).typecmplx ret.etype then begin
    let n1 = Tree.l (Option.get !nodret) in
    if n1.ntype = None || (link (t n1)) != ret then begin
      n1.ntype <- Some (typ Tind (Some ret));
      n1.netype <- Tind;
      let r = node OIND (Some n1) None in
      Check.complex (Some r);
      nodret := Some r
    end
  end;
  (* the first argument arrives in a register *)
  if (m ()).typecmplx ret.etype then begin
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
