(* Patterns: a rule's target, and which names it matches.
 *
 * In mk every rule's target is a pattern, and one type covers the four
 * kinds, so that a simple rule is just a rule whose pattern is literal:
 *
 *     pattern       name           stems                 kind
 *     hello         hello          [||]                  literal
 *     %.5           hello.5        [|"hello"|]           % : any string
 *     %.5           dir/hello.5    [|"dir/hello"|]
 *     &.5           dir/hello.5    no match              & : no '/', no '.'
 *     (.+)\.5  :R:  hello.5        [|"hello.5"; "hello"|]   regexp: \0 .. \9
 *
 * The prerequisites are then the rule's prerequisite patterns with the
 * stem put back ([subst]): %.5: %.c matched on hello.5 wants hello.c,
 * and (.+)\.5: \1.c the same. A pattern has at most one % or & (the
 * first is the pattern character; any later one is literal), as in
 * principia's match.c.
 *
 * % generalizes make's suffix rules (.c.o:, Feldman 1976), which could
 * only say "a file with this extension comes from the file with that
 * one"; mk's % goes anywhere: lib%.a, %/mkfile, test-%:V:.
 *
 * The regexps are Plan 9's (egrep's syntax: ( ) | * + ? [ ] . ^ $),
 * read by the re library's POSIX parser and matched against the whole
 * name. They are byte-level: '.' matches a byte, not a UTF-8
 * character.
 *
 * References: mk(1), "Meta-rules"; Stuart Feldman, "Make -- A Program
 * for Maintaining Computer Programs", 1979 (suffix rules); principia's
 * match.c; regexp(6) for the syntax. *)

type t =
  | Literal of string
  | Percent of string * string   (* A%B: prefix and suffix *)
  | Amp of string * string       (* A&B: the same, the stem without / or . *)
  | Regexp of string * Re.re     (* :R:, the source kept for printing *)

(* [of_target ~regexp s]: Literal if [s] has no % or &, unless the rule
 * is :R:. Raises Invalid_argument on a bad regexp. *)
val of_target : regexp:bool -> string -> t

val is_meta : t -> bool

(* [matches p name]: None, or the stems: [||] for a literal pattern,
 * [|stem|] for % and &, [|\0; \1; ...|] for a regexp (\0 the whole
 * match, as $stem0). E.g. matches (of_target ~regexp:false "%.5")
 * "hello.5" = Some [|"hello"|]. *)
val matches : t -> string -> string array option

(* [subst p stems s]: [s] with each % and & replaced by the stem (for
 * a % or & pattern), or with \1..\9 replaced by the groups (for :R:); a
 * literal rule's prerequisites are returned unchanged. E.g. subst %
 * [|"hello"|] "%.c" = "hello.c". *)
val subst : t -> string array -> string -> string

(* The stem as $stem sees it: stems.(0) for % and &, "" otherwise. *)
val stem : t -> string array -> string
