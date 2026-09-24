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
  | Nop
  | Undefined of int

val decode : int -> t

(* objdump's text, the instruction at [addr] (for branch targets) *)
val print : addr:int -> t -> string

(* the value of a logical immediate, N:immr:imms, for the width; None
 * for the reserved encodings *)
val bitmask : sf -> int -> int -> int -> int64 option
