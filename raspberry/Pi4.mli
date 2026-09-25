(* The Raspberry Pi 4 as QEMU's raspi4b models it, for xv6 arm64-pi4
 * (plan_pi.md, phase G): one Cortex-A72 core in AArch64 (machine/'s
 * Arm64 with its exception levels, Mmu64), the RAM from 0, and the
 * BCM2711's devices the kernel uses: the PL011 at 0xfe201000 (the
 * console, SPI 153), GPIO, the GIC-400 at 0xff841000, and the core's
 * generic timer (CNTV and CNTP at 62.5 MHz, QEMU's cortex-a72, on
 * PPIs 27 and 30). Unassigned I/O reads zero, written to nowhere (a
 * note with -d).
 *
 * Time: the counter advances 62.5 ticks per [ips] instructions (a
 * simulated microsecond, plan_pi.md decision 6); a WFI with nothing
 * pending skips to the next timer's deadline (at most 10ms).
 *
 * One core: QEMU's raspi4b has four, all started at the ELF's entry
 * (xv6's entry.S parks the others), so a console compared with QEMU's
 * lacks the other cores' lines ("hart 1 starting").
 *
 * The decode cache is by virtual address and privilege, emptied by any
 * TLBI, IC, and writes to the translation registers. *)

type config = {
  ram_size : int;
  ips : int;
  log : string -> unit;
  serial : char -> unit;               (* the PL011 *)
  trace : int;                         (* the first N instructions to the log, or every -N-th; 0 none *)
}

type t

val create : config -> t

(* an ELF kernel, as QEMU's -kernel loads one that is not Linux: its
 * segments at their physical addresses, the core at the entry (by the
 * segment that holds it, physical) at EL3, interrupts masked *)
val load_elf : t -> string -> unit

(* a character from the host, for the PL011 *)
val input : t -> char -> unit

(* [batch] instructions, then the timers *)
val run : t -> batch:int -> unit

(* the instructions run *)
val instructions : t -> int
