(* Plan 9's assembly language, for arm and arm64: the instructions
 * TinyAsm reads and writes, unencoded, into an object file, and that
 * TinyLd lays out and encodes.
 *
 *     TEXT  strchr(SB), $8           a function, the size of its frame
 *     MOVW  c+4(FP), R6              an argument: FP is the caller's frame
 *     MOVW  $table(SB), R1           an address: SB is the static base
 *     MOVW.EQ R1, R2                 a condition, as a suffix (arm)
 *     BNE   2(PC)                    a branch, counted in instructions
 *     DATA  msg+0(SB)/8, $"Hello, w" initialized data
 *     GLOBL msg(SB), $14             its size
 *
 * {b Why the assembler only parses, and the linker encodes.} This is
 * Plan 9's design (Thompson's and Pike's toolchain), the one xix
 * follows, and the one ix keeps, because it is the smallest:
 *
 * - {b No relocations.} The linker encodes after it has laid out the
 *   whole program, so every address is known when a word is made:
 *   objects carry no relocation records, and the linker has no
 *   relocation machinery, most of a Unix linker's complexity.
 * - {b One encoder per machine.} The C compiler will write these same
 *   instruction lists into an object, as 5c does, without printing
 *   assembly; the encoder is written once, in the linker, shared by
 *   both paths, instead of in the assembler and again in the compiler.
 * - {b Decisions made once, with everything known}: which form a branch
 *   takes, where literal pools go, how a large constant is built (one
 *   pool load on arm, up to four MOVZ/MOVK on arm64), what a function's
 *   prologue is. With the encoding in the assembler, each needs a guess
 *   now and a fixup later.
 * - {b The machine is in one place.} This module and the parser are the
 *   same for both targets but for a table of register names; which
 *   instructions exist, with which operands, is decided by the linker's
 *   module for each machine (linker/Arm, linker/Arm64), which is where
 *   having two targets forces the code to say what is general.
 *
 * The costs don't matter here: an object is not machine code, so it
 * can only be listed, not disassembled; and the linker redoes the
 * encoding at each link, which is why Go moved it back into its
 * compiler and assembler in 2013, for Google's large programs.
 *
 * {b One instruction type for both machines} (xix has a typed tree per
 * machine): an opcode, its dot suffixes, and operands from one set.
 * The linker's classifier rejects what a machine can't encode.
 *
 * References: Ken Thompson, "Plan 9 C Compilers" (Summer 1990 UKUUG
 * Conference, London), the design paper of this split: its loader
 * "combines the roles of second half of the assembler, global
 * optimizer, and loader", with the MIPS and the 68020 as examples;
 * Rob Pike, "A Manual for the Plan 9 assembler", for the syntax, the
 * pseudo-registers FP and SB, and the remark that the assemblers "are
 * really just variations of a single program" -- which one instruction
 * type makes literal; Russ Cox, "Go 1.3 Linker Overhaul" (2013), for
 * the move back, the encoding done once per package by the compiler
 * and the assembler because linking large programs redid it. *)

type arch = Arm | Arm64

(* a global name; [static] for name<>(SB), local to its file *)
type name = { sym : string; static : bool }

(* what a memory reference is relative to *)
type base = R of int | SB | FP | SP | PC

(* << >> -> @> *)
type shift_kind = Lsl | Lsr | Asr | Ror
(* old: an int, 0 to 3, the one the machines encode, indexing a table
 * of the arrows to print *)

type shift = { reg : int; kind : shift_kind; by : [ `Imm of int | `Reg of int ] }

type mem = {
  base : base;
  name : name option;        (* sym+off(SB) (and BL f(SB) is a call), or a
                                comment in name+off(FP) *)
  off : int64;
  index : shift option;      (* (R1)(R2), R2<<2(R1) *)
}

type operand =
  | Reg of int               (* R3; on arm64 31 is ZR or RSP, by context *)
  | FReg of int              (* F3 *)
  | Special of string        (* CPSR, FPCR, ...: registers without a number *)
  | Imm of int64             (* $42 *)
  | Fimm of float            (* $1.5 *)
  | Str of string            (* $"text" *)
  | Mem of mem               (* 8(R1), x+4(SB), c+4(FP), s-4(SP) *)
  | Addr of mem              (* $x(SB), $s-4(SP): the address itself *)
  | Shifted of shift         (* R1<<2 *)
  | Regs of int list         (* [R0-R3] *)
  | Pair of int * int        (* (R1, R2) *)
  | Target of int            (* a branch: an index into the object's items *)

type instr = { op : string; suffixes : string list; args : operand list }

type item =
  | Text of name * int * int64          (* flag, frame size *)
  | Globl of name * int * int64         (* flag, size *)
  | Data of name * int64 * int * operand (* offset, width, value *)
  | Ins of instr

type obj = { arch : arch; file : string; items : (item * int) array (* and its line *) }

(* the register names: R0-R15, SP, PC on arm; R0-R30, ZR, RSP on arm64 *)
val register : arch -> string -> operand option

(* the conditions both machines test, as 5a and 7a name them (CS and
 * CC are HS and LO); shared by the assembler, the linkers and the
 * compiler *)
(* old: strings in each, and in each linker a table inverting them *)
type cond = EQ | NE | HS | LO | MI | PL | VS | VC | HI | LS | GE | LT | GT | LE

(* the opposite condition *)
val invert : cond -> cond

(* the code both machines give it (arm's always is 14) *)
val cond_bits : cond -> int

val cond_of_string : string -> cond option
val string_of_cond : cond -> string

(* the objects, marshalled with a version; the files through the
 * capabilities *)
val save : < Cap.open_out; .. > -> string -> obj -> unit
val load : < Cap.open_in; .. > -> string -> obj

(* an instruction, as the assembler would read it back (for errors,
 * listings, and the round-trip law) *)
val show_item : item -> string
