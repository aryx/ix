(* The generated code and the machine's resources (txt.c, swt.c,
 * list.c, obj.c): the instructions ([prog]), their operands made from
 * trees ([naddr], to the assembler's Asm.operand), the registers, the
 * frame's safe area and outgoing arguments, the data of initializers
 * and strings; at the end the listing (-S) and the object.
 *
 * The object is mini-asm's Asm.obj, not goken's format: the compiler
 * produces what the assembler would, and mini-ld encodes both. The
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

(* what gopcode makes: an operator's instruction, 7c's negation and
 * complement, a call, a switch's table *)
type gop = Op of Tree.binop | Gneg | Gcom | Gcall | Gcase

(* the registers are numbered as 5c's: the integer ones, then the
 * floating ones from nreg *)
type backend = {
  arch : Ix_asm.Asm.arch;
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
  offset32 : bool;                    (* an operand's offset is 32 bits (5c's Adr) *)
  zero_reg : int option;              (* a constant 0 as a register (7c's raddr) *)
  gmove : Tree.expr -> Tree.expr -> unit;
  gmover : Tree.expr -> Tree.expr -> unit;
  gopcode : gop -> bool -> Tree.expr option -> Tree.expr option -> Tree.expr option -> unit;
}

val be : backend option ref
val bk : unit -> backend

(* from, reg and to are 5c's: the listing prints them in this order *)
type prog = {
  mutable as_ : string;
  mutable cond : string list;         (* .LS, .U, .W: the suffixes *)
  mutable from : Ix_asm.Asm.operand option;
  mutable reg : int option;           (* a second source register (F if from is) *)
  mutable to_ : Ix_asm.Asm.operand option;     (* Target is a pc until the end *)
  mutable pseudo : [ `No | `Text of int | `Data of int | `Globl ];   (* TEXT's flag, DATA's width *)
  ppc : int;                          (* the next one's, for DATA and GLOBL *)
}

(* the instructions, the last first; the next's pc *)
val progs : prog list ref
val pc : int ref

(* the last instruction; a new one *)
val p : unit -> prog
val nextpc : unit -> prog

(* a constant as 32 bits, sign-extended or not; an offset as the
 * machine's Adr holds it *)
val sx32 : int64 -> int64
val mask32 : int64 -> int64
val sx : int64 -> int64

(* an addressable tree as an operand *)
val naddr : Tree.expr -> Ix_asm.Asm.operand
val naddr_opt : Tree.expr option -> Ix_asm.Asm.operand option
val add_off : Ix_asm.Asm.operand option -> int -> Ix_asm.Asm.operand option

(* the register of a node, as a second source (txt.c's raddr) *)
val raddr : Tree.expr option -> prog -> unit

(* an instruction from f to t *)
val gins : string -> Tree.expr option -> Tree.expr option -> prog
val ins : string -> Tree.expr -> Tree.expr -> unit

(* a load's or a store's operand, and a move to itself *)
val is_mem : Tree.expr -> bool
val samaddr : Tree.expr -> Tree.expr -> bool

(* a comparison, both machines': a negative constant compared by CMN,
 * unless small says its negation overflows *)
val gcmp : string -> fd:bool -> small:(int64 -> bool) -> Tree.expr option -> Tree.expr option -> unit

(* the branch of a relation; a float's not taken on a NaN when tr *)
val grel : Tree.binop -> fd:bool -> tr:bool -> unit

(* a branch, its target to patch; a return *)
val gbranch : unit -> prog
val greturn : unit -> prog
val patch : prog -> int -> unit

(* TEXT, DATA, GLOBL of a symbol *)
val gpseudo : string -> Tree.sym -> Tree.expr -> prog

(* the nodes the generator makes: constants, registers; a register's
 * number *)
val nodconst : int64 -> Tree.expr
val nodfconst : float -> Tree.expr
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

(* .rathole's size; code generated then thrown away (> 0) *)
val nrathole : int ref
val suppress : int ref

(* n bytes of s in .string: their offset *)
val outstring : string -> int -> int

(* an initializer's data: s at o, of w bytes *)
val gextern : Tree.sym -> Tree.expr -> int -> int -> unit

(* a file's start; its end, the GLOBLs *)
val init : unit -> unit
val gclean : unit -> unit

(* the program as 5c's -S prints it; as mini-asm's object *)
val listing : unit -> string
val obj : Fpath.t -> Ix_asm.Asm.obj
