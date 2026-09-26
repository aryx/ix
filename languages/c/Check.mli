(* The machine-independent passes over an expression (com.c, sub.c,
 * scon.c, acom.c), each a function from a tree to a tree: the typing
 * [tcom], which inserts the conversions and checks the operands against
 * Tree's tables; the rewrites of comma expressions, the simplifications
 * and constant folding (ccom, evconst); then the back end's [xcom].
 * [complex] is all of them. 5c's arithmetic rewrites (acom) are the
 * compat back end's (compat/Acom.ml), run by its xcom.
 *
 * Plan 9's C, not ANSI's: unsigned char and short promote to unsigned
 * int, and double op float is computed as float (cck's table); the
 * listing depends on both.
 *
 * The passes have effects: the typing writes the strings' data, in the
 * order the expressions come, as 5c.
 *
 * References: Ken Thompson, "Plan 9 C Compilers", sections "Typing"
 * ("Implicit operations on the tree are added, such as type promotions
 * and taking the address of arrays and functions") and
 * "Machine-independent optimization". *)

(* what the front end asks of the back end, set by the command (CLI) *)
val outstring : (string -> int -> int) ref
val xcom : (Tree.expr -> Tree.expr) ref

(* the value of a small integral constant, or -159 *)
val vconst : Tree.expr -> int

(* log2 of a power-of-two constant, or -1 *)
val vlog : Tree.expr -> int

(* a conversion that makes no code *)
val nocast : Tree.typ -> Tree.typ -> bool

(* a conversion that means nothing: small to large, of one kind *)
val nilcast : Tree.typ -> Tree.typ -> bool

(* a node of type t at the line diagnosed; a constant; a cast; a
 * constant's value, or 0 (for compat's Acom) *)
val mkt : Tree.typ -> Tree.kind -> Tree.expr
val konst : int64 -> Tree.typ -> Tree.expr
val cast_to : Tree.expr -> Tree.typ -> Tree.expr
val ival : Tree.expr -> int64

(* an error unless the operator's table takes the operands' types *)
val tcompat : Tree.expr -> Tree.typ -> Tree.typ -> (Tree.etype -> Tree.etype -> bool) -> unit

(* a relation with its operands swapped, and negated *)
val invrel : Tree.binop -> Tree.binop
val comrel : Tree.binop -> Tree.binop

(* the typing of n, its conversions made nodes; ~addr (the default): an
 * array or a function used is its address *)
val tcom : ?addr:bool -> Tree.expr -> Tree.expr

(* all the passes, then the back end's xcom; ~ret: a function's result,
 * converted to its type *)
val complex : ?ret:Tree.typ -> Tree.expr -> Tree.expr
