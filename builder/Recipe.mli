(* Running a recipe: the job, its environment, how it is printed, and
 * the process that runs it.
 *
 * A job is one recipe to run: the rule it comes from, and the names it
 * is run with. For hello.5 from %.5: %.c, the recipe sees:
 *
 *     target=hello.5      the targets being made (a rule a b: c makes
 *                         both at once, if both are out of date)
 *     prereq=hello.c      all the prerequisites     newprereq=  the
 *     stem=hello          ones newer than a target  alltarget=  every
 *     stem0..stem9        (:R:) the groups          target of the rule
 *     nproc=0             the slot running it      pid=  mk's own pid
 *
 * plus every variable of the mkfile and of mk's environment, except
 * those assigned with X=U=... A list is exported with its words
 * separated by a space for sh, and by \001 for rc, which splits it
 * back into a list (9base: $#X is 2 for X=a b under rc). An empty list
 * is not exported to rc at all: on Plan 9 it is an empty /env file,
 * which rc reads as (), but a Unix rc reads X= as ('') -- one empty
 * word, and ocamlc $SYSLIBS then fails on an empty argument. omk does
 * the same; 9base's mk does not, and xix's build needs it.
 *
 * {b The whole recipe goes to one shell}, on its standard input, with
 * -e (unless :E:), so the first failing command stops it and a cd
 * lasts until the end -- unlike make's one shell per line:
 *
 *     install:V:
 *         cd sub
 *         cp prog /bin       mk copies sub/prog; make would copy ./prog
 *
 * {b Printing.} Before it runs, a recipe is printed (unless :Q:, and
 * always under -n) with the variables mk set expanded -- those of the
 * mkfile, of the command line, and the job's own -- and the rest left
 * for the shell: $HOME stays $HOME, and so does anything quoted
 * ('$X', "$target", `cmd`). mk(1)'s bugs section says not to trust it;
 * it is what 9base prints, and what the differential tests compare.
 *
 * References: mk(1), "Execution" and "Environment"; principia's run.c,
 * env.c (buildenv), shprint.c and Posix.c (execsh, exportenv); Andrew
 * Hume and Bob Flandrena, "Maintaining Files on Plan 9 with Mk", for
 * the one shell: "Make evaluates recipes one line at a time ... Mk
 * passes the entire recipe to the shell without interpretation". *)

type job = {
  rule : Mkfile.rule;         (* the master rule, whose recipe runs *)
  stems : Pattern.binding;
  targets : string list;      (* $target *)
  alltargets : string list;   (* $alltarget *)
  prereqs : string list;      (* $prereq *)
  newprereqs : string list;   (* $newprereq *)
  nodes : Graph.node list;    (* made by this job *)
}

(* the environment of [job] run in slot [slot]: the exported variables
 * and the job's own (buildenv); no job, for backquotes: those empty *)
val env : Mkfile.t -> ?job:job -> slot:int -> pid:int -> unit -> (string * string list) list

(* as "name=value" strings, lists joined the way [shell] wants *)
val environment : shell:string list -> (string * string list) list -> string array

(* [shprint mk env recipe]: the recipe as mk prints it (see above) *)
val shprint : Mkfile.t -> (string * string list) list -> quoting:Word.quoting -> string -> string

(* shprint.c's front(): a printed recipe cut down to its first three
 * and last fields, for error messages *)
val front : string -> string

(* {2 Processes} *)

type caps = < Cap.fork; Cap.exec; Cap.wait >

(* [start caps ~shell ~env ~args script]: fork the shell with [args]
 * (e.g. ["-e"]) and [script] on its standard input; returns its pid *)
val start : < caps; .. > -> shell:string list -> env:string array -> args:string list -> string -> int

(* [wait caps]: a child that ended, and "" or why it failed
 * ("exit(1)", "signal 9") *)
val wait : < caps; .. > -> int * string

(* [output caps ~shell ~env ~stdin cmd]: run [cmd] (on the standard input
 * or with -c), wait for it, and return what it printed and whether it
 * succeeded: for backquotes, <| and :P: *)
val output : < caps; .. > -> shell:string list -> env:string array -> stdin:bool -> string -> string * bool
