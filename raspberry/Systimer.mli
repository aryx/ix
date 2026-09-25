(* The BCM2835's system timer (base + 0x3000): a free-running 64-bit
 * counter of microseconds (CLO, CHI) and four compares (C0-C3); when
 * the counter's low word reaches a compare, its bit in CS is set and
 * its interrupt line (0-3) raised, until the kernel writes the bit to
 * CS. Time advances when the board says (instructions counted,
 * plan_pi.md decision 6), so a compare the counter jumps over still
 * matches.
 *
 * Reference: BCM2835 ARM Peripherals, chapter 12 (from memory). *)

type t

val create : line:(int -> bool -> unit) -> t

(* the counter moved on by microseconds *)
val advance : t -> int -> unit

(* the microseconds until the next compare (for an idle CPU) *)
val until_next : t -> int

val device : t -> Memory.device

(* the counter, microseconds *)
val now : t -> int
