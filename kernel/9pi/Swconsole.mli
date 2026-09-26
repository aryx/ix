(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The screen and its console (principia's arm screen.c and
 * swconsole.c): the framebuffer (640 x 480 x 16, as 9pi takes the
 * firmware's size, no vgasize), a black frame, a white window, its
 * orange title bar " Plan 9 Console ", and in it the kernel's output
 * (screenputs): each rune in the default font on white, newline, tab,
 * backspace, the window scrolled 8 lines at a time. *)

(* the screen made and the console drawn there from now on
 * (Machine.screen: all the console's output); nothing when there is no
 * framebuffer *)
val init : unit -> unit

(* the screen's rectangle, once there is one *)
val rect : unit -> (int * int * int * int) option
