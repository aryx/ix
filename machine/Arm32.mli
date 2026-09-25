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
  (* the status register, CPSR; [fields]: the mask, bits f s x c *)
  (* the CPSR, or the mode's SPSR ([spsr]) *)
  | Mrs of { cond : cond; rd : reg; spsr : bool }
  | Msr of { cond : cond; spsr : bool; fields : int; src : operand }
  (* mcr ([load] false), mrc: a coprocessor's register (CP15's, the
   * system's), cp <> 10, 11 *)
  | Coproc of { cond : cond; load : bool; cp : int; opc1 : int; crn : int; crm : int; opc2 : int; rd : reg }
  (* mcrr, mrrc: two registers (the ARM1176's cache range operations) *)
  | Coproc2 of { cond : cond; load : bool; cp : int; opc1 : int; crm : int; rd : reg; rd2 : reg }
  (* sxtb sxth uxtb uxth, and with an addend (rn <> 15) sxtab...:
   * rm rotated right by 8 * rot, a byte or a half extended *)
  | Extend of { cond : cond; signed : bool; half : bool; rd : reg; rn : reg; rm : reg; rot : int }
  (* 0 nop, 1 yield, 2 wfe, 3 wfi, 4 sev *)
  | Hint of { cond : cond; hint : int }
  | Swp of { cond : cond; byte : bool; rd : reg; rm : reg; rn : reg }
  (* ldrex, strex: the exclusive monitor is the state's *)
  | Ldrex of { cond : cond; rd : reg; rn : reg }
  | Strex of { cond : cond; rd : reg; rm : reg; rn : reg }
  | Clrex
  (* dsb (4), dmb (5), isb (6), the full system's: no effect here *)
  | Barrier of { kind : int }
  (* VFP's control registers (0 FPSID, 1 FPSCR, 8 FPEXC), and its double
   * registers' loads and stores: what 9pi's kernel uses *)
  | Vmrs of { cond : cond; reg : int; rd : reg }
  | Vmsr of { cond : cond; reg : int; rd : reg }
  | Vldst of { cond : cond; load : bool; d : int; rn : reg; offset : int }
  | Svc of { cond : cond; imm : int }
  | Undefined of int

val decode : int -> t

(* objdump's text, the instruction at [addr] (for branch targets) *)
val print : addr:int -> t -> string

(* the value of an Imm operand, and the shifter's carry out when the
 * rotation is not 0 (bit 31 of the value) *)
val imm_value : imm8:int -> rot:int -> int

val reg_name : reg -> string

(*****************************************************************************)
(* Execution *)
(*****************************************************************************)

(* the user-mode state: r0-r15 (words), the flags; [next] is the address
 * the instruction running jumps to, pc + 4 unless it writes pc *)
type state = {
  r : int array;
  mutable n : bool;
  mutable z : bool;
  mutable c : bool;
  mutable v : bool;
  mutable next : int;
  mem : Memory.t;
  (* the privileged state, a system's (plan_pi.md, decision 1); user
   * mode keeps usr (0x10), no MMU. [mode]: the CPSR's mode bits; the
   * A, I, F masks; [banked]: r13 and r14 of each bank not current (usr
   * and sys, svc, abt, und, irq, fiq); [fiq_banked]: r8-r12, the other
   * modes' (0-4) or FIQ's (5-9), whichever is not current; [spsr] per
   * bank. [translate]: the MMU, a virtual address and an access (bit
   * 0 a write, bit 1 as user) to a physical one, or Abort, used when
   * [mmu]; [coproc]: mcr and mrc; [vectors]: 0 or 0xffff0000 *)
  mutable mode : int;
  mutable a_off : bool;
  mutable i_off : bool;
  mutable f_off : bool;
  banked : int array;
  fiq_banked : int array;
  spsr : int array;
  mutable mmu : bool;
  mutable translate : int -> int -> int;
  mutable coproc : state -> t -> unit;
  mutable vectors : int;
  mutable exclusive : int;          (* the monitor's physical address, -1 open *)
  mutable vfp_ok : bool;            (* VFP granted (CPACR) *)
  vfp : int array;                  (* d0-d31, two words each *)
  mutable fpscr : int;
  mutable fpexc : int;
  mutable fpsid : int;
}

exception Unimplemented of int * int  (* the word, its address *)

(* a translation fault: the address, the fault status (FSR's) *)
exception Abort of int * int

val create : Memory.t -> state

(* the instruction at [addr], r15 reading addr + 8; [svc] runs a
 * system call *)
val execute : state -> addr:int -> svc:(state -> int -> unit) -> t -> unit

val cond_passed : state -> cond -> bool

(* the privileged state *)
val cpsr : state -> int
val write_cpsr : state -> int -> int -> unit     (* the value, the fields f s x c *)
val set_mode : state -> int -> unit

type exn_kind = Reset | Undefined_instruction | Supervisor_call | Prefetch_abort | Data_abort | Irq | Fiq

(* an exception taken, [ret] into the new mode's lr; st.next the vector *)
val take : state -> exn_kind -> ret:int -> unit
