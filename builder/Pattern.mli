(* Patterns: a rule's target, and which names it matches.
 *
 * In mk every rule's target is a pattern, and one type covers the four
 * kinds, so that a simple rule is just a rule whose pattern is literal:
 *
 *     pattern       name           binding                     kind
 *     hello         hello          Exact                       literal
 *     %.5           hello.5        Stem "hello"                % : any string
 *     %.5           dir/hello.5    Stem "dir/hello"
 *     &.5           dir/hello.5    no match                    & : no '/', no '.'
 *     (.+)\.5  :R:  hello.5        Groups [|"hello.5"; "hello"|]   regexp: \0 .. \9
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
 * for Maintaining Computer Programs", 1979 (suffix rules); Andrew
 * Hume, "Mk: a Successor to Make" (USENIX, 1987), whose abstract
 * counts "pattern-matching metarules rather than suffix
 * transformation rules" among mk's advantages over make, and which
 * warns that the :R: kind is "significantly slower than %
 * metarules" -- here a regexp match per candidate name; principia's
 * match.c; regexp(6) for the syntax. *)

(* a metarule's target *)
type meta =
  | Percent of string * string   (* A%B: prefix and suffix *)
  | Amp of string * string       (* A&B: the same, the stem without / or . *)
  | Regexp of string * Re.re     (* :R:, the source kept for printing *)

type t = Literal of string | Meta of meta

(* how a rule matched a name: a literal's exactly, % and & by a stem,
 * a regexp by its groups *)
type binding = Exact | Stem of string | Groups of string array

(* [of_target ~regexp s]: Literal if [s] has no % or &, unless the rule
 * is :R:. Raises Invalid_argument on a bad regexp. *)
val of_target : regexp:bool -> string -> t

val is_meta : t -> bool

(* [matches m name]: how the metarule's target [m] matches [name], if
 * it does: Stem for % and &, Groups [|\0; \1; ...|] for a regexp (\0
 * the whole match, as $stem0). E.g. matches (Percent ("", ".5"))
 * "hello.5" = Some (Stem "hello"). *)
val matches : meta -> string -> binding option

(* [subst b s]: a prerequisite [s] with each % and & replaced by the
 * stem, or with \1..\9 replaced by the groups; unchanged for an exact
 * match. E.g. subst (Stem "hello") "%.c" = "hello.c". *)
val subst : binding -> string -> string
