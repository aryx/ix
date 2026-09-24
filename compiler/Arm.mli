(* The arm machine, as 5c: its types (pointers are longs, vlongs are
 * structures and their operators calls to libc), its moves and
 * conversions, its instructions, and what Gen asks of it. *)

(* for the front end *)
val machine : Tree.machine

(* for Emit *)
val backend : Emit.backend

(* for Gen *)
val hooks : Gen.hooks
