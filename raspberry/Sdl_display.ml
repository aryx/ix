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
 * scancodes, which are USB HID usages (SDL took them from there); the
 * mouse, relative as a USB mouse is: a click grabs the host's pointer
 * (SDL's relative mode: its motion the guest's, the host cursor gone),
 * Ctrl-Alt-G lets it go, as QEMU's window does. The
 * one module of mini-qemu linking a C library (plan_pi.md, decision 9). *)

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
  let grabbed = ref false in
  let grab on =
    grabbed := on;
    ok (Sdl.set_relative_mouse_mode on);
    Option.iter (fun (win, _) ->
      Sdl.set_window_title win (if on then title ^ " (Ctrl-Alt-G releases the mouse)" else title)) !window in
  let button b = if b = Sdl.Button.left then 1 else if b = Sdl.Button.right then 2 else if b = Sdl.Button.middle then 4 else 0 in
  let poll () =
    let evs = ref [] in
    let add ev = evs := ev :: !evs in
    while Sdl.poll_event (Some e) do
      match Sdl.Event.(enum (get e typ)) with
      | `Quit -> add Display.Quit
      | `Key_down when !grabbed && Sdl.Event.(get e keyboard_keycode) = Sdl.K.g
                       && Sdl.get_mod_state () land Sdl.Kmod.ctrl <> 0 && Sdl.get_mod_state () land Sdl.Kmod.alt <> 0 ->
          grab false
      | (`Key_down | `Key_up) as k when Sdl.Event.(get e keyboard_repeat) = 0 ->
          add (Display.Key (Sdl.Event.(get e keyboard_scancode), k = `Key_down))
      | `Mouse_button_down when not !grabbed -> grab true           (* the grabbing click is the host's *)
      | (`Mouse_button_down | `Mouse_button_up) as k ->
          let b = button Sdl.Event.(get e mouse_button_button) in
          if b <> 0 then add (Display.Button (b, k = `Mouse_button_down))
      | `Mouse_motion when !grabbed -> add (Display.Motion (Sdl.Event.(get e mouse_motion_xrel), Sdl.Event.(get e mouse_motion_yrel)))
      | `Mouse_wheel when !grabbed -> add (Display.Wheel (- Sdl.Event.(get e mouse_wheel_y)))
      | _ -> ()
    done;
    List.rev !evs in
  { Display.present; poll }
