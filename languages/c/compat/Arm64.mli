(* The arm64 machine, as 7c: its moves and conversions, its
 * instructions, and what Gen asks of it. Its types (pointers are
 * vlongs, which the machine computes itself) are the front end's,
 * Machines.arm64. *)

(* for Emit *)
val backend : Emit.backend

(* for Gen *)
val hooks : Gen.hooks
