(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Arm.mli *)

open Tree

(* the no-op casts: pointers are longs (5c's txt.c) *)
let ncast = table [
  Tchar, b Tchar lor b Tuchar; Tuchar, b Tchar lor b Tuchar;
  Tshort, b Tshort lor b Tushort; Tushort, b Tshort lor b Tushort;
  Tint, b Tint lor b Tuint lor b Tlong lor b Tulong lor b Tind;
  Tuint, b Tint lor b Tuint lor b Tlong lor b Tulong lor b Tind;
  Tlong, b Tint lor b Tuint lor b Tlong lor b Tulong lor b Tind;
  Tulong, b Tint lor b Tuint lor b Tlong lor b Tulong lor b Tind;
  Tvlong, b Tvlong lor b Tuvlong; Tuvlong, b Tvlong lor b Tuvlong;
  Tfloat, b Tfloat; Tdouble, b Tdouble; Tind, b Tlong lor b Tulong lor b Tind;
  Tstruct, b Tstruct; Tunion, b Tunion ]

(* vlongs are structures to 5c: returned through a pointer, and their
 * operators calls to _addv... (com64.c) *)
let machine = {
  thechar = '5'; sz_ind = 4; maxalign = 4;
  typecmplx = typesuv; typeword = typechlp; typeswitch = typechl;
  ncast;
  machcap = (fun _ -> false);
}
