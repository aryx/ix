(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Draw.mli *)

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
let grey1 = 0x31
let grey8 = 0x38

(* The draw device's (Devdraw): its messages' ints in an int array, as
 * draw9.c's d9_* take them; a 32-bit chan or colour as two 16-bit
 * halves *)

(* a null image (an allocation failed) *)
external isnil : image -> bool = "draw_isnil"
(* makescreenimage's: another image on the screen's memory *)
external screenimage : unit -> image = "draw_screenimage"
(* 'b': [| r[4] chan[2] repl clipr[4] value[2] |] *)
external allocimage : int array -> image = "draw_allocimage"
external setrepl : image -> unit = "draw_setrepl"
(* [| clipr[4] |] *)
external setclipr : image -> int array -> unit = "draw_setclipr"
(* its chan's name, [| chan[2] repl r[4] clipr[4] depth layer |] *)
external info : image -> string * int array = "draw_info"
(* [drawop dst src mask [| r[4] p[2] q[2] op |]] *)
external drawop : image -> image -> image -> int array -> unit = "draw_drawop"
(* [| p0[2] p1[2] end0 end1 radius sp[2] op |] *)
external line : image -> image -> int array -> unit = "draw_line"
(* [| end0 end1 radius sp[2] op fill n pts[2n] |]: -1 no memory *)
external poly : image -> image -> int array -> int = "draw_poly"
(* [| c[2] a b thick sp[2] op arc alpha phi |] *)
external ellipse : image -> image -> int array -> unit = "draw_ellipse"
(* [memload dst [| r[4] compressed |] data]: the bytes used, -1 bad *)
external memload : image -> int array -> string -> int = "draw_memload"
(* [unload img [| r[4] |]]: its pixels *)
external unload : image -> int array -> string = "draw_unload"

(* Layers: a screen (Memscreen: its image, its fill), windows on it *)
type memscreen
external memscreen : image -> image -> memscreen = "draw_memscreen"
external freememscreen : memscreen -> unit = "draw_freememscreen"
(* its image's chan, its halves *)
external memscreenchan : memscreen -> int * int = "draw_memscreenchan"
(* 'b' on a screen: [| r[4] refresh clipr[4] value[2] |], a null image
 * when it fails *)
external lalloc : memscreen -> int array -> image = "draw_lalloc"
(* its refresh's pointer: a Refx's number (Devdraw's), 0 none *)
external lsetrefresh : image -> int -> unit = "draw_lsetrefresh"
(* [| refx screenr[4] onscreen |] *)
external layerinfo : image -> int array = "draw_layerinfo"
(* [lfree l delete]: memldelete (its screen still good) or memlfree *)
external lfree : image -> bool -> unit = "draw_lfree"
(* [ltofront windows front]: 0, -1 not windows, -2 not on one screen *)
external ltofront : image array -> bool -> int = "draw_ltofront"
(* [| log[2] scr[2] |]: -1 failed, 0 no move, 1 moved *)
external lorigin : image -> int array -> int = "draw_lorigin"
