(* tinydb [-c COMMAND] [-v] [-h] [DATABASE]: chidb's command line.
 *
 * With -c, the one command, and done; otherwise the prompt chidb> and
 * a line at a time until the end of the input, the prompt printed even
 * when the input is not a terminal (chidb's, kept, since it is its
 * output). -v, repeated, raises the level of the traces (Logs). *)

val main : < Shell.caps; Cap.argv; .. > -> int
