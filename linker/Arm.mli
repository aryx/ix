(* The arm machine (5l): the rewriting of frames, returns and
 * divisions, the layout of the code with its literal pools, and the
 * encoding of each instruction by the form its opcode and its
 * operands' classes select, in the order of 5l's rules.
 *
 * References: T. G. Szymanski, "Assembling Code for Machines with
 * Span-dependent Instructions" (CACM, 1978), the road not taken: when
 * an instruction's size depends on the distance it spans, sizes and
 * addresses depend on each other, and the layout is redone until no
 * branch grows. Thompson's "Plan 9 C Compilers" cites it for the
 * 68020's loader, and says of the MIPS that "all instructions are one
 * size. A single pass over the instructions will determine the
 * locations" -- arm's case too, so [layout] is one pass, a literal
 * pool being put out before its first load would be out of reach.
 * David Wheeler, "The use of sub-routines in programmes" (ACM National
 * Meeting, 1952), EDSAC's call: the return address arrives in a
 * register, as BL leaves it in R14, which a leaf keeps there; but the
 * subroutine planted it in its own last order, so it could not call
 * itself. Edsger Dijkstra, "Recursive programming" (Numerische
 * Mathematik, 1960), the stack instead of fixed cells: where
 * [rewrite]'s prologue pushes R14, below the frame, for a non-leaf. *)

(* the machine's opcodes (5.out.h) *)
type op

(* an opcode from its name, and back *)
val decode : string -> op option
val show : op -> string

(* immediates as a real ARM rotation, not goken's 64-bit one *)
val rotate : bool ref

(* the names the program needs besides its own (_div... for DIV) *)
val needs : op Link.prog list -> string list

(* B.NE as BNE; float constants into the data (5a's outcode, 5l's
 * ldobj) *)
val prepare : op Link.t -> unit

(* the code in its flow's order, the dead code dropped (5l's follow) *)
val follow : op Link.t -> unit

(* prologues, RET, DIV and MOD, negative ADD and SUB (5l's noops, and
 * ldobj's part; xix's Rewrite5) *)
val rewrite : op Link.t -> unit

(* each instruction's pc, the literal pools, t.text_size, t.data_start
 * (5l's dotext; xix's Layout5) *)
val layout : op Link.t -> unit

(* the text's bytes (5l's asmout; xix's Codegen5) *)
val encode : op Link.t -> Bytes.t
