(* ARM's 32-bit instructions (A32, ARM mode): a word decoded once into
 * a variant, and printed as binutils' objdump prints it (the decoder's
 * test: every word the corpus runs, machine/tests/words_arm.txt,
 * printed the same by both; plan_arm.md, phase 1).
 *
 *   e0823103   Dp {op = ADD; rd = 3; rn = 2; op2 = Sreg (3, By_imm (LSL, 2))}
 *              add  r3, r2, r3, lsl #2
 *   e59f0414   Mem {load; size = Word; rd = 0; rn = 15; offset = Off_imm 1044; ...}
 *              ldr  r0, [pc, #1044]
 *   e8bd8010   Block {load; rn = 13; writeback; mode = IA; regs = r4, pc}
 *              pop  {r4, pc}
 *   1a000003   Branch {cond = NE; link = false; offset = 12}
 *              bne  0x14            (at address 0: the pc reads 8 ahead)
 *
 * A word's class is in bits 27-25 (data processing, loads and stores,
 * block transfers, branches, coprocessor and svc); inside class 000,
 * bits 7-4 separate multiplies (1001), halfword and signed transfers
 * (1xx1), and the miscellaneous instructions (bx, clz). A word no case
 * matches is [Undefined]: the corpus decides what is decoded
 * (plan_arm.md's principles).
 *
 * References: ARM Architecture Reference Manual, ARMv7-A and ARMv7-R
 * edition (ARM DDI 0406; from memory), the encodings; binutils'
 * objdump 2.42, run, the printed form. *)

type reg = int                (* 0-15: r0-r9, sl, fp, ip, sp, lr, pc *)

type cond = EQ | NE | CS | CC | MI | PL | VS | VC | HI | LS | GE | LT | GT | LE | AL

type dp_op = AND | EOR | SUB | RSB | ADD | ADC | SBC | RSC | TST | TEQ | CMP | CMN | ORR | MOV | BIC | MVN

type shift = LSL | LSR | ASR | ROR

(* how a register operand is shifted: an amount of 1-32 (LSR and ASR
 * #32 are encoded as 0), by a register, or RRX (ROR #0) *)
type shifted = No_shift | By_imm of shift * int | By_reg of shift * reg | Rrx

(* the second operand: an 8-bit value rotated right by an even amount,
 * or a register, shifted *)
type operand = Imm of { imm8 : int; rot : int } | Sreg of reg * shifted

type size = Word | Byte | Half | Sbyte | Shalf | Dword

type offset = Off_imm of int | Off_reg of reg * shifted

type index = Pre | Post

type mode = IA | IB | DA | DB

type t =
  | Dp of { cond : cond; op : dp_op; s : bool; rd : reg; rn : reg; op2 : operand }
  | Mul of { cond : cond; s : bool; rd : reg; rm : reg; rs : reg; acc : reg option }
  | Mull of { cond : cond; s : bool; signed : bool; acc : bool; rdlo : reg; rdhi : reg; rm : reg; rs : reg }
  (* up: the offset added; writeback with Pre: "!"; Post always writes
   * back, and with the W bit set is the unprivileged access (ldrt,
   * strbt: [user]) *)
  | Mem of { cond : cond; load : bool; size : size; rd : reg; rn : reg; offset : offset; up : bool; index : index; writeback : bool; user : bool }
  | Block of { cond : cond; load : bool; rn : reg; writeback : bool; mode : mode; regs : int; psr : bool }
  | Branch of { cond : cond; link : bool; offset : int }
  | Bx of { cond : cond; link : bool; rm : reg }
  | Clz of { cond : cond; rd : reg; rm : reg }
  | Svc of { cond : cond; imm : int }
  | Undefined of int

val decode : int -> t

(* objdump's text, the instruction at [addr] (for branch targets) *)
val print : addr:int -> t -> string

(* the value of an Imm operand, and the shifter's carry out when the
 * rotation is not 0 (bit 31 of the value) *)
val imm_value : imm8:int -> rot:int -> int

val reg_name : reg -> string
