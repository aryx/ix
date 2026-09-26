(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Swcursor.mli *)

let enabled = ref false
let visible = ref false
(* swpt, where it should be; swvispt, where it is *)
let pt = ref (0, 0)
let vispt = ref (0, 0)
(* swvers, incremented by each load; swvisvers, the one on the screen *)
let vers = ref 0
let visvers = ref 0
let offset = ref (0, 0)
(* swrect: the screen's rectangle it covers *)
let r = ref (0, 0, 0, 0)
let drawlock = ref false

type images = { back : Draw.image; img : Draw.image; mask : Draw.image; img1 : Draw.image; mask1 : Draw.image }
let images = ref None

let draw () =
  match !images with
  | Some i when not !visible && !enabled ->
      vispt := !pt;
      visvers := !vers;
      let (x, y) = !pt in
      r := (x, y, x + 16, y + 16);
      (* what is under it kept, then it drawn *)
      Draw.draw i.back (0, 0, 32, 32) (Draw.screen ()) (x, y, 0, 0) (Draw.opaque ());
      Draw.draw (Draw.screen ()) !r i.img1 (0, 0, 0, 0) i.mask1;
      visible := true
  | _ -> ()

let hide () =
  match !images with
  | Some i when !visible ->
      visible := false;
      Draw.draw (Draw.screen ()) !r i.back (0, 0, 0, 0) (Draw.opaque ())
  | _ -> ()

let avoid (x0, y0, x1, y1) =
  let (a0, b0, a1, b1) = !r in
  if !visible && x0 < a1 && a0 < x1 && y0 < b1 && b0 < y1 then hide ()

let init () =
  enabled := true;
  (* hwdraw's (draw9.c): any drawing on the screen avoids it *)
  Callback.register "swcursor_avoid" avoid;
  let i = { back = Draw.alloc (0, 0, 32, 32) 0;
            mask = Draw.alloc (0, 0, 16, 16) Draw.grey8; mask1 = Draw.alloc (0, 0, 16, 16) Draw.grey1;
            img = Draw.alloc (0, 0, 16, 16) Draw.grey8; img1 = Draw.alloc (0, 0, 16, 16) Draw.grey1 } in
  List.iter (fun m -> Draw.draw m (0, 0, 16, 16) (Draw.opaque ()) (0, 0, 0, 0) (Draw.opaque ())) [ i.mask; i.mask1 ];
  List.iter (fun m -> Draw.draw m (0, 0, 16, 16) (Draw.black ()) (0, 0, 0, 0) (Draw.opaque ())) [ i.img; i.img1 ];
  images := Some i

let load off clr set =
  match !images with
  | None -> ()
  | Some i ->
      (* a byte a pixel: the image black where set, the mask opaque
       * where clr or set *)
      let img = String.create 256 and mask = String.create 256 in
      for k = 0 to 31 do
        let s = Char.code set.[k] and c = Char.code clr.[k] in
        for j = 0 to 7 do
          let bit = 0x80 lsr j in
          String.set img (k * 8 + j) (if s land bit <> 0 then '\000' else '\255');
          String.set mask (k * 8 + j) (if (c lor s) land bit <> 0 then '\255' else '\000')
        done
      done;
      ignore (Draw.load i.img img);
      ignore (Draw.load i.mask mask);
      offset := off;
      incr vers;
      Draw.draw i.img1 (0, 0, 16, 16) i.img (0, 0, 0, 0) (Draw.opaque ());
      Draw.draw i.mask1 (0, 0, 16, 16) i.mask (0, 0, 0, 0) (Draw.opaque ())

let move (x, y) = let (ox, oy) = !offset in pt := (x + ox, y + oy)

let cursoron () =
  if !drawlock then true else begin hide (); draw (); false end

let cursoroff () = hide ()

let ksetcursor off clr set = cursoroff (); load off clr set; ignore (cursoron ())

let clock xy =
  if !enabled then begin
    move xy;
    if not (!visible && !pt = !vispt && !vers = !visvers) && not !drawlock then begin
      hide ();
      draw ()
    end
  end
