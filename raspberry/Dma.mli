(* The BCM2835's DMA controller (base + 0x7000): 15 channels, each a
 * chain of 32-byte control blocks (TI, source, destination, length,
 * stride, next) by bus address; writing ACTIVE runs the chain at once,
 * incrementing the addresses TI says, a peripheral's register (9pi's
 * EMMC data port) read or written in place; then END, and INT when TI
 * asks, raising the channel's interrupt (16 + channel). 2D mode and
 * the DREQ pacing are not modelled: the transfers are immediate, as
 * QEMU's (hw/dma/bcm2835_dma.c).
 *
 * Reference: BCM2835 ARM Peripherals, chapter 4 (from memory); 9pi's
 * dma.c. *)

type t

val create : mem:Memory.t -> line:(int -> bool -> unit) -> t

val device : t -> Memory.device
