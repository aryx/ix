(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Screen.mli *)

module Phys = Machine.Phys

(* String.iteri, which OCaml 1.07 does not have *)
let string_iteri f s = for i = 0 to String.length s - 1 do f i s.[i] done

let width = 1024
let height = 768
let depth = 16
let cell_w = 8
let cell_h = 16
let rows_drawn = 15                     (* a glyph's rows: the 16th stays black *)

(* the framebuffer's address, a row's bytes; the cursor; the font *)
let fb = ref 0
let pitch = ref (width * 2)
let x = ref 0
let y = ref 0
let font = ref ""

(* a cell's row of pixels, 16 bits each little-endian: white where
 * [bits] (bit 0 the leftmost), black elsewhere *)
let row bits =
  let s = String.create (cell_w * 2) in
  for b = 0 to cell_w - 1 do
    let c = if (bits lsr b) land 1 = 1 then '\255' else '\000' in
    String.set s (2 * b) c;
    String.set s ((2 * b) + 1) c
  done;
  s

(* the cell at the cursor: [c]'s glyph over black (drawcursor, then
 * drawcharacter: a space, and a character past 127, only black) *)
let cell c =
  let glyph k = if c = ' ' || Char.code c > 127 then 0 else Char.code !font.[(Char.code c * 16) + k] in
  for k = 0 to rows_drawn - 1 do
    Phys.write (!fb + ((!y + k) * !pitch) + (!x * 2)) (row (glyph k))
  done

(* the next row; at the bottom, the screen moved up a row, the last row's
 * cells black *)
let newline () =
  x := 0;
  y := !y + cell_h;
  if !y >= height then begin
    Phys.copy !fb (!fb + (!pitch * cell_h)) (!pitch * (height - cell_h));
    y := height - cell_h;
    while !x < width do cell ' '; x := !x + cell_w done;
    x := 0
  end

(*****************************************************************************)
(* The mouse's cursor *)
(*****************************************************************************)

(* an arrow, 12 x 12, its tip at the pointer; drawn by inverting the
 * pixels under it (twice: the screen as it was) *)
let arrow = [| "X"; "XX"; "XXX"; "XXXX"; "XXXXX"; "XXXXXX"; "XXXXXXX"; "XXXXXXXX";
               "XXXXX"; "XX XX"; "X   XX"; "    XX" |]

let cx = ref (width / 2)
let cy = ref (height / 2)
let shown = ref false

let invert () =
  Array.iteri (fun r line ->
    string_iteri (fun c ch ->
      let px = !cx + c and py = !cy + r in
      if ch = 'X' && px < width && py < height then begin
        let a = !fb + (py * !pitch) + (px * 2) in
        Phys.set16 a (Phys.get16 a lxor 0xffff)
      end) line) arrow

let toggle () = if !fb <> 0 then begin invert (); shown := not !shown end

(* the mouse moved (Usbhost): the cursor there, within the screen; shown
 * from the first move on *)
let pointer dx dy (_ : int) =
  if !shown then toggle ();
  cx := max 0 (min (width - 1) (!cx + dx));
  cy := max 0 (min (height - 1) (!cy + dy));
  toggle ()

(* the console's drawing, the cursor off meanwhile (a scroll would move it) *)
let putc c =
  let on = !shown in
  if on then toggle ();
  if c = '\n' then newline ()
  else begin
    cell c;
    x := !x + cell_w;
    if !x >= width then newline ()
  end;
  if on then toggle ()

let init () =
  let a = Machine.fb_init width height depth in
  if a <> 0 then begin
    fb := a;
    (let p = Machine.fb_pitch () in if p > 0 then pitch := p);
    font := Phys.read (Machine.font_base ()) (128 * 16);
    Machine.screen := putc
  end
