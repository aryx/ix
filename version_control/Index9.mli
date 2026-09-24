(* .git/INDEX9, git9's staging file: text, a line a path, the last line
 * of a path winning (walk.c and save.c read it, the scripts append to
 * it, walk rewrites it).
 *
 *   A NOQID 0 new.c                     added (git/add)
 *   R NOQID 0 old.c                     to be removed (git/rm)
 *   T 1a2b3.1600000000123456.4d2 644 lib/a.c   tracked, and how it
 *                                       looked when last seen clean
 *
 * The second field is a Plan 9 qid (path, version, type), which
 * changes when the file does; on Linux its stand-in is the inode, the
 * modification time in microseconds and the size,
 * "INODE.MTIME.SIZE" in hex, decimal, hex. NOQID, or a mode of 0,
 * means "compare the bytes". A file changed twice within a clock tick
 * keeps its time: walk does not record the fingerprint of a file
 * modified in the last two seconds (git's answer to its "racy index",
 * from memory). U, untracked, is dropped when the file is rewritten. *)

type state = Added | Removed | Tracked | Untracked

type qid = Noqid | Qid of { ino : int; mtime : int; size : int }

type entry = { state : state; qid : qid; mode : int; path : string; order : int }

exception Corrupt of int

val letter : state -> char

(* sorted by path, then by line: the last of a path is its state *)
val read : < Cap.open_in; .. > -> Fpath.t -> entry list option

(* the last entry of each path, U dropped; through INDEX9.new and a rename *)
val write : < Cap.open_in; Cap.open_out; .. > -> Fpath.t -> entry list -> unit

(* lines appended, "A NOQID 0 path" *)
val append : < Cap.open_in; Cap.open_out; .. > -> Fpath.t -> (state * string) list -> unit

val qid_of_stats : Unix.stats -> qid
