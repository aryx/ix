(* mini-ed's command line, ed's: ed [-] [-o] [file]
 *
 *     -       quiet: no counts, no ! after a shell command, and q and e
 *             quit or edit even with changes not written
 *     -o      a filter: the remembered file is standard output, all the
 *             rest goes to standard error, and ed starts in input mode
 *             (ed -o < text, then commands after the ".")
 *     file    read into the buffer, and remembered, as e file would
 *
 * An interrupt prints ? and goes back to the commands; a hangup writes
 * the buffer to ed.hup and quits. The exit status is 0, as ed.c's. *)

type caps = < Command.caps; Cap.argv; Cap.exit >

val main : < caps; .. > -> string array -> int
