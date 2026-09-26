(* The generated code (txt.c, swt.c, list.c, obj.c), whatever the back
 * end: the instructions ([prog]), their operands made from addressable
 * trees ([naddr], to the assembler's Asm.operand), the data of
 * initializers and strings; at the end the GLOBLs, the listing (-S)
 * and the object. The registers and the frame's areas are each back
 * end's (compat/Regs.ml).
 *
 * The object is mini-asm's Asm.obj, not goken's format: the compiler
 * produces what the assembler would, and mini-ld encodes both. The
 * listing is 5c's and 7c's format, including Plan 9's %.17e for floats
 * ([listing]); compat's is theirs byte for byte (tests/listing.sh).
 *
 * References: Ken Thompson, "Plan 9 C Compilers", section "Structure":
 * combined in the compiler are "the traditional roles of preprocessor,
 * lexical analyzer, parser, code generator, local optimizer, and first
 * half of the assembler"; A. V. Aho, M. S. Lam, R. Sethi and J. D.
 * Ullman, Compilers: Principles, Techniques, and Tools (2nd ed., 2006),
 * section 6.7, "Backpatching", for [gbranch] and [patch]: a branch
 * emitted before its target is known, its hole kept in a variable and
 * filled once the target exists. *)

(* the machine: arm (5c's), else arm64; the integer registers' count,
 * the float ones numbered after them in a Reg node *)
val arm : unit -> bool
val nreg : unit -> int

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
 * machine's Adr holds it (32 bits on arm) *)
val sx32 : int64 -> int64
val mask32 : int64 -> int64
val sx : int64 -> int64

(* an addressable tree as an operand *)
val naddr : Tree.expr -> Ix_asm.Asm.operand
val naddr_opt : Tree.expr option -> Ix_asm.Asm.operand option
val add_off : Ix_asm.Asm.operand option -> int -> Ix_asm.Asm.operand option

(* an instruction from f to t *)
val gins : string -> Tree.expr option -> Tree.expr option -> prog
val ins : string -> Tree.expr -> Tree.expr -> unit

(* a branch, its target to patch *)
val gbranch : unit -> prog
val patch : prog -> int -> unit

(* TEXT, DATA, GLOBL of a symbol *)
val gpseudo : string -> Tree.sym -> Tree.expr -> prog

(* constants, of long and double *)
val nodconst : int64 -> Tree.expr
val nodfconst : float -> Tree.expr

(* code generated then thrown away (> 0): no strings written *)
val suppress : int ref

(* n bytes of s in .string: their offset *)
val outstring : string -> int -> int

(* an initializer's data: s at o, of w bytes *)
val gextern : Tree.sym -> Tree.expr -> int -> int -> unit

(* a file's start; its end: the strings' last DATA, the GLOBLs *)
val init : unit -> unit
val gclean : unit -> unit

(* the program as 5c's -S prints it; as mini-asm's object *)
val listing : unit -> string
val obj : Fpath.t -> Ix_asm.Asm.obj
