(* The evaluator: rc's syntax tree, walked.
 *
 * rc compiles each command to instructions for a small machine and
 * runs them on a queue of threads, one per nested . or function call
 * (principia's code.c and exec.c: a third of the C). Here the tree is
 * walked by recursion instead, and the two things the machine gave rc
 * come for free: . reads one command at a time and runs it (the
 * parser is asked for the next line), and after fork the child
 * evaluates the subtree it was forked for and exits with its status.
 *
 *     Simple      expand, glob; a function, a builtin, or a program
 *     Pipe a|b    fork a with its fd 1 to a pipe; run b here, fd 0 from
 *                 it (so echo | x=2 sets x, as in rc); wait for a;
 *                 $status = a's|b's
 *     If c b      run c; if true, b -- and remember, for if not
 *     x=v cmd     v for cmd only, then put back (dynamic, as $* is)
 *     @ c, `{c}   in a child; c & too, its stdin /dev/null, $apid its pid
 *     >f cmd      done in the shell around cmd, and undone (Process)
 *
 * {b Errors.} A runtime error ("mismatched list lengths ...", "> requires
 * singleton") stops everything up to the nearest interactive input: a
 * script ends, the terminal gets its prompt back. A syntax error ends
 * the input it is in (a . file, a script). With -e, a command that
 * fails ends rc -- except in a condition (if, while, &&, ||, !), as in
 * code.c, which compiles those without the check.
 *
 * References: principia's code.c (outcode: what each construct
 * means), exec.c, simple.c, processes.c. *)

type caps = < Process.caps; Cap.chdir; Cap.env >

type t

(* rc ends, with this status *)
exception Exit of string

(* a runtime error: rc (argv0): message; an empty one was printed
 * already, in its own words *)
exception Error of string

val create : < caps; .. > -> argv0:string -> Env.t -> t

val env : t -> Env.t
val caps : t -> caps
val argv0 : t -> string

val run : t -> Ast.cmd -> unit

(* [source t ~name ~interactive lx]: read and run commands until the
 * end of [lx] (what . and eval and rc itself do) *)
val source : t -> name:string option -> interactive:bool -> Lexer.t -> unit

(* the expanded, globbed words of a list *)
val words : t -> Ast.word list -> string list

(* set by the SIGINT handler; acted on before the next command *)
val interrupted : bool ref

(* the builtins, filled by Builtin *)
val builtins : (string, t -> string list -> unit) Hashtbl.t

(* the children started with &, for wait *)
val background : t -> int list
val forget : t -> int -> unit

(* print a line on standard output or error *)
val print : string -> unit
val eprint : string -> unit
