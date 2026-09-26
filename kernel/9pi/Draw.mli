(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The C pixel libraries (principia's libmemdraw, libmemlayer, libdraw's
 * geometry: plan_9pi.md, decision 4), as mini-9pi's OCaml sees them
 * (drawglue.c, draw9.c): images, the screen on the framebuffer, drawing
 * (memimagedraw, always SoverD), strings in the default font. *)

(* a memdraw image (a C pointer, to a Memimage) *)
type image

(* [init pa w h]: the screen, RGB16, on the framebuffer at physical
 * address pa; false when it cannot be made *)
external init : int -> int -> int -> bool = "draw_init"

external screen : unit -> image = "draw_screen"
external white : unit -> image = "draw_white"
external black : unit -> image = "draw_black"
external opaque : unit -> image = "draw_opaque"

(* a 1x1 replicated RGB16 colour, its two bytes; one freed *)
external color16 : int -> int -> image = "draw_color16"
external free : image -> unit = "draw_free"

(* [draw dst (x0, y0, x1, y1) src (sx, sy, mx, my) mask] *)
external draw : image -> int * int * int * int -> image -> int * int * int * int -> image -> unit = "draw_draw"

(* [string dst (x, y) src s]: the default font's s, its end's x *)
external string : image -> int * int -> image -> string -> int = "draw_string"

external fontheight : unit -> int = "draw_fontheight"
external stringwidth : string -> int = "draw_stringwidth"

(* [alloc (x0, y0, x1, y1) chan]: a new image, transparent; chan 0 the
 * screen's *)
external alloc : int * int * int * int -> int -> image = "draw_alloc"
(* [load img bytes]: its pixels, row after row; the bytes used *)
external load : image -> string -> int = "draw_load"

(* the chans (draw.h's GREY1, GREY8) *)
val grey1 : int
val grey8 : int
