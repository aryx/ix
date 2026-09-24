(* The linker's general part: the symbols, the objects and libraries
 * a program needs, the data's layout, the branches' targets, and the
 * bytes of the data -- everything that does not look inside an
 * instruction. The machine modules (Arm, Arm64) lay the code out and
 * encode it; the format modules (Elf, Aout, Macho) write the file.
 *
 *     load (objects, libraries) -> resolve (branches) -> layout_data
 *       -> Arm.rewrite -> Arm.layout (pcs, pools) -> Arm.encode -> Elf.write
 *
 * {b Why the linker encodes} (the plan's decision 1, and Asm.mli): it
 * does so after the whole program is laid out, so an address is known
 * whenever a word is made -- no relocations in the objects or here;
 * one encoder per machine, shared by the assembler's path and (next)
 * the compiler's; the choices that depend on distances (a literal
 * pool or not, a long branch or not) made once, knowing them; and the
 * machine confined to its module.
 *
 * Names: each function says which of 5l's (goken's linkers/5l, as the
 * Principia book documents it) and of xix's (linker/) it corresponds
 * to, so either can be found from here.
 *
 * References: Ken Thompson, "Plan 9 C Compilers" (Summer 1990 UKUUG
 * Conference), its section "The loader": code "reordered to remove
 * unconditional branch instructions", conditional branches inverted
 * and a few instructions copied instead of a branch ([follow]); and
 * external data allocated "with the smallest variables allocated
 * first", written for the MIPS, whose loads reach +-32K from R30
 * ([layout_data], for arm's R12); Leon Presser and John R. White,
 * "Linkers and Loaders" (ACM Computing Surveys, 1972), the classic
 * survey, which splits the job into allocation, linking, relocation
 * and loading -- here [layout_data] allocates, [load] and [resolve]
 * link, relocation has no pass of its own (the encoder writes final
 * addresses), and loading is the kernel's exec; John R. Levine,
 * Linkers and Loaders (2000), for archives and their symbol index, and
 * the one scan of Unix's ld that makes the order of libraries matter,
 * where [load] scans them all again until nothing new is defined. *)

type kind = Undefined | Text | Data | Bss

