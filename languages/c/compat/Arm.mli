(* The arm machine, as 5c: its moves and conversions, its
 * instructions, and what Gen asks of it. Its types (pointers are longs,
 * vlongs are structures and their operators calls to libc) are the
 * front end's, Machines.arm. *)

(* for Regs *)
val backend : Regs.backend

(* for Gen *)
val hooks : Gen.hooks
