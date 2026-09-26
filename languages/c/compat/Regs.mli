(* The compat back end's machine and resources (txt.c): what differs
 * between 5c's and 7c's instructions ([backend], which Arm and Arm64
 * fill), the registers as 5c allocates them (the listings depend on
 * it), the frame's safe area and outgoing arguments, and the nodes the
 * generator makes. Emit (languages/c/) writes the instructions. *)

(* what gopcode makes: an operator's instruction, 7c's negation and
 * complement, a call, a switch's table *)
type gop = Op of Tree.binop | Gneg | Gcom | Gcall | Gcase

(* the registers are numbered as 5c's: the integer ones, then the
 * floating ones from nreg *)
type backend = {
  nreg : int;
  nfreg : int;
  regret : int;                       (* the result, and the first argument *)
  fregret : int;
  regsp : int;
  reserved : int list;                (* never allocated: SB, SP, the linker's temporary... *)
  regtmp : int;                       (* regnode's: a register only for its type *)
  word : int;                         (* an argument's slot above the return address *)
  float_from_last : bool;             (* the float registers rotate as the integer ones (7c) *)
  ret : string;                       (* RET, RETURN *)
  zero_reg : int option;              (* a constant 0 as a register (7c's raddr) *)
  gmove : Tree.expr -> Tree.expr -> unit;
  gmover : Tree.expr -> Tree.expr -> unit;
  gopcode : gop -> bool -> Tree.expr option -> Tree.expr option -> Tree.expr option -> unit;
}

val be : backend option ref
val bk : unit -> backend

(* the register of a node, as a second source (txt.c's raddr) *)
val raddr : Tree.expr option -> Emit.prog -> unit

(* a load's or a store's operand, and a move to itself *)
val is_mem : Tree.expr -> bool
val samaddr : Tree.expr -> Tree.expr -> bool

(* a comparison, both machines': a negative constant compared by CMN,
 * unless small says its negation overflows *)
val gcmp : string -> fd:bool -> small:(int64 -> bool) -> Tree.expr option -> Tree.expr option -> unit

(* the branch of a relation; a float's not taken on a NaN when tr *)
val grel : Tree.binop -> fd:bool -> tr:bool -> unit

(* a return *)
val greturn : unit -> Emit.prog

(* the nodes the generator makes: registers; a register's number *)
val nodreg : Tree.expr -> int -> Tree.expr
val regnode : unit -> Tree.expr
val reg_of : Tree.expr -> int

(* .rathole (a struct thrown away), and *.ret (where a struct is
 * returned) *)
val nodrat : Tree.expr option ref
val nodret : Tree.expr option ref

(* the registers' uses; the temporaries' and the arguments' sizes *)
val regs : int array ref
val cursafe : int ref
val curarg : int ref
val maxargsafe : int ref

(* the result's register, taken; the first free one *)
val regret : Tree.expr -> Tree.expr
val tmpreg : unit -> int

(* a register for a value of tn's type: o's if o is one of that kind,
 * else the next free, round robin as 5c's; for a pointer *)
val regalloc : Tree.expr -> Tree.expr option -> Tree.expr
val regialloc : Tree.expr -> Tree.expr option -> Tree.expr
val regfree : Tree.expr -> unit

(* a temporary on the stack; the first argument's register, the next
 * arguments' slots *)
val regsalloc : Tree.expr -> Tree.expr
val regaalloc1 : Tree.expr -> Tree.expr
val regaalloc : Tree.expr -> Tree.expr

(* the register n as an indirection, at off, of nn's type *)
val regind : Tree.expr -> Tree.expr -> int -> Tree.expr

(* .rathole's size *)
val nrathole : int ref

(* a file's start, after Emit.init; its end, before Emit.gclean *)
val init : unit -> unit
val gclean : unit -> unit
