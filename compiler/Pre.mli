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

type input = { text : string; mutable pos : int; }

val includes : string list ref

val peekc : int option ref

val eof : int

val raw : unit -> int

(* the text, read next *)
val push : string -> unit

val getc : unit -> int

val unget : int -> unit

val is_alpha : int -> bool

val is_digit : int -> bool

val is_alnum : int -> bool

val is_space : int -> bool

val chr : int -> char

val dodefine : string -> unit

(* the expansion of a use of s, its arguments read *)
val macexpand : Tree.sym -> string

(* how #include reads a file, set by CLI (with its capability) *)
val read_file : (string -> string option) ref

(* #pragma profile's: whether TEXT gets NOPROF *)
val profile : bool ref

(* the directive after a '#' *)
val domacro : unit -> unit
