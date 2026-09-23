(* The command loop, ed.c's commands(), and every command.
 *
 * A command is read and run at once: [loop] reads the addresses
 * (Address.range), then the command's letter, and each command reads
 * the rest of its line itself -- a file name, a pattern and a
 * replacement, the text of a until ".". The loop returns at the end of
 * the input, and g runs it again on its command list, once per marked
 * line (Input.set_global).
 *
 *     1,$s/x/X/g          every x on every line
 *     g/^#/d              the comment lines deleted, in one pass
 *     /main/;/}/m0        from the next main to the } after it, moved first
 *
 * {b s}, the only complicated command: the n-th match (s2/a/X/), all
 * the later ones (g), the empty match (s/x*\/-/g gives -a-b-c-: after
 * an empty match the search moves one character on), & and \1-\8 in
 * the replacement, and a \ then a newline in it, which makes several
 * lines of one; the last line changed is kept, with the one it
 * replaced, for u.
 *
 * Errors are Input.Error, caught by [run], which prints ? (or ?file)
 * and starts the loop again, after Input.recover. *)

type t

type caps = < Cap.fork; Cap.exec; Cap.wait; Cap.open_in; Cap.open_out >

(* [create caps input ~verbose ~filter]: verbose is ed.c's vflag (off
 * with -: no counts, no !, q and e never complain), filter -o *)
val create : < caps; .. > -> Input.t -> verbose:bool -> filter:bool -> t

(* [run t first]: the loop, until q or the end of the input (after an
 * optional first command, ed.c's globp: "r" to read the file named on
 * the command line, "a" for -o); the loop starts again after each
 * error, as ed.c's setjmp does *)
val run : t -> file:string option -> unit

(* the buffer written to ed.hup, for a hangup *)
val rescue : t -> unit
