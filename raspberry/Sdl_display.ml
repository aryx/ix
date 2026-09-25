(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The display in an SDL window (tsdl): the framebuffer as a streaming
 * texture in its own format (RGB565 for 16 bits: no conversion), sized
 * at its first frame, drawn when it changed; the keys by SDL's
 * scancodes, which are USB HID usages (SDL took them from there). The
 * one module of tinypi linking a C library (plan_pi.md, decision 9). *)

open Tsdl
open Ix_raspberry

let ok = function Ok v -> v | Error (`Msg m) -> failwith ("SDL: " ^ m)

(* the texture's format for the framebuffer's depth *)
let format = function
  | 16 -> Sdl.Pixel.format_rgb565
  | 24 -> Sdl.Pixel.format_rgb24
  | _ -> Sdl.Pixel.format_argb8888

let create ~title =
  ok (Sdl.init Sdl.Init.video);
  let window = ref None and texture = ref None and shape = ref None and last = ref "" in
  let pixels = ref (Bigarray.Array1.create Bigarray.int8_unsigned Bigarray.c_layout 0) in
  let present (g : Framebuffer.geometry) data =
    if !shape <> Some g then begin
      (match !window with
       | None ->
           let win = ok (Sdl.create_window title ~w:g.width ~h:g.height Sdl.Window.windowed) in
           window := Some (win, ok (Sdl.create_renderer win))
       | Some (win, _) -> Sdl.set_window_size win ~w:g.width ~h:g.height);
      let _, r = Option.get !window in
      texture := Some (ok (Sdl.create_texture r (format g.depth) Sdl.Texture.access_streaming ~w:g.width ~h:g.height));
      pixels := Bigarray.Array1.create Bigarray.int8_unsigned Bigarray.c_layout (String.length data);
      shape := Some g; last := ""
    end;
    (* a frame like the last one: nothing to draw *)
    if data <> !last then begin
      last := data;
      let px = !pixels in
      String.iteri (fun i c -> Bigarray.Array1.unsafe_set px i (Char.code c)) data;
      let _, r = Option.get !window and tex = Option.get !texture in
      ok (Sdl.update_texture tex None px g.pitch);
      ok (Sdl.render_clear r);
      ok (Sdl.render_copy r tex);
      Sdl.render_present r
    end in
  let e = Sdl.Event.create () in
  let poll () =
    let evs = ref [] in
    while Sdl.poll_event (Some e) do
      match Sdl.Event.(enum (get e typ)) with
      | `Quit -> evs := Display.Quit :: !evs
      | (`Key_down | `Key_up) as k when Sdl.Event.(get e keyboard_repeat) = 0 ->
          evs := Display.Key (Sdl.Event.(get e keyboard_scancode), k = `Key_down) :: !evs
      | _ -> ()
    done;
    List.rev !evs in
  { Display.present; poll }
