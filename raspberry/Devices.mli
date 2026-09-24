(* The BCM2835's smaller devices, each a Memory.device (offsets from its
 * base): what the Pi kernels touch, as QEMU's raspi1ap models it
 * (plan_pi.md, decision 4).
 *
 * References: BCM2835 ARM Peripherals (from memory); the Raspberry Pi
 * firmware's mailbox property interface (its wiki; from memory);
 * QEMU's hw/misc/bcm2835_mbox.c, bcm2835_property.c, hw/usb/hcd-dwc2.c
 * (read by a survey, 2026-09-25). *)

(* registers that read back what is written, some reading fixed values *)
val regs : ?fixed:(int * int) list -> unit -> Memory.device

(* AUX (base + 0x215000): the mini UART with no backend, as QEMU's *)
val aux : unit -> Memory.device

(* the rest of the I/O space: reads 0; each address logged once *)
val unassigned : log:(string -> int -> unit) -> Memory.device

(* the mailbox (base + 0xB880): a write to MAIL1 (0x20) is answered
 * at once on MAIL0 (0x00, EMPTY in 0x18) -- channel 8's property tags
 * (the ARM's and VideoCore's memory, revisions, clocks, power),
 * channel 1's framebuffer (at vc_base + 1MB, as QEMU's) -- channel 0
 * never, as QEMU. Buffers by bus address (the top two bits dropped). *)
val mailbox : mem:Memory.t -> ram_size:int -> vc_base:int -> Memory.device

(* the DWC2 USB controller (base + 0x980000), QEMU's: its id 2.94a
 * (the kernels' "emulating" test), resets that finish at once, halted
 * channels, no device on the root port *)
val dwc2 : unit -> Memory.device
