(* The machine-independent passes over a function's trees (com.c,
 * sub.c, scon.c, acom.c): the typing [tcom], which inserts the
 * conversions and checks the operands against Tree's tables; then
 * [complex] runs the rewrites of comma expressions, the simplifications
 * and constant folding (ccom, evconst), the arithmetic rewrites (acom),
 * and hands the tree to the generator's [xcom].
 *
 * Plan 9's C, not ANSI's: unsigned char and short promote to unsigned
 * int, and double op float is computed as float (cck's table); the
 * listing depends on both. acom sorts its terms as 5c's qsort does on
 * glibc (a merge sort), so equal terms keep 5c's order.
 *
 * References: Ken Thompson, "Plan 9 C Compilers", sections "Typing"
 * ("Implicit operations on the tree are added, such as type promotions
 * and taking the address of arrays and functions"), "Machine-independent
 * optimization" and "Arithmetic rewrites" (factoring: 4+8*a+16*b+5 is
 * transformed into 9+8*(a+2*b), as arises "from address manipulation
 * and array indexing"). *)

(* what the front end asks of the back end, set by Gen *)
val outstring : (string -> int -> int) ref

val xcom : (Tree.node -> unit) ref

(* the value of a small integral constant, or -159 *)
val vconst : Tree.node option -> int

(* log2 of a power-of-two constant, or -1 *)
val vlog : Tree.node -> int

val nocast : Tree.typ option -> Tree.typ option -> bool

val tcompat :
  Tree.node ->
  Tree.typ option ->
  Tree.typ option -> (Tree.etype -> int) -> bool

val relindex : Tree.op -> int

val relindex_opt : Tree.op -> int option

val invrel : Tree.op array

val comrel : Tree.op array

val invert : Tree.node option -> Tree.node option

(* the typing of n, its conversions inserted; true if in error *)
val tcom : Tree.node -> bool

type term = { mutable mult : int64; mutable tnode : Tree.node option; }

(* the passes after the typing, then Gen's xcom *)
val complex : Tree.node option -> unit
