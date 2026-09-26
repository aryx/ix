(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#Ι', the keyboard's scan codes from outside the kernel (principia's
 * devkbin.c): usb/kb writes the USB keyboard's keys, as a PC keyboard's
 * scan codes, to #Ι/kbin (one writer at a time); Kbd turns them into
 * the console's input. *)

(* the device registered *)
val init : unit -> unit
