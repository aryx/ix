(* Words to lists of strings: rc's only value is a list.
 *
 *     x=(a b c)
 *     $x        a b c          three words, never re-split
 *     $#x       3
 *     $"x"      'a b c'        ($ and a double quote, then x) one word, joined
 *     $x(2)     b              $x(2 3) b c, $x(2-) b c, $x(9) nothing
 *     $3        $*(3)          and $#3 is 1 or 0
 *     $$y       the variable whose name is $y's value
 *
 * {b Concatenation distributes} (principia's exec.c, Xconc):
 *
 *     a^(b c)          ab ac        one with each
 *     (a b)^(c d)      ac bd        pairwise
 *     (a b)^(c d e)    error: mismatched list lengths in concatenation
 *     ()^a             error: null list in concatenation
 *     ()^()            ()
 *     $x.o             a.o b.o c.o  the lexer's free caret, $x^.o
 *
 * which is not mk's rule (mk glues .o to the last word only: a b.o).
 *
 * `{cmd} is cmd's output split on the characters of $ifs, `sep{cmd} on
 * those of sep. A variable's value, a count, a backquote's output are
 * literal -- never globbed again: x='*'; echo $x prints *. Only the
 * characters written unquoted in the source are pattern characters
 * (Glob). A name is itself a word, expanded, which must be one word:
 * "variable name not singleton!".
 *
 * References: rc(1), "Variables", "Concatenation"; principia's
 * exec.c (Xdol, Xcount, Xqdol, Xsub, subwords, Xconc) and processes.c
 * (Xbackq). *)

exception Error of string

(* what expansion needs from the shell *)
type ctx = {
  var : string -> string list;              (* [] if unset *)
  backquote : string -> Ast.cmd -> string;  (* run it, its output *)
  pipefd : bool -> Ast.cmd -> string;       (* <{cmd}: a /dev/fd name *)
}

(* the words a word expands to, each still knowing its quoting *)
val expand : ctx -> Ast.word -> Glob.word list

(* [split seps s]: s cut at any of the characters of [seps] *)
val split : string -> string -> string list

(* the one string a word must expand to, e.g. a variable's name *)
val singleton : ctx -> Ast.word -> string
