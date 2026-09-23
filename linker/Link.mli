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
 * to, so either can be found from here. *)

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

(* an instruction of the program, with what linking adds to it
 * (5l's Prog, xix's Types.node) *)
type prog = {
  mutable op : string;
  mutable suffixes : string list;
  mutable args : Asm.operand list;
  mutable pc : int;
  mutable target : prog option;   (* a branch's target; a load's pool word (5l's p->cond) *)
  version : int;                  (* its object's, for the object's name<>s *)
  where : string * int;           (* its file and line *)
  mutable frame : int;            (* TEXT: the frame size, as written; the machine rounds it *)
  mutable leaf : bool;            (* TEXT: calls nothing *)
  mutable rule : int;             (* the machine's cached choice of encoding, -1 before *)
}

(* a DATA: a symbol, an offset, a width, a value *)
type data = { dsym : sym; off : int; width : int; value : Asm.operand; dversion : int }

type t = {
  arch : Asm.arch;
  syms : (string * int, sym) Hashtbl.t;
  mutable ncreated : int;
  mutable progs : prog list;
  mutable datas : data list;
  mutable text_start : int;       (* INITTEXT *)
  mutable data_start : int;       (* INITDAT *)
  mutable text_size : int;
  mutable data_size : int;
  mutable bss_size : int;
}

exception Error of string

(* raise Error, printf-style *)
val error : ('a, unit, string, 'b) format4 -> 'a

val create : Asm.arch -> text_start:int -> t

(* [lookup t name version]: 5l's lookup; created as Undefined *)
val lookup : t -> string -> int -> sym

(* the symbol a memory operand names, from the object of [version] *)
val sym_of : t -> int -> Asm.name -> sym

(* [load t files]: the objects, then from the libraries (.a) the objects
 * defining what is still undefined, until nothing new is (5l's
 * objfile, loadlib and ldobj; xix's Load). [needs]: the names the
 * machine's rewriting will call, which the libraries must define too
 * (5l's needsdiv) *)
val load : t -> ?needs:(prog list -> string list) -> string list -> unit

(* [make_library out objs]: the objects, and the symbols each defines
 * (Plan 9's ar; xix's Library_file) *)
val make_library : string -> string list -> unit

(* branch targets: a BL f(SB) to f's TEXT, a branch to a branch to the
 * final one (5l's patch and brloop; xix's Resolve) *)
val resolve : t -> unit

(* the code in the order its flow goes, the dead code dropped (5l's
 * and 7l's follow): [ends] a prog that ends the flow, [invert] a
 * conditional branch's opposite *)
val follow : t -> ends:(prog -> bool) -> invert:(string -> string) -> unit

(* each data symbol's offset (5l's dodata; xix's Layout.layout_data):
 * small ones (<= 64 bytes, bss included) first, then the data, then
 * the bss, each in 5l's hash-table order, so that the addresses are
 * goken's *)
val layout_data : t -> unit

(* the data segment's bytes (5l's datblk; xix's Datagen) *)
val data_bytes : t -> Bytes.t

(* a double's bits as a single's, as 5l rounds them (5l's ieeedtof) *)
val single_bits : float -> int

(* a float constant as a memory operand, its symbol and DATA made
 * once; [single] for 4 bytes (5l's and 7l's ldobj) *)
val float_constant : t -> float -> single:bool -> Asm.operand

(* the entry's address *)
val entry : t -> string -> int

(* [put32 b off v]: little-endian words and halves into bytes *)
val put32 : Bytes.t -> int -> int -> unit
val put64 : Bytes.t -> int -> int -> unit

val rnd : int -> int -> int
