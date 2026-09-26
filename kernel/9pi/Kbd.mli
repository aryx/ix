(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The keyboard's scan codes (principia's portkbd.c): a PC keyboard's
 * codes (usb/kb turns the USB keyboard's into these, writing #Ι/kbin)
 * turned into runes for the console (Devcons.kbdputc): the 0xe0 and 0xe1
 * escapes, a key's release (bit 7), shift, ctrl, alt, altgr, caps lock,
 * the tables kbtab, kbtabshift, kbtabesc1, kbtabaltgr, kbtabctrl.
 * Alt starts a compose sequence (latin1: not here yet, its characters
 * given as they are). *)

(* a scan code, from outside the kernel (kbin: the external state) *)
val kbdputsc : int -> unit

(* the mouse buttons the keyboard sets (Kmouse keys: none in the
 * default tables), told to the mouse (Devmouse) *)
val kbdmouse : (int -> unit) ref
