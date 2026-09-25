(* mini-git CMD args: git9's programs and scripts, git/CMD on Plan 9, as
 * subcommands of one executable. A command's fatal error prints
 * "git/CMD: message" (git9's sysfatal, with argv0) and exits 1. *)

type caps = < Store.caps; Cap.stdout; Cap.stderr; Cap.argv; Cap.fork; Cap.exec; Cap.wait >

val main : < caps; .. > -> int
