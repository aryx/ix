(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#c', the console (principia's devcons.c): /dev/cons, what the
 * programs read and write, on the serial console (the screen's is
 * stage D). Its input cooked as Plan 9's: echoed, a line at a time,
 * backspace and ^U editing it, ^D ending it without a newline (an empty
 * one: the end of file). Output as 9pi's UART gives it: a CR before
 * each LF. Also /dev/null. *)

(* a character typed (the UART's interrupt) *)
val intr : int -> unit

(* the console's output (the kernel's messages too) *)
val print : string -> unit

(* the device registered *)
val init : unit -> unit
