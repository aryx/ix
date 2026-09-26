(* The machine-independent passes over an expression (com.c, sub.c,
 * scon.c, acom.c), each a function from a tree to a tree: the typing
 * [tcom], which inserts the conversions and checks the operands against
 * Tree's tables; the rewrites of comma expressions, the simplifications
 * and constant folding (ccom, evconst), the arithmetic rewrites (acom);
 * then the generator's [xcom]. [complex] is all of them.
 *
 * Plan 9's C, not ANSI's: unsigned char and short promote to unsigned
 * int, and double op float is computed as float (cck's table); the
 * listing depends on both. acom sorts its terms as 5c's qsort does on
 * glibc (a merge sort), so equal terms keep 5c's order.
 *
 * The passes have effects: the typing writes the strings' data, in the
 * order the expressions come, as 5c.
 *
 * References: Ken Thompson, "Plan 9 C Compilers", sections "Typing"
 * ("Implicit operations on the tree are added, such as type promotions
 * and taking the address of arrays and functions"), "Machine-independent
 * optimization" and "Arithmetic rewrites" (factoring: 4+8*a+16*b+5 is
 * transformed into 9+8*(a+2*b), as arises "from address manipulation
 * and array indexing"). *)

(* what the front end asks of the back end, set by Gen *)
val outstring : (string -> int -> int) ref
val xcom : (Tree.expr -> Tree.expr) ref

(* the value of a small integral constant, or -159 *)
val vconst : Tree.expr -> int

(* log2 of a power-of-two constant, or -1 *)
val vlog : Tree.expr -> int

(* a conversion that makes no code *)
val nocast : Tree.typ -> Tree.typ -> bool

(* an error unless the operator's table takes the operands' types *)
val tcompat : Tree.expr -> Tree.typ -> Tree.typ -> (Tree.etype -> Tree.etype -> bool) -> unit

(* a relation with its operands swapped, and negated *)
val invrel : Tree.binop -> Tree.binop
val comrel : Tree.binop -> Tree.binop

(* the typing of n, its conversions made nodes; ~addr (the default): an
 * array or a function used is its address *)
val tcom : ?addr:bool -> Tree.expr -> Tree.expr

(* all the passes, then Gen's xcom; ~ret: a function's result,
 * converted to its type *)
val complex : ?ret:Tree.typ -> Tree.expr -> Tree.expr
