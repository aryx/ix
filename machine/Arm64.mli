(* ARM's 64-bit instructions (A64, AArch64): a word decoded once into a
 * variant, and printed as binutils' objdump prints it (the decoder's
 * test: the words the arm64 corpus runs, machine/tests/words_arm64.txt,
 * and random words of the decoded classes; plan_arm.md, phase 5).
 *
 *   910043ff   Add_imm {sub = false; rd = 31 (sp); rn = 31; imm = 16}
 *              add  sp, sp, #0x10
 *   b9400fe0   Mem {load; size = Word; rt = 0; addr = Base {rn = 31; offset = 12; mode = Offset}}
 *              ldr  w0, [sp, #12]
 *   2a0103e0   Logic_reg {op = ORR; rd = 0; rn = 31 (wzr); rm = 1}
 *              mov  w0, w1        (objdump's alias)
 *
 * A64's word has its class in bits 28-25 (data processing with an
 * immediate, branches, loads and stores, data processing on registers;
 * SIMD and floating point are left undecoded, the corpus running
 * none). Register 31 is sp or the zero register (xzr, wzr), by
 * operand: the variant keeps 31, the printer and the executor know
 * which. [sf]: X, the 64-bit form, or W, the 32-bit one.
 *
 * objdump prints many instructions under an alias (mov for orr, add
 * and movz; cmp for subs; lsl, asr, ubfx, sxtw for the bitfield moves;
 * cset for csinc; mul for madd...): the printer chooses them as
 * binutils does, by the rules of the ARMv8 ARM's alias conditions.
 *
 * References: ARM Architecture Reference Manual, ARMv8-A (ARM DDI
 * 0487; from memory), the encodings and the aliases' conditions;
 * binutils' objdump 2.42, run, the printed forms. *)

type reg = int                (* 0-30, and 31: sp or zr *)

type sf = W | X

type cond = EQ | NE | CS | CC | MI | PL | VS | VC | HI | LS | GE | LT | GT | LE | AL | NV

type shift = LSL | LSR | ASR | ROR

type extend = UXTB | UXTH | UXTW | UXTX | SXTB | SXTH | SXTW | SXTX

type logic = AND | ORR | EOR | ANDS

type size = Byte | Half | Word | Dword

(* Offset: scaled by the size (ldr, str); Unscaled (ldur) and Unpriv
 * (ldtr) take a signed byte offset; Pre and Post write back *)
type mode = Offset | Unscaled | Unpriv | Pre | Post

type addr =
  | Base of { rn : reg; offset : int; mode : mode }
  (* the index register, extended, shifted by the size when [s] *)
  | Index of { rn : reg; rm : reg; extend : extend; s : bool }
  | Literal of int            (* pc-relative *)

type pair_mode = P_offset | P_pre | P_post | P_nontemporal

type hint = Yield | Wfe | Wfi | Sev | Sevl

type pstate_field = Spsel | Daifset | Daifclr

type barrier = Dsb | Dmb | Isb | Clrex

(* claude: the floating point's sizes, operations *)
type fsize = S | D | Q
type fop2 = Fadd | Fsub | Fmul | Fdiv | Fnmul
type fop1 = Fmov | Fabs | Fneg | Fsqrt

type t =
  | Add_imm of { sf : sf; sub : bool; s : bool; rd : reg; rn : reg; imm : int; lsl12 : bool }
  | Add_reg of { sf : sf; sub : bool; s : bool; rd : reg; rn : reg; rm : reg; shift : shift; amount : int }
  | Add_ext of { sf : sf; sub : bool; s : bool; rd : reg; rn : reg; rm : reg; extend : extend; amount : int }
  | Adc of { sf : sf; sub : bool; s : bool; rd : reg; rn : reg; rm : reg }
  | Logic_imm of { sf : sf; op : logic; rd : reg; rn : reg; imm : int64 }
  (* invert: bic, orn, eon, bics *)
  | Logic_reg of { sf : sf; op : logic; invert : bool; rd : reg; rn : reg; rm : reg; shift : shift; amount : int }
  | Movn of { sf : sf; rd : reg; imm16 : int; hw : int }
  | Movz of { sf : sf; rd : reg; imm16 : int; hw : int }
  | Movk of { sf : sf; rd : reg; imm16 : int; hw : int }
  | Sbfm of { sf : sf; rd : reg; rn : reg; immr : int; imms : int }
  | Bfm of { sf : sf; rd : reg; rn : reg; immr : int; imms : int }
  | Ubfm of { sf : sf; rd : reg; rn : reg; immr : int; imms : int }
  | Extr of { sf : sf; rd : reg; rn : reg; rm : reg; lsb : int }
  (* adrp's offset in pages (4GB away: more than js_of_ocaml's ints) *)
  | Adr of { page : bool; rd : reg; offset : int }
  (* csel, csinc, csinv, csneg *)
  | Csel of { sf : sf; inc : bool; inv : bool; rd : reg; rn : reg; rm : reg; cond : cond }
  (* ccmp, ccmn: [imm] is Rm's field read as a 5-bit value *)
  | Ccmp of { sf : sf; neg : bool; rn : reg; imm : bool; rm : reg; nzcv : int; cond : cond }
  | Rbit of { sf : sf; rd : reg; rn : reg }
  | Rev of { sf : sf; bytes : int; rd : reg; rn : reg }     (* rev16, rev32, rev (the register's size) *)
  | Clz of { sf : sf; cls : bool; rd : reg; rn : reg }
  | Div of { sf : sf; signed : bool; rd : reg; rn : reg; rm : reg }
  | Shiftv of { sf : sf; shift : shift; rd : reg; rn : reg; rm : reg }
  | Madd of { sf : sf; sub : bool; rd : reg; rn : reg; rm : reg; ra : reg }
  (* smaddl, umaddl, smsubl, umsubl: 32 x 32 + 64 *)
  | Maddl of { signed : bool; sub : bool; rd : reg; rn : reg; rm : reg; ra : reg }
  | Mulh of { signed : bool; rd : reg; rn : reg; rm : reg }
  | B of { link : bool; offset : int }
  | Bcond of { cond : cond; offset : int }
  | Cbz of { sf : sf; nz : bool; rt : reg; offset : int }
  | Tbz of { nz : bool; rt : reg; bit : int; offset : int }
  | Br of { link : bool; rn : reg }
  | Ret of reg
  (* [signed]: the width a signed load extends to; None, zero-extended *)
  | Mem of { load : bool; size : size; signed : sf option; rt : reg; addr : addr }
  (* ldp, stp, ldpsw ([signed]) *)
  | Pair of { load : bool; sf : sf; signed : bool; rt : reg; rt2 : reg; rn : reg; offset : int; mode : pair_mode }
  | Svc of int
  | Hvc of int
  | Smc of int
  | Brk of int
  | Nop
  | Hint of hint
  (* the system registers, by their 16-bit encoding (op0, op1, CRn,
   * CRm, op2: [sysreg]); only those of the table, the rest Undefined *)
  | Mrs of { rt : reg; sr : int }
  | Msr of { rt : reg; sr : int }
  | Msr_imm of { field : pstate_field; imm : int }
  (* dc, ic, tlbi, at: the operations of the table, by op1:CRn:CRm:op2 *)
  | Sys of { op : int; rt : reg }
  | Barrier of { kind : barrier; option : int }
  | Eret
  (* ldxr, ldaxr, stxr, stlxr ([exclusive]); ldar, stlr, ldlar, stllr;
   * [ordered]: acquire for a load, release for a store; [rs] the
   * status register of an exclusive store *)
  | Excl of { load : bool; size : size; ordered : bool; exclusive : bool; rs : reg; rt : reg; rn : reg }
  (* claude: the scalar floating point (the OCaml runtime's doubles:
   * kernel/xv6's Pi4 kernel), on v0-v31's low 64 bits (s, d); [q] a
   * 128-bit load or store (a variadic function saving v0-v7), its high
   * half zero (scalar writes clear it, nothing else writes it) *)
  | Fmem of { load : bool; fsize : fsize; rt : reg; addr : addr }
  | Fpair of { load : bool; fsize : fsize; rt : reg; rt2 : reg; rn : reg; offset : int; mode : pair_mode }
  | Fop2 of { double : bool; op : fop2; rd : reg; rn : reg; rm : reg }
  | Fop1 of { double : bool; op : fop1; rd : reg; rn : reg }
  | Fmadd of { double : bool; neg : bool; sub : bool; rd : reg; rn : reg; rm : reg; ra : reg }
  | Fcmp of { double : bool; e : bool; rn : reg; rm : reg option (* None: with 0.0 *) }
  | Fcsel of { double : bool; rd : reg; rn : reg; rm : reg; cond : cond }
  | Fcvt of { to_double : bool; rd : reg; rn : reg }
  | Fcvt_int of { double : bool; sf : sf; signed : bool; rd : reg; rn : reg }   (* fcvtzs, fcvtzu *)
  | Cvtf of { double : bool; sf : sf; signed : bool; rd : reg; rn : reg }       (* scvtf, ucvtf *)
  | Fmov_gen of { double : bool; to_fp : bool; rd : reg; rn : reg }
  | Fmov_imm of { double : bool; rd : reg; imm8 : int }
  (* movi of a 64-bit vector: an element of [esize] bits, [imm8] shifted
   * left [amount], repeated; esize 64: imm8's bits a mask of bytes *)
  | Movi of { rd : reg; esize : int; imm8 : int; amount : int }
  | Shift_scalar of { signed : bool; rd : reg; rn : reg; shift : int }   (* sshr, ushr d *)
  | Undefined of int

val decode : int -> t

(* objdump's text, the instruction at [addr] (for branch targets) *)
val print : addr:int -> t -> string

(* the value of a logical immediate, N:immr:imms, for the width; None
 * for the reserved encodings *)
val bitmask : sf -> int -> int -> int -> int64 option

(*****************************************************************************)
(* Execution *)
(*****************************************************************************)

(* the state: x0-x30 and sp (slot 31), the flags; [next] is the
 * address the instruction running jumps to, pc + 4 unless it
 * branches.
 *
 * And the privileged state (plan_pi.md, phase G), which user mode
 * (mini-5i) leaves at EL0 with the MMU off: the exception level, SPSel
 * and the stack pointers of each level (slot 31 the current one,
 * [sp_el] the others), DAIF (D 8, A 4, I 2, F 1), and per level ELR,
 * SPSR, ESR, FAR, VBAR. The board supplies the rest: the MMU's
 * translation (an address, bit 0 a write, bit 1 as user, to a
 * physical address, or Abort), the other system registers, and the
 * system instructions (hints, dc, ic, tlbi, at, hvc, smc, brk).
 * [monitor]: the exclusive monitor's physical address, -1 clear. *)
type state = {
  x : int64 array;
  mutable n : bool;
  mutable z : bool;
  mutable c : bool;
  mutable v : bool;
  mutable next : int;
  mem : Memory.t;
  mutable el : int;
  mutable spsel : bool;
  sp_el : int64 array;
  mutable daif : int;
  elr : int64 array;
  spsr : int64 array;
  esr : int64 array;
  far : int64 array;
  vbar : int64 array;
  mutable mmu : bool;
  mutable translate : int64 -> int -> int;
  mutable read_sysreg : int -> int64;
  mutable write_sysreg : int -> int64 -> unit;
  mutable system : state -> t -> unit;
  mutable monitor : int;
  (* claude: v0-v31's low 64 bits, the scalar floating point's s and d *)
  fp : int64 array;
}

exception Unimplemented of int * int  (* the word, its address *)

(* a translation fault: the virtual address, ESR's ISS (the fault
 * status code, bit 6 a write) *)
exception Abort of int64 * int

val create : Memory.t -> state

(* register r, 31 read as the zero register, or as sp *)
val get : state -> reg -> int64
val get_sp : state -> reg -> int64
val set : state -> sf -> reg -> int64 -> unit
val set_sp : state -> sf -> reg -> int64 -> unit

(* an address below 4GB, or Memory.Fault; and back, zero-extended *)
val address : int64 -> int
val of_address : int -> int64

val execute : state -> addr:int -> svc:(state -> int -> unit) -> t -> unit

val cond_passed : state -> cond -> bool

(* a system register's encoding, by its name ("sctlr_el1"), and back *)
val sysreg : string -> int
val sysreg_name : int -> string

(* a system operation's kind, name and whether it takes a register *)
val sysop : int -> string * string * bool

(* a program counter as a register holds it *)
val of_pc : int -> int64

(* the physical address of an access (bit 0 a write, bit 1 as user) *)
val phys : state -> int64 -> int -> int

(* PSTATE as SPSR keeps it *)
val pstate : state -> int64

(* an exception: [offset] 0 synchronous, 0x80 IRQ; [ret] ELR's *)
val take : state -> offset:int -> ret:int -> ?esr:int64 -> ?far:int64 -> unit -> unit

(* ESR's value: its class, the syndrome *)
val syndrome : int -> int -> int64
val ec_unknown : int
val ec_svc : int
val ec_hvc : int
val ec_smc : int
val ec_iabort_lower : int
val ec_iabort : int
val ec_dabort_lower : int
val ec_dabort : int
val ec_brk : int
