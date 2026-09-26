(* The stack machine on the registers, for arm64 and arm (simple/): the
 * slot at depth i is Ri or Fi as its value is an integer or a float
 * (R1-R15 and F1-F15 on arm64, R1-R7 and F1-F6 on arm), so an
 * expression deeper than that is refused. Every register is the
 * caller's to save, as in 5c's and 7c's convention: a call spills the
 * slots below its arguments, below the frame's locals, and reloads
 * them. Values are kept as their type makes them, extended to the
 * register's width, so that a comparison or a division of any width is
 * the register's; an operation's result is extended again.
 *
 * What differs between the machines is the [mach] record and the
 * mnemonics (the functions at the top): arm64's 64-bit registers,
 * SCVTF; arm's MOVW, DIV (5l makes it a call), MOVWD, and no unsigned
 * conversion to a float but through a signed one. *)

(* a function's code, after Lower's *)
val codgen : Tree.sym -> Tree.stmt -> unit
