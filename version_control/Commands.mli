(* git9's commands, its rc scripts (init.rc, add.rc, commit.rc,
 * branch.rc, ...), as OCaml functions following the scripts line for
 * line: what they print, their messages and their order. What the
 * scripts did through git/fs's mount (cp from .git/fs/object/H/tree/f,
 * test -e $gitfs/HEAD/tree) is done on the store directly; what they
 * did through git/walk, git/save and git/query calls Walk, Save and
 * Query.
 *
 * A command returns its exit status; a script's "die msg" raises Die,
 * printed "git/CMD: msg" by CLI, exit 1. *)

type caps = < Store.caps; Cap.stdout; Cap.stderr; Cap.fork; Cap.exec; Cap.wait >

exception Die of string

val init : caps -> string list -> int
val add : caps -> string list -> int
val rm : caps -> string list -> int
val commit : caps -> string list -> int
val branch : caps -> string list -> int
val revert : caps -> string list -> int
val diff : caps -> string list -> int
val merge : caps -> string list -> int
val repack : caps -> string list -> int
val get : caps -> string list -> int
val send : caps -> string list -> int
val serve : caps -> string list -> int
val clone : caps -> string list -> int
val pull : caps -> string list -> int
val push : caps -> string list -> int

(* a pack's bytes indexed and saved; its name *)
val save_pack : Repo.t -> string -> string
val walk : caps -> string list -> int
val save : caps -> string list -> int

(* the message cleaned as commit.rc's cleanmsg: # lines dropped, blank
 * runs made one, leading and trailing blank lines and trailing blanks
 * dropped, each line ended by a newline *)
val cleanmsg : string -> string
