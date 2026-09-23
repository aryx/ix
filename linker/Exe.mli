(* The executable's file: ELF (Linux) or Plan 9's a.out, from the
 * text's and the data's bytes (5l's asmb; goken's liblk/elf.c; xix's
 * Executable) *)

type format = Elf | Plan9

type image = { text : Bytes.t; data : Bytes.t; bss : int; text_start : int; data_start : int; entry : int }

(* the header's size, before the text (5l's HEADR) *)
val headr : format * Asm.arch -> int

val write : format -> Asm.arch -> string -> image -> unit
