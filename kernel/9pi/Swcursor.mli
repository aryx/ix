(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The software cursor (9pi's swcursor.c, and screen.c's cursoron,
 * cursoroff and ksetcursor): a 16x16 picture drawn on the screen, what
 * it covers kept aside (in back) and put back when it is hidden. Any
 * drawing on the screen first calls [avoid] with its rectangle
 * (memdraw's hwdraw hook, draw9.c's, calls it back); the clock redraws the cursor at the
 * mouse's position ([clock], each tick).
 *
 * The pictures are GREY8 images built from the cursor's bits, then drawn
 * into GREY1 ones, as 9pi does. *)

(* swcursor_init: its images (after the screen's) *)
val init : unit -> unit

(* [load (ox, oy) clr set]: a cursor's offset and its 2x16 bytes each *)
val load : int * int -> string -> string -> unit

(* hidden when its rectangle meets r (x0, y0, x1, y1) *)
val avoid : int * int * int * int -> unit

(* arch_cursoron, arch_cursoroff, arch_ksetcursor *)
val cursoron : unit -> bool
val cursoroff : unit -> unit
val ksetcursor : int * int -> string -> string -> unit

(* swcursor_clock: to the mouse's position (x, y), drawn anew there *)
val clock : int * int -> unit

(* drawlock: taken by the console's drawing, the clock then leaves the
 * cursor as it is *)
val drawlock : bool ref
