(* The input and the preprocessor: files and macro expansions pushed
 * on one stack, which the lexer reads a character at a time ([getc]),
 * the directives handled as the lexer meets a '#' (lex.c's Io; macbody).
 *
 * There is no separate pass: an #include pushes the file, a macro's
 * use pushes its expansion, and each pops when exhausted. A macro is
 * stored in its symbol's [macro], its body's parameters already replaced
 * by their index, #a, #b... (5c's encoding: the expansion needs no parsing).
 *
 * References: Ken Thompson, "Plan 9 C Compilers", section "Parsing":
 * "The input stream of the parser is a pushdown list of input
 * activations. The preprocessor expansions of macros and #include are
 * implemented as pushdowns. Thus there is no separate pass for
 * preprocessing." *)

val includes : string list ref

(* the character put back, if any *)
val peekc : char option ref

(* the end of the input: a NUL is no C *)
val eof : char

(* the next byte, eof at the end *)
val raw : unit -> char

(* the text, read next *)
val push : string -> unit

(* the character put back, or the next *)
val read : unit -> char

(* the next, counting lines; an error at the end *)
val getc : unit -> char

val unget : char -> unit

val is_alpha : char -> bool
val is_digit : char -> bool
val is_alnum : char -> bool
val is_space : char -> bool

(* -Dname=value *)
val dodefine : string -> unit

(* the expansion of a use of s, its arguments read *)
val macexpand : Tree.sym -> string

(* how #include reads a file, set by CLI (with its capability) *)
val read_file : (string -> string option) ref

(* #pragma profile's: whether TEXT gets NOPROF *)
val profile : bool ref

(* the directive after a '#' *)
val domacro : unit -> unit
