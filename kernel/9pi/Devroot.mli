(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#/', the root (principia's devroot.c): the directories the
 * namespace is built on (bin, dev, env, ... empty: mount points), and
 * /boot, the bootdir: the programs 9pi links into its image (boot, the
 * rc script, rcmain, rc, echo, bind, fdisk, dossrv, mount, ls), here the
 * kernel's embedded image (mkbootdir.py's format), read in place. *)

(* the bootdir's files read from the embedded image; the device
 * registered *)
val init : unit -> unit
