(* The arm64 machine, as 7c: its types (pointers are vlongs, which the
 * machine computes itself), its moves and conversions, its
 * instructions, and what Gen asks of it. *)

(* for the front end *)
val machine : Tree.machine

(* for Emit *)
val backend : Emit.backend

(* for Gen *)
val hooks : Gen.hooks
