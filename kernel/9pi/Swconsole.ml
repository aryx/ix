(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Swconsole.mli *)

let wid = 640 and ht = 480 and depth = 16
let scroll_lines = 8
let tabstop = 4

let screen_r = ref None
let rect () = !screen_r

(* the console's window and its cursor *)
let win = ref (0, 0, 0, 0)
let cur = ref (0, 0)
let h = ref 0

let inset (x0, y0, x1, y1) n = (x0 + n, y0 + n, x1 - n, y1 - n)

let fill r img = Draw.draw (Draw.screen ()) r img (0, 0, 0, 0) (Draw.opaque ())

(* the default font's s at (x, y), in black *)
let text (x, y) s =
  ignore (Draw.string (Draw.screen ()) (x, y) (Draw.black ()) s)

(* the positions a backspace goes back to (xbuf) *)
let xbuf = ref []

let scroll () =
  let (x0, y0, x1, y1) = !win in
  let o = scroll_lines * !h in
  Draw.draw (Draw.screen ()) (x0, y0, x1, y1 - o) (Draw.screen ()) (x0, y0 + o, x0, y0 + o) (Draw.opaque ());
  fill (x0, y1 - o, x1, y1) (Draw.white ());
  let (cx, cy) = !cur in
  cur := (cx, cy - o)

let rec putc s =
  let (x0, _, x1, y1) = !win in
  let (cx, cy) = !cur in
  match s with
  | "\n" ->
      if cy + !h >= y1 then scroll ();
      let (cx, cy) = !cur in
      cur := (cx, cy + !h);
      putc "\r"
  | "\r" -> xbuf := []; cur := (x0, cy)
  | "\t" ->
      let w = Draw.stringwidth " " in
      if cx >= x1 - (tabstop * w) then putc "\n";
      let (cx, cy) = !cur in
      let pos = tabstop - (((cx - x0) / w) mod tabstop) in
      xbuf := cx :: !xbuf;
      fill (cx, cy, cx + (pos * w), cy + !h) (Draw.white ());
      cur := (cx + (pos * w), cy)
  | "\b" ->
      (match !xbuf with
       | [] -> ()
       | x :: rest ->
           xbuf := rest;
           fill (x, cy, cx, cy + !h) (Draw.white ());
           cur := (x, cy))
  | "\000" -> ()
  | _ ->
      let w = Draw.stringwidth s in
      if cx >= x1 - w then putc "\n";
      let (cx, cy) = !cur in
      xbuf := cx :: !xbuf;
      fill (cx, cy, cx + w, cy + !h) (Draw.white ());
      text (cx, cy) s;
      cur := (cx + w, cy)

(* the bytes of a rune gathered (screenputs' chartorune) *)
let pending = Buffer.create 4

let need c = if c < 0x80 then 1 else if c land 0xe0 = 0xc0 then 2 else if c land 0xf0 = 0xe0 then 3 else 1

let putbyte ch =
  Buffer.add_char pending ch;
  let s = Buffer.contents pending in
  if String.length s >= need (Char.code s.[0]) then begin
    Buffer.clear pending;
    (* the screen's lock: the clock's cursor stays still meanwhile *)
    Swcursor.drawlock := true;
    (try putc s with e -> Swcursor.drawlock := false; raise e);
    Swcursor.drawlock := false
  end

(* screenwin: the title bar, the window below it *)
let screenwin () =
  let orange = Draw.color16 0x40 0xfd in
  let (x0, y0, x1, _) = !win in
  Draw.draw (Draw.screen ()) (x0, y0, x1, y0 + !h + 5 + 6) orange (0, 0, 0, 0) (Draw.opaque ());
  Draw.free orange;
  win := inset !win 5;
  let (x0, y0, x1, y1) = !win in
  text (x0 + 10, y0) " Plan 9 Console ";
  let y0 = y0 + !h + 6 in
  cur := (x0, y0);
  win := (x0, y0, x1, y0 + (((y1 - y0) / !h) * !h))

let init () =
  let pa = Machine.fb_init wid ht depth in
  if pa <> 0 && Draw.init pa wid ht then begin
    screen_r := Some (0, 0, wid, ht);
    h := Draw.fontheight ();
    (* fbinit's "blue screen": its memory all 0x7F (the margin outside
     * the frame keeps it) *)
    let blue = Draw.color16 0x7f 0x7f in
    fill (0, 0, wid, ht) blue;
    Draw.free blue;
    (* swconsole_init: the frame, the window *)
    let r = inset (0, 0, wid, ht) 4 in
    fill r (Draw.black ());
    win := inset r 4;
    fill !win (Draw.white ());
    screenwin ();
    Machine.screen := putbyte
  end
