{
(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The lexer: chidb's sql.l, in ocamllex. Keywords are
 * case-insensitive words, taken from the identifiers by a table (as
 * flex's case-insensitive keyword rules do, a keyword winning a tie);
 * the table is sql.l's, so CROSS, INTERSECT and EXCEPT, which sql.y
 * mentions but sql.l does not, are identifiers. A number with a sign
 * is one token (x -1 is x and -1). The line count is global, as flex's
 * yylineno: it goes on from one statement to the next, and so does
 * being inside a comment. *)
open Parser

let line = Ast.line

let keywords = Hashtbl.create 64
let () =
  List.iter (fun (k, t) -> Hashtbl.replace keywords k t)
    [ "explain", EXPLAIN; "create", CREATE; "table", TABLE; "index", INDEX; "insert", INSERT; "into", INTO;
      "select", SELECT; "from", FROM; "where", WHERE; "primary", PRIMARY; "foreign", FOREIGN; "key", KEY;
      "default", DEFAULT; "check", CHECK; "not", NOT; "null", NULL; "and", AND; "or", OR;
      "references", REFERENCES; "order", ORDER; "by", BY; "delete", DELETE; "as", AS; "byte", INT; "int", INT;
      "integer", INT; "double", DOUBLE; "char", CHAR; "varchar", VARCHAR; "text", TEXT; "join", JOIN;
      "inner", INNER; "outer", OUTER; "full", FULL; "left", LEFT; "right", RIGHT; "natural", NATURAL;
      "union", UNION; "values", VALUES; "auto_increment", AUTO_INCREMENT; "asc", ASC; "desc", DESC;
      "unique", UNIQUE; "in", IN; "count", COUNT; "sum", SUM; "min", MIN; "max", MAX; "avg", AVG; "on", ON;
      "using", USING; "true", TRUE; "false", FALSE; "case", CASE; "when", WHEN; "bit", BIT; "group", GROUP;
      "distinct", DISTINCT ]

(* C's atoi, 32 bits *)
let atoi s = Int32.to_int (Int32.of_int (int_of_string (if s.[0] = '+' then String.sub s 1 (String.length s - 1) else s)))

let newlines s = String.iter (fun c -> if c = '\n' then incr line) s

(* flex's start condition: inside a -- or a /* comment. Like the line
 * count it is global, and a new text does not reset it: after a line
 * "-- a comment" (the shell's lines have no newline), chidb goes on
 * reading the next statements as the comment's, until a newline *)
type state = Initial | Line_comment | Block_comment

let state = ref Initial

(* the comment's first line; flex's warning increments it (++) *)
let comment_start = ref 0
}

rule initial = parse
  | "/*" { comment_start := !line; state := Block_comment; comment lexbuf }
  | "--" { state := Line_comment; line_comment lexbuf }
  | "!=" | "<>" { NEQ }
  | ">=" { GEQ }
  | "<=" { LEQ }
  | "||" { CONCAT }
  | "|><|" { BOWTIE }
  | ['a'-'z' 'A'-'Z'] ['a'-'z' 'A'-'Z' '0'-'9' '_']* as id
      { match Hashtbl.find_opt keywords (String.lowercase_ascii id) with Some t -> t | None -> IDENTIFIER id }
  | '"' ([^ '"']* as s) '"' | '\'' ([^ '\'']* as s) '\'' { newlines s; STRING_LITERAL s }
  | ['+' '-']? ['0'-'9']+ as n { INT_LITERAL (atoi n) }
  | ['0'-'9']* '.' ['0'-'9']+ (['e' 'E'] ['-' '+']? ['0'-'9']+)? as d { DOUBLE_LITERAL (float_of_string d) }
  | [' ' '\t' '\r']+ { initial lexbuf }
  | '\n' { incr line; initial lexbuf }
  | ';' { SEMI } | ',' { COMMA } | '(' { LPAREN } | ')' { RPAREN } | '.' { DOT }
  | '*' { STAR } | '+' { PLUS } | '-' { MINUS } | '/' { SLASH }
  | '=' { EQ } | '<' { LT } | '>' { GT }
  | _ { OTHER }
  | eof { EOF }

and line_comment = parse
  | '\n' { incr line; state := Initial; initial lexbuf }
  | eof { EOF }
  | _ { line_comment lexbuf }

and comment = parse
  | "*/" { state := Initial; initial lexbuf }
  | '\n' { incr line; comment lexbuf }
  | eof { incr comment_start; Printf.eprintf "Warning: unclosed comment beginning on line %d\n%!" !comment_start; EOF }
  | _ { comment lexbuf }

{
(* the next token, in the state the last one left *)
let token lexbuf =
  match !state with Initial -> initial lexbuf | Line_comment -> line_comment lexbuf | Block_comment -> comment lexbuf
}
