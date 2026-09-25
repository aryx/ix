(* mini-xv6's console on the framebuffer (xv6 arm-pi1's gpuputc and
 * initframebuf, pixel for pixel): 1024 x 768, 16 bits a pixel, asked of
 * the VideoCore on the mailbox's channel 1 (both boards: machine.c); a
 * character an 8 x 16 cell of xv6's font (font1.bin), 15 rows drawn,
 * white on black; the cell cleared first (a space: only that); a
 * newline (or the right edge) the next row, the screen scrolled up a
 * row at the bottom and its last row's cells cleared. Everything the
 * console prints, the kernel's messages and the programs' output, is
 * drawn: the screen shows the serial console's last 48 lines, as
 * arm-pi1's C kernel's does. *)

(* the framebuffer asked for, the console drawn there from now on
 * (Machine.screen); nothing when there is none *)
val init : unit -> unit

(* the mouse moved (dx, dy; its buttons): the cursor, an arrow drawn by
 * inverting the pixels under it, moved there within the screen (shown
 * from the first move on; hidden while the console draws) *)
val pointer : int -> int -> int -> unit
