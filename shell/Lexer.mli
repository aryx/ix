(* The lexer: characters to rc's tokens, by hand (principia's lex.c).
 *
 * rc's lexer does four things a grammar can't:
 *
 *     'it''s'            the only quote is ', and '' in quotes is a quote
 *     $x.c   x$y         free carets: a word right after a word (no blank
 *                        between) is joined to it, as if by ^
 *     $x(1)              a ( right after a word is a subscript, not a list
 *     if(  echo if       keywords -- for in while if not switch fn ~ ! @ --
 *                        are words the parser gives meaning to; after one,
 *                        no free caret, so if( is if then (
 *
 * and a newline right after | && || is skipped, so a pipeline can go on
 * the next line. A # at the start of a token starts a comment.
 *
 * The characters that end a word are the blanks and \n#;&|^$=`'{}()<>
 * (lex.c's wordchr); after a $, a name stops at any punctuation
 * (idchr), so $stem.c is $stem^.c. An unquoted = can only be an
 * assignment: echo a=b is a syntax error, as in rc.
 *
 * Redirections come as one token with their file descriptors
 * (> >> < <> << and |, with [fd], [fd=], [fd=fd]):
 *
 *     >[2]   REDIR (Write, 2)       >[2=1]   DUP (2, 1)
 *     >[2=]  CLOSE 2                |[2]     PIPE (2, 0)
 *
 * Input is read a line at a time, through [refill], which is told
 * whether the command is continued: that is how the terminal prompts
 * with the first or the second string of $prompt. A here document's
 * body is read, raw, right after the line that asked for it.
 *
 * References: principia's lex.c; Tom Duff, "Rc -- The Plan 9 Shell"
 * (1990), "Free carets": "User demand has dictated that rc insert
 * carets in certain places, to make the syntax look more like the
 * Bourne shell", with the exact rule; S. R. Bourne, "An Introduction
 * to the UNIX Shell", for here documents, the lines between <<! and !
 * given as a command's standard input. *)

type token =
  | WORD of string * bool     (* text, quoted *)
  | DOLLAR | COUNT | JOIN     (* $ $# and dollar-quote *)
  | CARET | SUB               (* ^, and a ( right after a word *)
  | LPAREN | RPAREN | LBRACE | RBRACE
  | BACKQUOTE | EQUAL | SEMI | AMP | NEWLINE | EOF
  | ANDAND | OROR
  | PIPE of int * int
  | REDIR of Ast.rkind * int
  | HERE of int
  | DUP of int * int
  | CLOSE of int

type t

exception Error of string

(* [create ~refill]: [refill continued] is the next line, with its \n,
 * or None at the end *)
val create : refill:(bool -> string option) -> t

val of_string : string -> t

val token : t -> token

(* skip blanks, comments and newlines (after if(...), for(...) ...) *)
val skip_newlines : t -> unit

(* a new command starts: the next line read is not a continuation *)
val new_command : t -> unit

(* read this here document's body after the current line *)
val add_heredoc : t -> Ast.heredoc -> unit

(* skip the rest of the line, after a syntax error *)
val skip_line : t -> unit

val line : t -> int

(* for in while if not switch fn ~ ! @, which the parser takes as such
 * where a command starts *)
(* old: strings, matched in the parser as L.WORD ("if", false): a
 * misspelling was silently a command's name *)
type keyword = [ `For | `In | `While | `If | `Not | `Switch | `Fn | `Match | `Bang | `At ]

val keyword_of : string -> keyword option

val is_keyword : string -> bool

(* how the token is written, for error messages *)
val show : token -> string
