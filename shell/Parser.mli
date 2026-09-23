(* The parser: tokens to commands, by recursive descent (the grammar of
 * principia's syn.y, whose precedences it follows).
 *
 * rc's grammar is small because a condition is a command in
 * parentheses and a body is one command (often a brace):
 *
 *     line     cmd ; cmd & cmd ...                 up to a newline
 *     cmd      bang && bang || ...                 lowest: && ||
 *     bang     ! bang   @ bang   >f bang   x=v bang   pipe
 *     pipe     unit | unit |[2] unit ...
 *     unit     if(line) cmd   if not cmd   while(line) cmd
 *              for(x in words) cmd   for(x) cmd   switch word {...}
 *              fn names {...}   fn names   ~ word words   {line} >f
 *              simple: words and redirections, in any order
 *     word     comword ^ comword ...
 *     comword  WORD  $comword  $#comword  JOIN comword  $comword(words)
 *              (words)  `{line}  `sep{line}  <{line}  >{line}
 *
 * So `if(c) a && b` is if(c){a && b}, `! a | b` is !(a | b), `x=1 a | b`
 * runs the whole pipe with x set, and `a && b | c` is a && (b | c) --
 * what yacc makes of syn.y's precedences. A newline after if(...),
 * while(...), for(...), switch word or if not is skipped, as syn.y's
 * skipnl() does. Keywords are keywords only where a command starts:
 * echo if prints if.
 *
 * Why not menhir, as the plan said: syn.y's grammar leans on yacc's
 * tricks -- prefix redirections and assignments given %prec BANG, a
 * skipnl() inside rules, keywords turned back into words -- which a
 * recursive descent writes plainly, and menhir only with the same
 * tricks. (The plan's decision 2, and its Status.) *)

exception Error of string   (* e.g. token 'x': syntax error *)

(* the next command line, or None at the end of the input. Raises
 * Error, or Lexer.Error. *)
val line : Lexer.t -> Ast.cmd option

(* all the commands of a string, e.g. a function body from the
 * environment *)
val parse_string : string -> Ast.cmd
