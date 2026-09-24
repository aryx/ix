(* The tokens of Plan 9's assembly: names (with their dots: MOVW.P,
 * .string, are one token), numbers (0x, octal, 'c', and floats),
 * strings with C escapes, the punctuation, and Eol for a newline or a
 * semicolon. Comments are // and /* */. *)

type token =
  | Ident of string
  | Int of int64
  | Float of float
  | String of string
  | Punct of string
  | Eol

exception Error of int * string

(* [preprocess dir text]: #include "file" (from dir) and #define NAME
 * text, the only directives the inputs use *)
val preprocess : < Cap.open_in; .. > -> Fpath.t -> string -> string

val tokens : string -> (token * int) list
