(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Machines.mli *)

open Tree

(* vlongs are structures to 5c: returned through a pointer, and their
 * operators calls to _addv... (com64.c) *)
let arm = {
  thechar = '5'; sz_ind = 4; maxalign = 4;
  typecmplx = typesuv; typeword = typechlp; typeswitch = typechl;
  machcap = (fun _ -> false);
}

(* what 7c generates itself, rather than com64.c's calls (7c's machcap.c) *)
let machcap (n : expr option) =
  match n with
  | None -> true
  | Some n -> (
      match n.e with
      | Binary ((Mul | Lmul), _, _) | Assign (Some (Mul | Lmul), _, _) -> typechlv (et n)
      | Binary ((Add | And | Or | Sub | Xor | Ashl | Lshr | Ashr), l, _) | Unary (Neg, l) -> typechlv (et l)
      | Unary ((Cast | Not | Postinc | Postdec | Preinc | Predec), _) | Cond _ | Binary ((Comma | Andand | Oror), _, _)
      | Assign (Some (Add | Sub | And | Or | Xor | Ashl | Ashr | Lshr), _, _) -> true
      | Binary (o, _, _) -> is_rel o
      | _ -> false)

let arm64 = {
  thechar = '7'; sz_ind = 8; maxalign = 8;
  typecmplx = typesu; typeword = typechlvp; typeswitch = typechlv;
  machcap;
}
