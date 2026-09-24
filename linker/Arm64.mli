(* The arm64 machine (7l): frames and returns, the layout of the code
 * with its literal pool, and the encoding of each instruction by the
 * first of 7l's rules that takes its operands.
 *
 * References: as Arm.mli for the one-pass layout (Szymanski's problem
 * does not arise: every instruction is 4 bytes) and for the frames;
 * the Arm Architecture Reference Manual for A-profile, whose
 * DecodeBitMasks pseudocode defines the logical immediates -- a run of
 * ones, rotated, in an element of 2 to 64 bits, repeated -- the 5,334
 * values the encoder tabulates, as 7l's bits.c does. *)

(* the machine's opcodes (7.out.h) *)
type op

(* an opcode from its name, and back *)
val decode : string -> op option
val show : op -> string

(* frames rounded, negative ADD and SUB, float constants into the data
 * (7l's ldobj) *)
val prepare : op Link.t -> unit

(* the code in its flow's order (7l's follow) *)
val follow : op Link.t -> unit

(* prologues and RETURN (7l's noops; xix's Rewrite7) *)
val rewrite : op Link.t -> unit

(* each instruction's pc, the literal pool, t.text_size, t.data_start
 * (7l's span; xix's Layout7) *)
val layout : op Link.t -> unit

(* the text's bytes (7l's asmout; xix's Codegen7) *)
val encode : op Link.t -> Bytes.t
