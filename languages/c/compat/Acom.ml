(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Acom.mli *)

open Tree

let mkt = Check.mkt and konst = Check.konst and cast_to = Check.cast_to and ival = Check.ival
let nilcast = Check.nilcast and nocast = Check.nocast

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
