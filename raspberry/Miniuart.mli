(* The mini UART of the BCM2835's AUX block (base + 0x215000), as QEMU
 * models it (hw/char/bcm2835_aux.c): characters out at once (LSR says
 * empty and idle, 0x60), received ones in an 8-deep FIFO; the
 * interrupt (line 29) while IER's receive bit and a character, or its
 * transmit bit, are set. 9pi's console (QEMU's second -serial). *)

type t

val create : output:(char -> unit) -> line:(bool -> unit) -> t

(* room for a character from the host *)
val room : t -> bool
val input : t -> char -> unit

val device : t -> Memory.device
