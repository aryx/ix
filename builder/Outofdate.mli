(* Out of date, or not: the date stamps, and the decision.
 *
 * A target must be remade if it is not newer than one of its
 * prerequisites. The date stamp of a node (mk(1), principia's mk.c
 * update()) is:
 *
 *     a file that exists       its modification time
 *     a file that doesn't      0 before it is made; after its recipe,
 *                                re-stat it, and if still missing, the
 *                                newest of its prerequisites' stamps
 *     a virtual target (:V:)   0 before; after, the newest of its
 *                                prerequisites' stamps (at least 1)
 *
 * and the test is [target <= prereq]: equal times count as out of date
 * ("It's a race, and the safer option is to do extra building", mk.c).
 * On foo.o: foo.c (checked on 9base's mk and omk, 2026-09-23):
 *
 *     foo.c        foo.o          9base mk     omk          TinyMk
 *     10:00:00     10:00:00       rebuilds     up to date   rebuilds
 *     10:00:00.2   10:00:00.7     rebuilds     up to date   up to date
 *     10:00:00.7   10:00:00.2     rebuilds     rebuilds     rebuilds
 *
 * 9base has whole seconds, so it can't tell the second row from the
 * first; omk has sub-second times but compares with <. TinyMk takes
 * sub-second times and mk's <=.
 *
 * {b Re-stat after the recipe.} A recipe that leaves its target alone
 * (cmp -s new old || mv new old) keeps its old time, so what depends on
 * it is not rebuilt: early cutoff, which Bazel and Shake get from
 * content hashes, here obtained from mtimes because [after_recipe]
 * looks again rather than assuming.
 *
 * {b :P:cmd:} replaces the comparison: "cmd target prereq" is run by
 * the shell, and a non-zero exit status means out of date. Its answer
 * is remembered, and asked again only after the target's recipe.
 *
 * This is the rebuilder of Mokhov, Mitchell and Peyton Jones's "Build
 * Systems a la Carte" (2018): a modification-time rebuilder; Graph
 * gives it the dependencies and Build is the scheduler around it.
 *
 * References: mk(1), "Execution"; principia's mk.c (outofdate, update)
 * and file.c (timeof). *)

type ctx

(* [create ~time ~prog]: [time name] is the current date stamp of a
 * node, [prog cmd target prereq] runs a :P: command and says whether
 * it succeeded *)
val create : time:(string -> float) -> prog:(string -> string -> string -> bool) -> ctx

(* Is [node] out of date with respect to the prerequisite of [arc]?
 * [~eval:true] asks a :P: command again instead of remembering. *)
val arc : ?eval:bool -> ctx -> Graph.node -> Graph.arc -> Graph.node -> bool

(* [after_recipe ctx ~exists ~stat node]: the node's date stamp once its
 * recipe has run (the table above) *)
val after_recipe :
  ctx -> exists:(string -> bool) -> stat:(string -> float) -> Graph.node -> float