(* a symbol: a name and a version (0, or its object's for a name<>) *)
type sym = {
  name : string;
  version : int;
  mutable kind : kind;
  mutable value : int;        (* Text: its address; Data and Bss: its offset in the data *)
  mutable size : int;         (* Data and Bss *)
  created : int;              (* the order of creation, for the data's layout *)
}

(* the conditions both machines test, as 5a and 7a name them; CS and CC
 * are HS and LO *)
type cond = EQ | NE | HS | LO | MI | PL | VS | VC | HI | LS | GE | LT | GT | LE

(* the opposite condition *)
val invert : cond -> cond

(* the code both machines give a condition (arm's always is 14) *)
val cond_bits : cond -> int

val cond_of_string : string -> cond option
val string_of_cond : cond -> string

(* an opcode: those this part looks at, the rest the machine's ['m] *)
(* old: a string, compared here ("B", "BEQ", "TEXT") and matched in the
 * machines with catch-alls; each machine inverted a condition with its
 * own table of strings, and a typo in one was an error at run time *)
type 'm op =
  | Func                (* TEXT *)
  | Nop
  | B
  | Bl
  | Bcond of cond       (* BEQ ... *)
  | Bcase
  | Ins of 'm

(* an opcode from its name, the machine's [decode] for the rest *)
val decode : (string -> 'm option) -> string -> 'm op option

val show_op : ('m -> string) -> 'm op -> string

(* an instruction of the program, with what linking adds to it
 * (5l's Prog, xix's Types.node) *)
type 'm prog = {
  mutable op : 'm op;
  mutable suffixes : string list;
  mutable args : Asm.operand list;
  mutable pc : int;
  mutable target : 'm prog option;   (* a branch's target; a load's pool word (5l's p->cond) *)
  version : int;                  (* its object's, for the object's name<>s *)
  where : string * int;           (* its file and line *)
  mutable frame : int;            (* TEXT: the frame size, as written; the machine rounds it *)
  mutable leaf : bool;            (* TEXT: calls nothing *)
  mutable rule : int;             (* the machine's cached choice of encoding, -1 before *)
}

(* a DATA: a symbol, an offset, a width, a value *)
type data = { dsym : sym; off : int; width : int; value : Asm.operand; dversion : int }

type 'm t = {
  arch : Asm.arch;
  syms : (string * int, sym) Hashtbl.t;
  mutable ncreated : int;
  mutable progs : 'm prog list;
  mutable datas : data list;
  mutable text_start : int;       (* INITTEXT *)
  mutable data_start : int;       (* INITDAT *)
  mutable text_size : int;
  mutable data_size : int;
  mutable bss_size : int;
  mutable data_round : int;       (* INITRND: the data's start is rounded to it *)
  mutable pie : bool;             (* position independent (Mach-O): no absolute address in the code *)
}

exception Error of string

(* an instruction as the assembler writes it *)
val show : ('m -> string) -> 'm prog -> string

(* raise Error, printf-style *)
val error : ('a, unit, string, 'b) format4 -> 'a

(* a shift's kind, as both machines encode it *)
val shift_bits : Asm.shift_kind -> int

val create : Asm.arch -> text_start:int -> 'm t

(* [lookup t name version]: 5l's lookup; created as Undefined *)
val lookup : 'm t -> string -> int -> sym

(* the symbol a memory operand names, from the object of [version] *)
val sym_of : 'm t -> int -> Asm.name -> sym

(* [load t files]: the objects, then from the libraries (.a) the objects
 * defining what is still undefined, until nothing new is (5l's
 * objfile, loadlib and ldobj; xix's Load). [needs]: the names the
 * machine's rewriting will call, which the libraries must define too
 * (5l's needsdiv) *)
val load : < Cap.open_in; .. > -> 'm t -> decode:(string -> 'm option) -> ?needs:('m prog list -> string list) -> string list -> unit

(* [make_library out objs]: the objects, and the symbols each defines
 * (Plan 9's ar; xix's Library_file) *)
val make_library : < Cap.open_in; Cap.open_out; .. > -> string -> string list -> unit

(* branch targets: a BL f(SB) to f's TEXT, a branch to a branch to the
 * final one (5l's patch and brloop; xix's Resolve) *)
val resolve : 'm t -> unit

(* the code in the order its flow goes, the dead code dropped (5l's
 * and 7l's follow): [ends] a prog that ends the flow *)
val follow : 'm t -> ends:('m prog -> bool) -> unit

(* each data symbol's offset (5l's dodata; xix's Layout.layout_data):
 * small ones (<= 64 bytes, bss included) first, then the data, then
 * the bss, each in 5l's hash-table order, so that the addresses are
 * goken's *)
val layout_data : 'm t -> unit

(* the data segment's bytes (5l's datblk; xix's Datagen) *)
val data_bytes : 'm t -> Bytes.t

(* a double's bits as a single's, as 5l rounds them (5l's ieeedtof) *)
val single_bits : float -> int

(* a float constant as a memory operand, its symbol and DATA made
 * once; [single] for 4 bytes (5l's and 7l's ldobj) *)
val float_constant : 'm t -> float -> single:bool -> Asm.operand

(* the data's pointers, as offsets in the data, sorted (for Mach-O's
 * rebase stream) *)
val pointers : 'm t -> int list

(* the entry's address *)
val entry : 'm t -> string -> int

(* [put32 b off v]: little-endian words and halves into bytes *)
val put32 : Bytes.t -> int -> int -> unit
val put64 : Bytes.t -> int -> int -> unit

val rnd : int -> int -> int

(* the NOPs out, as 5c -O0 leaves them, a branch to one to the next
 * instruction (5l's and 7l's noops) *)
val drop_nops : 'm t -> unit
