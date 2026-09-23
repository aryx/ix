(* The executable's file: ELF (Linux), Plan 9's a.out or Mach-O (arm64 macOS), from the
 * text's and the data's bytes (5l's asmb; goken's liblk/elf.c; xix's
 * Executable) *)

type format = Elf | Plan9 | Macho

type image = { text : Bytes.t; data : Bytes.t; bss : int; text_start : int; data_start : int; entry : int;
               pointers : int list;   (* the data's pointers, for Mach-O's rebase *)
               round : int }          (* INITRND *)

(* the header's size, before the text (5l's HEADR) *)
val headr : format * Asm.arch -> int

val write : < Cap.open_out; .. > -> format -> Asm.arch -> string -> image -> unit
