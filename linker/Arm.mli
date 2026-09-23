(* The arm machine (5l): the rewriting of frames, returns and
 * divisions, the layout of the code with its literal pools, and the
 * encoding of each instruction by the first of 5l's rules that takes
 * its operands. *)

(* immediates as a real ARM rotation, not goken's 64-bit one *)
val rotate : bool ref

(* the names the program needs besides its own (_div... for DIV) *)
val needs : Link.prog list -> string list

(* B.NE as BNE; float constants into the data (5a's outcode, 5l's
 * ldobj) *)
val prepare : Link.t -> unit

(* the code in its flow's order, the dead code dropped (5l's follow) *)
val follow : Link.t -> unit

(* prologues, RET, DIV and MOD, negative ADD and SUB (5l's noops, and
 * ldobj's part; xix's Rewrite5) *)
val rewrite : Link.t -> unit

(* each instruction's pc, the literal pools, t.text_size, t.data_start
 * (5l's dotext; xix's Layout5) *)
val layout : Link.t -> unit

(* the text's bytes (5l's asmout; xix's Codegen5) *)
val encode : Link.t -> Bytes.t
