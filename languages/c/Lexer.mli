(* The tokens, for Parser (lex.c's yylex): hand-written, not ocamllex.
 * It reads from Pre's input stack, whose '#' lines it hands to
 * [Pre.domacro], and it asks the symbol table whether a name is a
 * typedef's (the parser needs LTYPE: C's grammar is not context-free
 * without it). Both would be awkward through a lexbuf.
 *
 * References: M. E. Lesk and E. Schmidt, "Lex - A Lexical Analyzer
 * Generator" (Bell Labs CSTR 39, 1975), the road not taken, by 5c too. *)

val init : unit -> unit

val token : unit -> Parser.token
