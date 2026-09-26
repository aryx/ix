(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#i', the draw device (principia's devdraw.c, drawmesg.c and their
 * drawalloc.c, drawname.c, drawwindow.c, drawmisc.c): the screen shared
 * by its clients, each a directory of /dev/draw (new: a new client's
 * ctl), its images by number. A client writes messages to its data
 * file (drawmesg: 'b' an image, 'd' a drawing, 's' a string, 'y' pixels
 * loaded, 'A' a screen, 'b' on it a window, 't' windows to the front,
 * ...: draw.h's protocol), reads its ctl (an image's size and chan: the
 * screen's first), and names images for others to use ('N', 'n': the
 * screen is "noborder.screen.1"). The pixels are principia's libraries'
 * (Draw's primitives); the numbers, names, fonts' characters, screens
 * and refreshes are here.
 *
 * Not as 9pi: no flushes (9pi's are nothing on the Pi: its screen is
 * not a soft one), no blanking after 30 minutes (its colour map is
 * nothing on an RGB16 screen, 9pi skips it under emulation), and the
 * colormap file's 256 colours are 0 (9pi's arch_getcolor leaves them
 * unset). *)

(* the device registered *)
val init : unit -> unit
