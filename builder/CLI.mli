(* The command line: mk [-f file] [-aeiknstuH] [-d[egp]] [-w file] [var=value ...] [target ...]
 *
 *     -f file   read file instead of mkfile
 *     -n        print the recipes, run nothing (targets count as made now)
 *     -t        touch the targets instead of running recipes
 *     -a        everything is out of date
 *     -e        explain why each recipe runs
 *     -k        keep going after a failure, with what doesn't depend on it
 *     -s        make the targets one after the other, not as one virtual
 *               rule "command line arguments"
 *     -w file   pretend file was just modified (several: -w a,b or -w 'a b')
 *     -i        make missing intermediates: always the case here (see
 *               Build, and the plan's decision 5)
 *     -u        print how long 0, 1, 2 ... jobs ran at once
 *     -d[egp]   dump: e the jobs, g the graph, p the variables and rules
 *     -H        out of date by content, not time: each target's trace
 *               (a digest of its recipe and its prerequisites' contents)
 *               is kept in .mkhash (not in mk; see Outofdate)
 *     var=value an assignment that blocks every assignment to var in the
 *               mkfile (see Mkfile)
 *
 * With no target, the targets of the first rule without % or & are
 * made. $MKFLAGS is set to the options and assignments, $MKARGS to the
 * targets; $NPROC (default 1) is how many recipes run at once, $NREP
 * (default 1) how often a metarule may repeat on a path (Graph).
 *
 * References: mk(1); principia's main.c. *)

type caps = < Recipe.caps; Cap.env; Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr >

(* [main caps argv]: the exit status: 0, or 1 after an error *)
val main : < caps; .. > -> string array -> int
