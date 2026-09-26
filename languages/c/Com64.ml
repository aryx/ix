(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Com64.mli *)

open Tree

(* the complexity of a call: more than any expression's (compat's
 * Sethi-Ullman; simple's ignores it) *)
let fnx = 100

let fvns : (string * etype, expr) Hashtbl.t = Hashtbl.create 64

(* libc's function name, as a node of a function returning et *)
let fvn name et =
  match Hashtbl.find_opt fvns (name, et) with
  | Some n -> n
  | None ->
      let n = { (name_of (lookup name) (typ Tfunc (Some (ty et))) Cglobl 0) with addable = Aname } in
      Hashtbl.replace fvns (name, et) n;
      n

let vbinops = [ Add, "_addv"; Sub, "_subv"; Mul, "_mulv"; Lmul, "_mulv"; Div, "_divv"; Ldiv, "_divvu"; Mod, "_modv";
                Lmod, "_modvu"; Ashl, "_lshv"; Ashr, "_rshav"; Lshr, "_rshlv"; And, "_andv"; Or, "_orv"; Xor, "_xorv" ]

(* a type's letters in the conversions' names: _sc2v, _v2sc *)
let vcodes = [ Tchar, "sc"; Tuchar, "uc"; Tshort, "sh"; Tushort, "uh"; Tint, "si"; Tuint, "ui"; Tlong, "sl"; Tulong, "ul";
               Tfloat, "f"; Tdouble, "d"; Tind, "p" ]

(* _vasop's code for the type of the left side *)
let etconv t = match List.assoc_opt t [ Tchar, 1; Tuchar, 2; Tshort, 3; Tushort, 4; Tlong, 5; Tulong, 6; Tvlong, 7; Tuvlong, 8; Tint, 9; Tuint, 10 ] with Some c -> c | None -> 0

let testv () = fvn "_testv" Tlong

let addr_of (x : expr) = { (mk ~t:(typ Tind (Some x.t)) (Unary (Addr, x))) with complex = x.complex }

(* n as a call to libc, where vlongs are the machine's (arm's, whose
 * machcap does nothing itself); None: not a vlong's, as it is *)
let com64 (n : expr) : expr option =
  let call a args = Some { n with e = Call (a, args); complex = fnx } in
  let test (x : expr) = { (mk ~t:(ty Tlong) (Call (testv (), [ x ]))) with complex = fnx } in
  let isv (x : expr) = typev (et x) in
  (* the left operand is a vlong; the right, where ?:'s are of its type *)
  let lv = match n.e with Binary (_, a, _) | Assign (_, a, _) | Cond (a, _, _) | Unary (_, a) | Call (a, _) | Dot (a, _) -> isv a | _ -> false in
  let rv = match n.e with Binary (_, _, b) | Assign (_, _, b) -> isv b | Cond _ -> isv n | _ -> false in
  let logical = match n.e with Binary ((Andand | Oror), _, _) -> true | _ -> false in
  let test_right (n : expr) = match n.e with Binary (o, a, b) when rv && logical -> { n with e = Binary (o, a, test b) } | _ -> n in
  match n.e with
  | Binary (o, a, b) when lv && is_rel o ->
      Some { n with e = Call (fvn ("_" ^ String.lowercase_ascii (binop_name o) ^ "v") Tlong, [ a; b ]); complex = fnx; t = ty Tlong }
  | (Binary ((Andand | Oror), _, _) | Cond _ | Unary (Not, _)) when lv ->
      let n = test_right n in
      let e = match n.e with Binary (o, a, b) -> Binary (o, test a, b) | Cond (c, a, b) -> Cond (test c, a, b) | Unary (o, a) -> Unary (o, test a) | e -> e in
      Some { n with e; complex = fnx }
  | (Binary ((Andand | Oror), _, _) | Cond _) when rv -> Some (test_right n)
  | _ when typev (et n) -> (
      match n.e with
      | Call _ -> Some { n with complex = fnx }
      | Assign (None, _, _) | Unary (Ind, _) | Binary (Comma, _, _) -> Some n
      | Unary ((Postinc | Postdec | Preinc | Predec) as o, x) ->
          call (fvn (List.assoc o [ Postinc, "_vpp"; Postdec, "_vmm"; Preinc, "_ppv"; Predec, "_mmv" ]) Tvlong) [ addr_of x ]
      | Unary (Neg, x) -> call (fvn "_negv" Tvlong) [ x ]
      | Unary (Com, x) -> call (fvn "_comv" Tvlong) [ x ]
      | Unary (Cast, x) -> (
          match List.assoc_opt (et x) vcodes with
          | Some code when List.mem (et x) [ Tchar; Tuchar; Tshort; Tushort ] ->
              (* a small one as a long first *)
              call (fvn ("_" ^ code ^ "2v") Tvlong) [ { (mk ~t:(ty Tlong) (Unary (Cast, x))) with complex = x.complex } ]
          | Some code -> call (fvn ("_" ^ code ^ "2v") Tvlong) [ x ]
          | None -> diag (Some n) "unknown %s->vlong cast" (show_type (Some x.t)))
      | Binary (o, a, b) when List.mem_assoc o vbinops -> call (fvn (List.assoc o vbinops) Tvlong) [ a; b ]
      | Assign (Some o, x, y) ->
          (* x op= y: _vasop(&x, fn, type, y) *)
          let a = fvn (List.assoc o vbinops) Tvlong in
          call (fvn "_vasop" Tvlong) [ addr_of x; { (addr_of a) with complex = 0 }; Emit.nodconst (Int64.of_int (etconv (et x))); y ]
      | _ -> diag (Some n) "unknown vlong")
  | Unary (Cast, x) when lv -> (
      (* _v2uh is _v2ul, as com64.c has it; a pointer is an unsigned long *)
      match et n with
      | Tushort | Tind -> call (fvn "_v2ul" (if et n = Tind then Tulong else Tushort)) [ x ]
      | t -> (match List.assoc_opt t vcodes with Some code -> call (fvn ("_v2" ^ code) t) [ x ] | None -> diag (Some n) "unknown vlong->%s cast" (show_type (Some n.t))))
  | _ -> None

(* a vlong tested as a condition *)
let bool64 (n : expr) =
  if not ((m ()).machcap None) && typev (et n) then { n with e = Call (testv (), [ n ]); complex = fnx; addable = Anone; t = ty Tlong } else n
