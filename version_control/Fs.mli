(* git9's git/fs, the repository as a file system, without the file
 * system: its paths resolved on demand (decision 4 of plan_vcs.md).
 *
 *   ctl                       "branch heads/master\nrepo /home/me/src\n"
 *   HEAD/                     the commit HEAD names (empty if none)
 *   branch/heads/master/      a commit, from .git/refs/heads/master
 *   object/HASH               a blob's bytes, a tag's; a tree's or
 *                             commit's directory
 *   COMMIT/tree/...           its files
 *   COMMIT/parent             a hash a line
 *   COMMIT/msg                the message, leading blanks dropped
 *   COMMIT/hash, author       "HASH\n", "Name <email>\n"
 *   COMMIT/committer          readable, not listed, as in git9
 *
 * A symbolic link in a tree reads as its target's text (git9 follows
 * it inside the tree). *)

type node = File of string | Dir of string list

(* a path such as "HEAD/tree/lib/a.c"; None if nothing is there *)
val resolve : Repo.t -> string -> node option
