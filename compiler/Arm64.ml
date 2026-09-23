(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Arm64.mli *)

open Tree

(* the no-op casts: pointers are vlongs (7c's txt.c) *)
let ncast = table [
  Tchar, b Tchar lor b Tuchar; Tuchar, b Tchar lor b Tuchar;
  Tshort, b Tshort lor b Tushort; Tushort, b Tshort lor b Tushort;
  Tint, b Tint lor b Tuint lor b Tlong lor b Tulong; Tuint, b Tint lor b Tuint lor b Tlong lor b Tulong;
  Tlong, b Tint lor b Tuint lor b Tlong lor b Tulong; Tulong, b Tint lor b Tuint lor b Tlong lor b Tulong;
  Tvlong, b Tvlong lor b Tuvlong lor b Tind; Tuvlong, b Tvlong lor b Tuvlong lor b Tind;
  Tfloat, b Tfloat; Tdouble, b Tdouble; Tind, b Tvlong lor b Tuvlong lor b Tind;
  Tstruct, b Tstruct; Tunion, b Tunion ]

(* what 7c generates itself, rather than com64.c's calls (7c's machcap.c) *)
let machcap (n : node option) =
  match n with
  | None -> true
  | Some n -> (
      match n.op with
      | OMUL | OLMUL | OASMUL | OASLMUL -> typechlv (et n)
      | OADD | OAND | OOR | OSUB | OXOR | OASHL | OLSHR | OASHR | ONEG -> typechlv (et (l n))
      | OCAST | OCOND | OCOMMA | OLIST | OANDAND | OOROR | ONOT | OASADD | OASSUB | OASAND | OASOR | OASXOR
      | OASASHL | OASASHR | OASLSHR | OPOSTINC | OPOSTDEC | OPREINC | OPREDEC
      | OEQ | ONE | OLE | OGT | OLT | OGE | OHI | OHS | OLO | OLS -> true
      | _ -> false)

let machine = {
  thechar = '7'; sz_ind = 8; maxalign = 8;
  typecmplx = typesu; typeword = typechlvp; typeswitch = typechlv;
  ncast;
  machcap;
}
