(* SQL text to a statement: chidb's chisql_parser.
 *
 * A ; is added if the text does not end with one. On a syntax error,
 * chidb's two lines on stderr:
 *
 *      syntax error (line 1)
 *      invalid sql: "SELEC x;"
 *
 * and None. Several statements in one text are parsed, the last one
 * kept, as chidb's parser overwrites its statement for each; a text
 * with only empty statements (";") is refused, where chidb crashes (a
 * deliberate difference, since chidb reads its uninitialized statement
 * type). *)

val parse : < Cap.stderr; .. > -> string -> Ast.t option

(* the last statement, without messages: for the schema's SQL *)
val parse_quiet : string -> Ast.stmt option
