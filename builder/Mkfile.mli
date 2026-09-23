(* Reading a mkfile: one pass, evaluated as read, no syntax tree.
 *
 * A mkfile is a sequence of lines, and each is handled as soon as it is
 * read:
 *
 *     backslash-newline    deleted (long lines may be folded)
 *     # to end of line     deleted, unless quoted
 *     `{cmd}  `cmd`        run now; its output replaces it in the line
 *     <file                the file is read here (a missing one: a warning)
 *     <|cmd args           the command's output is read here
 *     a tab or a space     in column 0: a recipe line of the rule above,
 *                          kept raw -- the shell reads it, not mk
 *     anything else        an assignment or a rule, by whichever of = and
 *                          : comes first unquoted (a < first: an include)
 *
 * Rules and assignments carry attributes between colons or equal signs:
 *
 *     clean:V:             V virtual, Q quiet, D delete on error,
 *     %.5:Q: %.c           E continue on error, N no recipe needed,
 *     (.+)\.5:R: \1.c      n not after a virtual rule, R regexp,
 *     t:Pcmp -s: a b       Pcmd: cmd decides if t is out of date
 *     X=U=value            U: not exported to recipes
 *
 * {b Evaluated as read.} A variable in a rule header takes the value it
 * has at that line; recipes are expanded later, by the shell, with the
 * final values in its environment (checked on 9base's mk):
 *
 *     Y=early
 *     late:V: $Y        <- late depends on "early"
 *     Y=changed         <- but its recipe sees $Y = changed
 *
 * That is why there is no AST here: mk's semantics consume each line as
 * it comes, so a tree would only be a stopover. (xix's omk parses into
 * one with ocamllex and ocamlyacc, then evaluates it: the same result
 * in two passes.)
 *
 * {b Where a variable's value comes from}, weakest first: mk's
 * environment, the mkfile, the command line. A command-line X=v blocks
 * *every* assignment to X in the mkfiles. mk(1) says "the first (but
 * not any subsequent)", but 9base's mk, principia's (parse.c's
 * S_OVERRIDE) and omk all block every one, and the program is the
 * specification.
 *
 * {b Several rules for one target} are kept in mk's order, which is
 * not the order of the file: the first, then the others newest first
 * (rule.c chains each new rule right after the first). With a: b,
 * a: c, a: d the prerequisites are b d c (checked on 9base). A rule
 * with the same target and prerequisites as an earlier one replaces it.
 *
 * {b MKSHELL} is read when the mkfile is: a rule remembers the shell of
 * the line it was read at, so one mkfile can use both rc and sh, and an
 * included file starts again from the default (mk(1)). The default is
 * $MKSHELL from the environment if set -- principia's mk honours it,
 * which xix's build relies on (env.sh) -- and sh otherwise.
 *
 * References: mk(1), "The mkfile"; principia's parse.c (parse, rhead,
 * rbody), lex.c (assline, bquote) and rule.c (addrule); Bob Flandrena,
 * "Plan 9 Mkfiles", 1995, for how real mkfiles include prototypes. *)

type attrs = {
  virtual_ : bool;       (* V *)
  quiet : bool;          (* Q *)
  delete : bool;         (* D *)
  noerror : bool;        (* E: run the recipe without -e *)
  norecipe : bool;       (* N *)
  novirtual : bool;      (* n *)
  regexp : bool;         (* R *)
  prog : string option;  (* Pcmd *)
}

type rule = {
  target : string;
  pattern : Pattern.t;
  alltargets : string list;   (* every target of its line *)
  prereqs : string list;
  recipe : string;            (* "" when none; each line ends with \n *)
  attrs : attrs;
  id : int;                   (* the line it came from: two arcs with the
                               * same id carry the same recipe *)
  shell : string list;        (* MKSHELL when the line was read *)
  file : string;
  line : int;
}

type t

exception Error of string   (* "file:line: message" *)

(* How reading reaches the outside world: to read a file (None: it
 * doesn't exist), and to run a shell command and get its output
 * ([~stdin:true] feeds [script] on its standard input, as backquotes
 * do; false runs it with -c, as <| does), with the environment the
 * recipes would get; and to print a warning. Tests pass fakes. *)
type io = {
  read_file : string -> string option;
  output : t -> shell:string list -> stdin:bool -> string -> string * bool;
  warn : string -> unit;
}

(* [create ~env ~default_shell]: no rules; the variables of [env] (mk
 * imports its environment, each value one word). *)
val create : env:(string * string) list -> default_shell:string list -> t

(* [read io t ~file text]: read [text] as the mkfile [file]. With
 * [~override:true] its assignments block later ones: that is how the
 * command line's X=v are read. Raises Error. *)
val read : ?override:bool -> io -> t -> file:string -> string -> unit

(* {2 What reading produced} *)

val lookup : t -> string -> string list option
val set : t -> string -> string list -> unit
(* set by the mkfile or the command line, not only inherited from the
 * environment: those are the ones a recipe is printed with expanded *)
val set_here : t -> string -> bool
val exported : t -> (string * string list) list   (* not U, sorted *)

(* the rules whose target is exactly [name], in mk's order (see above) *)
val rules_for : t -> string -> rule list
(* every rule whose target is a pattern, in the order of the file *)
val metarules : t -> rule list
(* the targets of the first rule without % or &: what "mk" alone makes *)
val default_targets : t -> string list

(* the shell a file starts with (see MKSHELL above) *)
val default_shell : t -> string list
val set_default_shell : t -> string list -> unit

(* [add_rule t ~targets ~prereqs ~recipe attrs]: a rule not read from a
 * file, e.g. the virtual "<command line arguments>" mk makes when given
 * several targets. *)
val add_rule :
  t -> targets:string list -> prereqs:string list -> recipe:string -> attrs -> unit

val no_attrs : attrs

(* the variables and rules, for -d p *)
val dump : t -> string
