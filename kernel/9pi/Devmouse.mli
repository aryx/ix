(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#m', the mouse (principia's devmouse.c): /dev/mouse, its state as
 * rio reads it ("m x y buttons msec", a read waiting for a change; a
 * button's change queued), mousein (usb/kb writes a USB mouse's moves:
 * "m dx dy buttons [msec]"), mousectl (buttonmap, swap, scrollswap,
 * accelerated, linear), cursor (the cursor's image: 9pi's arrow at
 * first, drawn by Swcursor). The position is kept within the screen
 * (without one, moves are dropped, as 9pi's without a gscreen). *)

(* the screen's rectangle (min x, min y, max x, max y), once there is one *)
val screen : (int * int * int * int) option ref

(* mousexy: the mouse's position *)
val xy : unit -> int * int

(* the device registered; the arrow cursor loaded and drawn *)
val init : unit -> unit
