(* tinyasm: the assembler. Reads a .s file, writes its object, the
 * instructions as they are (Asm): tinyasm -m 5|7 [-o out] file.s
 * (the default output: file.5 or file.7). An error names the file and
 * the line. *)

val main : string array -> int
