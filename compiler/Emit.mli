(* The generated code and the machine's resources (txt.c, swt.c,
 * list.c, obj.c): the instructions ([prog]), their operands made from
 * trees ([naddr], to the assembler's Asm.operand), the registers, the
 * frame's safe area and outgoing arguments, the data of initializers
 * and strings; at the end the listing (-S) and the object.
 *
 * The object is TinyAsm's Asm.obj, not goken's format: the compiler
 * produces what the assembler would, and TinyLd encodes both. The
 * listing is byte for byte 5c's and 7c's at -O0, including Plan 9's
 * %.17e for floats ([listing]); tests/listing.sh compares them.
 *
 * What differs between the machines' instructions is the [backend]
 * record, which Arm and Arm64 fill; the rest is shared.
 *
 * References: Ken Thompson, "Plan 9 C Compilers", section "Structure":
 * combined in the compiler are "the traditional roles of preprocessor,
 * lexical analyzer, parser, code generator, local optimizer, and first
 * half of the assembler"; A. V. Aho, M. S. Lam, R. Sethi and J. D.
 * Ullman, Compilers: Principles, Techniques, and Tools (2nd ed., 2006),
 * section 6.7, "Backpatching", for [gbranch] and [patch]: a branch
 * emitted before its target is known, its hole kept in a variable and
 * filled once the target exists. *)

(* what differs between the machines' instructions *)
type backend = {
  arch : Ix_asm.Asm.arch;
  nreg : int;
  nfreg : int;
  regret : int;
  fregret : int;
  regsp : int;
  reserved : int list;
  regtmp : int;
  word : int;
  float_from_last : bool;
  ret : string;
  offset32 : bool;
  zero_reg : int option;
  gmove : Tree.node -> Tree.node -> unit;
  gmover : Tree.node -> Tree.node -> unit;
  gopcode :
    Tree.op ->
    bool ->
    Tree.node option ->
    Tree.node option -> Tree.node option -> unit;
}

val be : backend option ref

val bk : unit -> backend

(* an instruction: from, reg and to in the listing's order *)
type prog = {
  mutable as_ : string;
  mutable cond : string list;
  mutable from : Ix_asm.Asm.operand option;
  mutable reg : int option;
  mutable to_ : Ix_asm.Asm.operand option;
  mutable pseudo : [ `Data of int | `Globl | `No | `Text of int ];
  ppc : int;
}

val progs : prog list ref

val pc : int ref

val p : unit -> prog

val nextpc : unit -> prog

val sx32 : int64 -> int64

val mask32 : int64 -> int64

val sx : int64 -> int64

(* a tree, addressable, as an operand *)
val naddr : Tree.node -> Ix_asm.Asm.operand

val naddr_opt : Tree.node option -> Ix_asm.Asm.operand option

val add_off : Ix_asm.Asm.operand option -> int -> Ix_asm.Asm.operand option

val raddr : Tree.node option -> prog -> unit

(* an instruction from f to t, appended *)
val gins : string -> Tree.node option -> Tree.node option -> prog

val ins : string -> Tree.node -> Tree.node -> unit

val is_mem : Tree.node -> bool

val samaddr : Tree.node -> Tree.node -> bool

(* a branch, its target to patch *)
val gbranch : Tree.op -> prog

(* the branch's target: a pc *)
val patch : prog -> int -> unit

val gpseudo : string -> Tree.sym -> Tree.node -> prog

val nodconst : int64 -> Tree.node

val nodfconst : float -> Tree.node

val nodreg : Tree.node -> int -> Tree.node

val regnode : unit -> Tree.node

val nodrat : Tree.node option ref

val nodret : Tree.node option ref

val regs : int array ref

val cursafe : int ref

val curarg : int ref

val maxargsafe : int ref

val regret : Tree.node -> Tree.node

val tmpreg : unit -> int

(* a register for a value of tn's type: o's if o is one of that
 * kind, else the next free one *)
val regalloc : Tree.node -> Tree.node option -> Tree.node

val regialloc : Tree.node -> Tree.node option -> Tree.node

val regfree : Tree.node -> unit

val regsalloc : Tree.node -> Tree.node

val regaalloc1 : Tree.node -> Tree.node

val regaalloc : Tree.node -> Tree.node

val regind : Tree.node -> Tree.node -> unit

val nrathole : int ref

val suppress : int ref

val outstring : string -> int -> int

val gextern : Tree.sym -> Tree.node -> int -> int -> unit

val init : unit -> unit

val gclean : unit -> unit

(* the program as 5c's -S prints it *)
val listing : unit -> string

(* the program as TinyAsm's object *)
val obj : string -> Ix_asm.Asm.obj
