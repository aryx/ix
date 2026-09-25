@ Claude Code
@
@ Copyright (C) 2026 Yoann Padioleau
@
@ This library is free software; you can redistribute it and/or
@ modify it under the terms of the GNU Library General Public License
@ (LGPL) as published by the Free Software Foundation; either version
@ 2 of the License, or (at your option) any later version.
@
@ mini-xv6, step 4: the user program's image, linked at 0 (user.ld),
@ in the kernel's read-only data; the kernel copies it into a process's
@ pages (xv6 would read an ELF from its file system: steps to come).
	.section .rodata
	.global user_image
	.global user_image_end
	.align	2
user_image:
	.incbin	"build/user.bin"
user_image_end:
