(* The build: which recipes to run, in what order, several at a time.
 *
 * mk's loop, re-walked from the target after every change:
 *
 *   loop:
 *     walk the graph from the target (work): a node whose prerequisites
 *       are all made and which is out of date gets a job, queued
 *       (dorecipe); a job starts as soon as one of the $NPROC slots is
 *       free
 *     if the walk queued nothing, wait for a running job to end, re-stat
 *       its targets (Outofdate.after_recipe), and mark them made
 *   until the target is made
 *
 * With NPROC=2, hello.mk from scratch:
 *
 *   time ->
 *   slot 0:  [ 5c -c hello.c ]            [ 5l -o hello hello.5 world.5 ]
 *   slot 1:  [ 5c -c world.c ]
 *                            ^ both .5 made: hello becomes ready
 *
 * The walk is a function of the graph and of two tables, the only
 * mutable state of a build: each node's date stamp, and how far it has
 * got (not made, being made, made). mk and omk keep both inside the
 * nodes; here the graph stays as Graph built it. What "start a job"
 * means is where the modes live: -n prints the recipe and marks its
 * targets made as of now, -t touches them, and otherwise the shell is
 * forked. The re-walk costs a walk of the graph per job, as in mk.
 *
 * {b Why not plan everything first and then run it?} Because a recipe
 * may leave its target untouched, and then what depends on it is up to
 * date after all (Outofdate: early cutoff). What must run next depends
 * on what the last recipe actually did, so the question is asked again
 * after every job.
 *
 * The order is mk's: jobs queue in the order the walk finds them
 * (depth first, prerequisites in the graph's order) and start in that
 * order. Under NPROC=1 that is exactly what 9base's mk -n prints, and
 * the differential tests check it.
 *
 * This is the scheduler of "Build Systems a la Carte" (Mokhov,
 * Mitchell, Peyton Jones, 2018): a topological one, with Outofdate as
 * its rebuilder.
 *
 * References: principia's mk.c (mk, work), recipe.c (dorecipe) and
 * run.c (run, sched, waitup, usage). *)

type flags = {
  dry : bool;          (* -n *)
  touch : bool;        (* -t *)
  always : bool;       (* -a *)
  keep_going : bool;   (* -k *)
  explain : bool;      (* -e *)
}

(* What a build does to the world; CLI gives the real one, tests a fake. *)
type io = {
  run : Recipe.job -> slot:int -> env:(string * string list) list -> int;  (* a pid *)
  wait : unit -> (int * string) option;   (* None: no child left *)
  stat : string -> float;                 (* 0: missing *)
  exists : string -> bool;
  touch : string -> unit;
  delete : string -> unit;
  prog : string -> string -> string -> bool;   (* :P: *)
  now : unit -> float;
  print : string -> unit;
  eprint : string -> unit;
  cwd : string;
  pid : int;
}

type t

(* mk's Exit(): a recipe failed, or nothing knows how to make a target *)
exception Failed

(* with [hashes], out of date is decided by -H's traces (Outofdate) *)
val create : ?hashes:Outofdate.hashes -> Mkfile.t -> Graph.t -> io -> flags -> t

(* [make t ~nproc ~nrep target]: bring [target] up to date, printing
 * "mk: 'target' is up to date" if nothing had to be done. Raises
 * Failed (after the message) unless -k. *)
val make : t -> nproc:int -> nrep:int -> string -> unit

(* wait for the jobs still running, e.g. after Failed *)
val wait_all : t -> unit

(* how many recipes failed under -k *)
val errors : t -> int

(* -u: seconds spent with 0, 1, 2 ... jobs running *)
val usage : t -> string
