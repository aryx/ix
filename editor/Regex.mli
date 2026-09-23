(* Regular expressions, in Plan 9's notation (regexp(7)), matched
 * leftmost-longest, with the submatches of the highest-priority way
 * among the longest -- libregexp's answers, by another algorithm.
 *
 *     c  \c  .  [a-z]  [^a-z]  ^  $     a character, quoted, any, a class,
 *                                       its complement, start, end
 *     e*  e+  e?  e1e2  e1|e2  (e)      repeats, concatenation, alternation,
 *                                       a group, which also captures
 *
 *     exec (compile "o|on") "one" 0            = Some [| (0, 2); ... |]
 *     exec (compile "(o|on)(e|ne)*") "one" 0   : \1 = (0, 1), \2 = (1, 3)
 *
 * {b The algorithm is libregexp's}, because its answers are the
 * specification, and they depend on how it works. It compiles the
 * pattern to a small program (regcomp.c: RUNE, ANY, CLASS, LBRA and
 * RBRA for the captures, OR, END), and runs it as a Thompson NFA with
 * captures -- the "Pike VM": a list of threads, each an instruction
 * with its own captures, advanced together a character at a time; of
 * two threads at the same instruction only the first is kept (or the
 * one that started earlier). The order of the list is not a priority:
 * an OR follows its left side at once and puts its right side at the
 * end of the list, and the left side of * + ? is the skip, of a|b the
 * b. With the dedup, that order shows in corner cases: ((x?)?)* on
 * xxb matches the empty string at 0 (checked on 9base), where a
 * priority-ordered matcher (a backtracker, RE2) matches xx.
 *
 * {b Lines and characters.} Positions are byte offsets; a step over a
 * character decodes UTF-8, so . takes an é whole. As in libregexp, .
 * and [^...] never match a newline, ^ matches after one and $ before
 * one: a line holds none, except while s is making several lines of
 * one (Command). *)

type t

(* a pattern that isn't one: "missing operand", "malformed []", ... *)
exception Error of string

(* [compile p]: p as ed passes it, a \ still before what it quotes *)
val compile : string -> t

(* [exec re s from]: the leftmost-longest match starting at [from] or
 * after (^ still only at 0 or after a newline): the whole match's span
 * then groups 1-8, (-1, -1) for a group that did not match *)
val exec : t -> string -> int -> (int * int) array option
