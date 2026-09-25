(* AArch64's MMU for the EL1&0 regime, as the Pi4's kernels use it
 * (plan_pi.md, phase G2): the 4 KB granule, TTBR0 for the addresses
 * whose top bits are all zeros and TTBR1 for those all ones (TCR's
 * T0SZ and T1SZ give the sizes), tables of 512 descriptors from the
 * level the size starts at down to level 3, blocks (1 GB at level 1,
 * 2 MB at level 2) and pages, AP[2:1], UXN and PXN, the access flag.
 *
 *   xv6 arm64-pi4: T1SZ = 25, a 39-bit kernel half at
 *   0xffffff80_00000000: levels 1, 2 (2 MB blocks); its processes
 *   under TTBR0, down to 4 KB pages at level 3.
 *
 * Not modelled: the 16 KB and 64 KB granules, the table descriptors'
 * APTable/XNTable, the hardware access flag, ASIDs (the TLB is emptied
 * by any TLBI and by writes to TTBR0/1, TCR, SCTLR), stage 2.
 *
 * References: ARM Architecture Reference Manual, ARMv8-A (ARM DDI
 * 0487; from memory), chapter D5 (the VMSAv8-64 translation); QEMU's
 * target/arm/ptw.c (read 2026-09-25) for the permissions: an address
 * EL0 may write is never executable at EL1, and one EL0 may not read
 * is not executable at EL0. *)

type t = {
  mutable sctlr : int64;
  mutable tcr : int64;
  mutable ttbr0 : int64;
  mutable ttbr1 : int64;
  mem : Memory.t;
  tags : int array;
  pages : int array;
  rights : int array;
}

val create : Memory.t -> t

val flush : t -> unit

val enabled : t -> bool

(* the physical address of [va] for an access (bit 0 a write, bit 1 as
 * user, bit 2 an instruction fetch), or Arm64.Abort with the virtual
 * address and the fault status code (translation, access flag or
 * permission, and the level; bit 6 when a write) *)
val translate : t -> int64 -> int -> int
