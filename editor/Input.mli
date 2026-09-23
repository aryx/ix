(* The command stream: where ed's characters come from.
 *
 * Three readers share it: the command loop, a character at a time;
 * input mode (a, i, c), a line at a time until one that is "."; and,
 * while g runs, its command list, a string read before the stream
 * (ed.c's globp), whose end is an end of file for that line's run.
 * One character can be pushed back (ed.c's peekc), and the last one
 * read is kept (lastc), for the clean-up after an error.
 *
 * Standard input is read one byte at a time, as plan9port's ed does,
 * so that a child of ! reads what ed has not. Characters are runes:
 * the bytes of a UTF-8 sequence are read together.
 *
 *     let t = of_string "1p\n" in
 *     getc t = Char.code '1';  unget t (Char.code '1');  getc t = Char.code '1'
 *     getc t = Char.code 'p';  getc t = nl;  getc t = eof *)

type t

(* ed's ?, and ?file: raised anywhere, caught by the command loop *)
exception Error of string

val eof : int
val nl : int

val of_fd : Unix.file_descr -> t
val of_string : string -> t

val getc : t -> int
val unget : t -> int -> unit
val lastc : t -> int
val set_lastc : t -> int -> unit

(* [line t]: input mode's line (NULs dropped), or None at the end of
 * the stream -- and then, in a g list, the end stays for the loop *)
val line : t -> string option

(* [digits t]: a number, 0 when there is none (ed.c's getnum) *)
val digits : t -> int

(* g's command list: run [list] in front of the stream *)
val set_global : t -> string option -> unit
val in_global : t -> bool

(* in a g list with more of it to come (a newline in s's replacement
 * is then part of it) *)
val global_has_more : t -> bool

(* ed.c's error_1 on the input: the g list dropped, the rest of the
 * line thrown away, and if standard input is a file, all of it *)
val recover : t -> unit
