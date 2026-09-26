(* mini-ml [-dast] [-dscope] [-I dir] file.ml|file.mli
 * For now (phase 2 of plan_ml.md), the front end: -dast prints the
 * tree the parser makes, -dscope the names Scope resolved; an error
 * on stderr, and the exit status 1. *)

type caps = < Cap.open_in; Cap.stdout; Cap.stderr >

val main : < caps; .. > -> string array -> int
