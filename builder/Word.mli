(* Words: how mk turns the text of a line into a list of strings.
 *
 * Every value in mk is a list of words. A rule header, an assignment's
 * right-hand side and a variable's value are all lists, split on blanks
 * (space, tab, newline) outside quotes:
 *
 *     OBJS=hello.5 world.5          OBJS = ["hello.5"; "world.5"]
 *     hello: $OBJS                  prereqs = ["hello.5"; "world.5"]
 *
 * A word is a concatenation of pieces -- literal text, quoted text,
 * variable references -- and a variable's value is itself a list. Its
 * text is glued to its neighbours at the *ends*, not distributed (rc
 * would distribute, mk does not):
 *
 *     X=a b      $X.o      ->  ["a"; "b.o"]       (not ["a.o"; "b.o"])
 *                pre$X     ->  ["prea"; "b"]
 *                $X$X      ->  ["a"; "ba"; "b"]
 *
 * A variable that is undefined, or whose value is empty, vanishes:
 * x${NONE}y is "xy", and $NONE alone is no word at all.
 *
 * {b Substitution}, ${name:A%B=C%D}, rewrites each word of $name that
 * starts with A and ends with B, the middle being the stem:
 *
 *     SRC=Ast.ml Main.ml lexer.mll
 *     ${SRC:%.ml=%.cmo}    ->  ["Ast.cmo"; "Main.cmo"; "lexer.mll"]
 *                               (A="", B=".ml", C="", D=".cmo";
 *                                lexer.mll does not end in .ml: kept)
 *
 * Two quirks of the original are kept, because real mkfiles can
 * observe them: without a % on the right (${X:%.c=gone}) a matching
 * word becomes the right-hand side alone; and an undefined $name in a
 * substitution gives the word "name" itself (checked on 9base's mk:
 * ${UNDEF:%.c=%.o} asks to make "UNDEF").
 *
 * {b Quoting} depends on the shell, because mk quotes the way the shell
 * that will run its recipes does (mk(1), MKSHELL):
 *
 *     Rc    'it''s'           one word: it's      ('' is a quote)
 *     Sh    'a b' "a b" a\ b   one word each; a backslash escapes the
 *                               next character, and inside double
 *                               quotes only a quote, a backslash,
 *                               a dollar or a backquote
 *
 * Unicode costs nothing: every byte of a multibyte UTF-8 character is
 * 0x80 or above, so treating such bytes as word characters makes UTF-8
 * names work without decoding anything.
 *
 * Backquotes (`{cmd} and `cmd`) are not handled here: mk runs them
 * while it assembles a line, before the line is split (Mkfile).
 *
 * References: mk(1), "Environment" (Plan 9 and plan9port, the
 * substitution rule); Andrew Hume, "Mk: a Successor to Make", USENIX
 * 1987; Tom Duff, "Rc -- The Plan 9 Shell", 1990, for the quoting;
 * principia's varsub.c (nextword, subsub, submatch) for the exact
 * gluing rules. *)

type quoting = Rc | Sh

(* The quoting of a shell command line, e.g. ["/bin/rc"; "-I"]: rc's if
 * its first word ends in "rc" or "rcsh", sh's otherwise (mk(1)). *)
val quoting_of_shell : string list -> quoting

(* The characters that can be part of a variable name: everything above
 * a space except ASCII's punctuation (mk.h's WORDCHR). So $stem.c is
 * the variable stem followed by ".c", and $a-b is $a followed by "-b". *)
val is_wordchar : char -> bool

exception Error of string

(* Does this character open a quote (or, in sh, escape the next one)? *)
val opens_quote : quoting -> char -> bool

(* [find_unquoted q s ~from chars]: the index of the first character of
 * [chars] in [s] at or after [from], outside quotes and outside ${...}.
 * E.g. find_unquoted Rc "x='a:b' y:z" ~from:0 ":=" = Some 1, and in
 * "${SRC:%.ml=%.cmo}: foo" the first ':' found is the one at 17. *)
val find_unquoted : quoting -> string -> from:int -> string -> int option

(* [split q ~lookup s]: the words of [s], variables expanded through
 * [lookup] (None: undefined). Quotes are removed. No word is ever the
 * empty string. E.g., with X = ["a"; "b"], split Rc "$X.o 'c d'" is
 * ["a"; "b.o"; "c d"]. Raises Error on a malformed reference. *)
val split : quoting -> lookup:(string -> string list option) -> string -> string list
