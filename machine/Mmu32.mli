(* ARM's 32-bit MMU, the short descriptors (plan_pi.md, decision 5): a
 * first-level table of 4096 entries (a fault, a 1MB section, a 16MB
 * supersection, or a coarse second-level table: the legacy fine tables
 * and their 1KB tiny pages, obsolete in ARMv6, are left out) and
 * second levels of large (64KB), small (4KB) and extended small pages; both ARMv6 formats, the legacy one with a permission per
 * quarter page (SCTLR.XP clear: the Pi1's xv6) and the ARMv6/v7 one
 * (XP set: APX, XN); TTBCR's split between TTBR0 and TTBR1; the
 * domains (DACR: no access, client, manager); faults with the FSR's
 * codes. A TLB of 1024 pages in front of the walk, flushed by the
 * CP15 operations that change a translation.
 *
 * References: ARM Architecture Reference Manual (ARM DDI 0100I, ARMv6;
 * ARM DDI 0406, ARMv7-A; from memory), chapter B4 / "Virtual memory
 * system architecture"; ARM1176JZF-S TRM (from memory). *)

type t = {
  mutable sctlr : int;
  mutable ttbr0 : int;
  mutable ttbr1 : int;
  mutable ttbcr : int;
  mutable dacr : int;
  mem : Memory.t;
  tags : int array;
  pages : int array;
  rights : int array;
}

val create : Memory.t -> t

(* the TLB emptied: a TLB invalidation, or a table's register written *)
val flush : t -> unit

val enabled : t -> bool

(* a virtual address to a physical one for an access (bit 0 a write,
 * bit 1 as user; [user]: the CPU in usr mode), or Arm32.Abort (the
 * address, the FSR: the domain in bits 7-4, bit 11 a write) *)
val translate : t -> user:bool -> int -> int -> int
