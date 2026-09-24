(* The graph: from a target to everything it depends on.
 *
 * For one target, which rules apply, and recursively for their
 * prerequisites. hello.mk (principia's own mk test), from hello:
 *
 *                 hello                 rule "hello: $OBJS"
 *                /     \
 *          hello.5     world.5          rule "%.5: %.c", stems hello, world
 *             |           |
 *          hello.c     world.c          no rule: they must exist as files
 *
 * A node is a name; an arc goes from a node to one prerequisite through
 * the rule that asked for it (an arc with no prerequisite is a rule
 * with none: its recipe still counts). The lookup follows mk's policy
 * (principia's graph.c):
 *
 * 1. The rules whose target is the name itself apply first, all of
 *    them, in Mkfile's order; then every metarule that matches, in the
 *    order of the file. A rule with neither prerequisites nor recipe is
 *    ignored.
 * 2. NREP: one rule is used at most $NREP times (default 1) on the way
 *    down from the target. Without that, %: %.gz would ask for foo.gz,
 *    then foo.gz.gz, forever.
 * 3. A node is {e vacuous} if it doesn't exist, no rule of its own
 *    names it, and all its arcs were dropped; an arc from a metarule to
 *    a vacuous node is dropped -- unless another arc of the same rule
 *    stays, then they all stay. With %.5: %.c and %.5: %.s and only
 *    hello.c on disk, hello.5 is made from the .c.
 * 4. Two arcs with different recipes are ambiguous -- mk's "ambiguous
 *    recipes" error -- except that a rule naming the target beats a
 *    metarule, whose arcs are then dropped.
 * 5. A cycle (a: b, b: a) is an error, reported at the node where it
 *    closes, as graph.c's cyclechk() does: "cycle in graph detected at
 *    target a".
 *
 * Unlike mk's and omk's, these nodes never change once built: they
 * say what the graph is, and Build keeps how far the build has got in
 * tables of its own. A node is built once, the first time it is
 * reached, and shared by everything that needs it; so the arcs are
 * computed bottom-up, and a node can be pruned as soon as its
 * prerequisites are known. The one check that must wait is ambiguity:
 * a node reached only through an arc that is later dropped is never
 * checked (as in graph.c, where vacuous() runs before ambiguous()).
 *
 * References: principia's graph.c (applyrules, vacuous, ambiguous,
 * cyclechk, attribute); mk(1) for NREP; Stuart Feldman, "Make -- A
 * Program for Maintaining Computer Programs" (Software: Practice and
 * Experience, 1979), the first build tool, whose abstract already
 * says all of this module: "The description file really defines the
 * graph of dependencies; Make does a depth-first search of this
 * graph"; Andrew Hume, "Mk: a Successor to Make" (USENIX, 1987), for
 * rule 4, "Any non-metarule takes precedence over a metarule"; R. E.
 * Tarjan, "Depth-first search and linear graph algorithms" (SIAM
 * Journal on Computing, 1972): a cycle is an edge back to a node still
 * on the current path, and a node finished once is never walked again
 * -- here the path and the table of built nodes, where graph.c's
 * cyclechk clears its mark on the way out and so walks a shared
 * subgraph once per path to it. *)

type node = {
  name : string;
  arcs : arc list;
  virtual_ : bool;    (* some arc's rule is :V: *)
  delete : bool;      (* :D: *)
  norecipe : bool;    (* :N: *)
  time : float;       (* when the graph was built: 0 if missing or virtual *)
}

and arc = {
  prereq : node option;
  rule : Mkfile.rule;
  stems : Pattern.binding;   (* how the rule matched, for the recipe's $stem *)
}

exception Error of string

(* The nodes built so far, shared between the targets of one run of
 * mk, as mk shares them; [stat] gives a file's time, 0 if missing. *)
type t

val create : Mkfile.t -> stat:(string -> float) -> t

(* [node g ~nrep target]: the graph from [target]. Raises Error on a
 * cycle or on ambiguous recipes. *)
val node : t -> nrep:int -> string -> node

(* the node already built under this name, if any *)
val find : t -> string -> node option

(* a node and what it depends on, indented, for -d g *)
val dump : node -> string
