(* The BCM2835's interrupt controller (base + 0xB200, the registers from
 * 0x200 on): the GPU's 64 interrupt lines, level-triggered, enabled
 * and disabled by bits; the pending registers show the enabled lines
 * that are up (as QEMU's model does), the basic one a summary and a
 * few lines again (bits 10-20). The ARM's own interrupts (its timer,
 * doorbells) are not modelled: no Pi kernel of the list uses them.
 *
 * Reference: BCM2835 ARM Peripherals (Broadcom, 2012; from memory),
 * chapter 7; QEMU's hw/intc/bcm2835_ic.c (from memory). *)

type t

val create : unit -> t

(* a device's line, up or down: 3 the system timer's compare 3, 57 the
 * PL011 *)
val set : t -> int -> bool -> unit

(* the CPU's IRQ input *)
val irq : t -> bool

(* its FIQ input: the source the FIQ control register names (0x20C: bit
 * 7 enable, bits 6-0 the line), up *)
val fiq : t -> bool

(* its registers, from base + 0xB200 *)
val device : t -> Memory.device
