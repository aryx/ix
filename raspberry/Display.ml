(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The screen and the input devices, a record of functions at the edge
 * (plan_pi.md, decision 9): the board's framebuffer shown, the keys
 * pressed and the mouse moved in the window read back. SDL's (Sdl_display, the executable's
 * one module linking a C library), or none (-nographic, the tests: a
 * QMP screendump writes the framebuffer as PPM). *)

type event =
  | Key of int * bool              (* a HID usage, down *)
  | Motion of int * int            (* the mouse moved, relative *)
  | Button of int * bool           (* a mouse button (1 left, 2 right, 4 middle), down *)
  | Wheel of int                   (* -1 up *)
  | Quit

type t = {
  present : Framebuffer.geometry -> string -> unit;   (* the pixels as the kernel wrote them *)
  poll : unit -> event list;
}

let none = { present = (fun _ _ -> ()); poll = (fun () -> []) }
