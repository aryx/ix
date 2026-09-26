(* Decision 8's route B, a fallback (plan_ml.md): mini-ml's arm code
 * as GNU's assembly, for as and ld, so that mini-ml's code runs in a
 * kernel gcc builds, before mini-ld can link one (route A). It reads the
 * object mini-asm's parser makes of Gen's text, and does the little of
 * mini-ld's work GNU's assembler doesn't: a static address a literal
 * (ldr r, =sym), a division a call of libgcc's, names made local or
 * spelled for as; the prologues and epilogues are the compiler's own,
 * and literal pools and branches' reach as's. Nothing else in mini-ml
 * knows this module: mini-ml -gas, and removing it is deleting the file
 * and the flag. *)

val obj : Ix_asm.Asm.obj -> string
