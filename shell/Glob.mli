(* Globbing: *, ? and [...] against file names, and against strings for
 * ~ and switch.
 *
 * A word keeps, as it is expanded, which of its characters were quoted
 * (Word): only the unquoted * ? [ are pattern characters, so '*'.c and
 * $x.c with x='*' are literal, and *.c is a pattern. rc marks the
 * unquoted ones with a special byte as it lexes (principia's lex.c,
 * GLOB); here a word is a list of pieces, each quoted or not.
 *
 *     in a directory with a.c b.c .hidden (checked on 9base's rc):
 *     *.c        a.c b.c
 *     *          .hidden a.c b.c       * matches a leading . too
 *     nomatch*   nomatch*              no match: the word itself
 *     */*.c      d1/x.c d2/y.c         one directory level per /
 *
 * [abc] [a-z] match one character of the set, [~a-z] one not in it.
 * The matches of one word are sorted. In ~ and switch, the same
 * patterns match strings, where * matches / too.
 *
 * References: principia's glob.c (glob, match); rc(1), "Patterns";
 * Tom Duff, "Rc -- The Plan 9 Shell" (1990), "Patterns": only / and
 * the components . and .. must be written explicitly, where Bourne's
 * "An Introduction to the UNIX Shell" makes any "." at the start of a
 * name one; Russ Cox, "Glob Matching Can Be Simple And Fast Too"
 * (2017), the road not taken: a * that tries every suffix by
 * recursion, as here and in rc, is exponential on a*a*a*b against
 * many a's, and going back only to the last * is enough. *)

type piece = { text : string; literal : bool }

(* an expanded word *)
type word = piece list

val to_string : word -> string

(* does it have an unquoted pattern character? *)
val is_pattern : word -> bool

(* [matches pat s]: does [s] match [pat], * matching / too (for ~ and
 * switch)? *)
val matches : word -> string -> bool

(* [files ~readdir ~exists w]: the file names [w] matches, sorted, or
 * [w] itself if it matches none or is no pattern; [readdir dir] lists
 * a directory ("" is the current one), None if it can't be read *)
val files :
  readdir:(string -> string list option) -> exists:(string -> bool) -> word -> string list
