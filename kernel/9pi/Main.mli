(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* mini-9pi's boot, its traps and interrupts (principia's main.c,
 * trap.c). The first process does initcode's work in the kernel (as
 * mini-xv6's init does xv6's initcode): #c/cons opened as 0, 1, 2, then
 * the boot program exec'd; stage A's is /boot/echo (plan_9pi.md). *)
