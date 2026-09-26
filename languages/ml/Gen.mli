(* The stack machine into Plan 9's assembly, for arm (5) or arm64 (7):
 * TinyC's and tiny-ml's back end, a record per machine (mini-cc's
 * decision 1). The text is what -S prints and what mini-asm's parser
 * reads into the object, so that mini-ml -S f.ml | mini-asm makes
 * mini-ml f.ml's object.
 *
 * The stack machine's stack is in registers (R1..R8 on arm, R1..R15 on
 * arm64): a push a move, an operation an instruction. At a call or an
 * allocation every register goes to its slot on the value stack, where
 * the collector sees it, and comes back after. The value stack's top
 * is a register 5c and 7c never allocate (R10, R26), stored in
 * ml_vsp before C is called. Every function is TEXT $-4 or $-8, a frame
 * mini-ld leaves alone: the prologue and epilogue are the compiler's,
 * so that a tail call is the epilogue then a B.
 *
 * try is setjmp's: BL ml_try(SB) records the stack pointers, the return
 * address and the previous handler in the frame, and returns 0; raise
 * restores them from the latest record and returns there again, with
 * the exception in R0. (A BL over the handler to a label, tiny-ml's
 * way, is not a call mini-ld links.) *)

type mach

val arm : mach
val arm64 : mach
val arch : mach -> Ix_asm.Asm.arch

(* a unit's assembly *)
val unit_ : mach -> Lower.unit_ -> string

(* the program's start, from the units in their order: ml_start (C
 * calls it with the value stack's base), ml_try, ml_raise, the table
 * of the units' globals, each unit's Init in a handler that prints an
 * uncaught exception *)
val startup : mach -> string list -> string
