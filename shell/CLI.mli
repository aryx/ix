(* The command line: mini-rc [-eiIlrvxp] [-c cmd] [-m rcmain] [file [arg ...]]
 *
 * rc does not start in C: it runs a script, rcmain, which reads the
 * profile if asked, then the -c command, the file, or the terminal
 * (plan9port's rcmain, embedded here as it is in 9base; -m reads
 * another):
 *
 *     mini-rc script a b     *=(script a b); . rcmain -> . $*
 *     mini-rc -c 'cmd'       cflag=cmd; . rcmain -> eval $cflag
 *     mini-rc                . rcmain -> . -i /dev/stdin, with a prompt
 *                           if the input is a terminal, or with -i
 *
 *     -e  a failed command ends rc      -x  print each command run
 *     -i  interactive                   -I  not interactive
 *     -l  a login shell: read $home/lib/profile
 *
 * The environment is read first (functions included), then the flags
 * are set as variables flag reads, and $status is rc's exit code:
 * "" 0, a number that number, anything else 1. *)

type caps = < Eval.caps; Cap.argv; Cap.exit >

val main : < caps; .. > -> string array -> int
