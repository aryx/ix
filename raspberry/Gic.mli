(* The Pi4's interrupt controller, ARM's GIC-400 (GICv2), for one core
 * (plan_pi.md, phase G3): its distributor at 0xff841000 (enables,
 * pendings, priorities, targets, configurations: SGIs 0-15, PPIs
 * 16-31 such as the generic timer's 27 and 30, SPIs 32 and up such as
 * the PL011's 153) and its CPU interface at 0xff842000 (the priority
 * mask, IAR to acknowledge the highest pending interrupt, EOIR to end
 * it). Interrupts are level-sensitive as the devices drive them: a
 * line held high stays pending; an acknowledged one is active until
 * its EOI, and a higher-priority one may preempt it.
 *
 * Not modelled: groups and the secure view (all interrupts group 0),
 * the binary point (priorities compared whole), SGIs sent through
 * GICD_SGIR, the other cores' banked registers.
 *
 * References: ARM Generic Interrupt Controller Architecture
 * Specification v2 (IHI 0048; from memory); QEMU's hw/intc/arm_gic.c
 * (read 2026-09-25) for the reset values: 192 SPIs on the BCM2711. *)

type t

val create : unit -> t

(* a device's line, by interrupt ID *)
val set : t -> int -> bool -> unit

(* whether the core's IRQ is asserted *)
val irq : t -> bool

val distributor : t -> Memory.device
val cpu_interface : t -> Memory.device
