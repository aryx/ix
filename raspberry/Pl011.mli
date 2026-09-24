(* The PL011 UART (the Pi's UART0, base + 0x201000): characters written
 * to DR go out at once (the transmit FIFO never fills: FR's TXFE set,
 * TXFF clear); characters received queue for DR, with the receive
 * interrupt (RXIM) and its timeout (RTIM) raised until the queue is
 * read empty; the transmit interrupt (TXIM) after each character, as
 * QEMU's model. The line is up while RIS and IMSC share a bit. Baud
 * rates and formats are kept, not used.
 *
 * Reference: ARM PrimeCell UART (PL011) Technical Reference Manual
 * (ARM DDI 0183; from memory); QEMU's hw/char/pl011.c (from memory). *)

type t

val create : output:(char -> unit) -> line:(bool -> unit) -> t

(* a character from the host (the console's input) *)
val input : t -> char -> unit

(* nothing received waiting *)
val empty : t -> bool

val device : t -> Memory.device
