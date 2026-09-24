(* The four kinds of git objects, parsed (git9's Object, its Cinfo
 * and Tinfo, pack.c's parsecommit and parsetree).
 *
 * An object on disk is "KIND SIZE\000CONTENT", named by the hash of
 * exactly that. A tree's content is its entries, each
 * "MODE NAME\000" and 20 raw bytes; a commit's, text:
 *
 *    tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
 *    parent 1f7a7a472abf3dd9643fd615f6da379c4acb3e3a     (0 or more)
 *    author Ori <ori@eigenstate.org> 1600000000 +0000
 *    committer Ori <ori@eigenstate.org> 1600000000 +0000
 *                                                        (a blank line)
 *    the message
 *
 * [print (parse kind s) = s] for every object C git writes with
 * canonical modes (a tree entry's 100664, from old gits, prints as
 * 100644: git9's save normalizes the same way). A commit's other
 * headers (gpgsig, encoding, mergetag) are kept as they are, where git9
 * drops a signature (deliberate difference 3). *)

module Kind : sig
  type t = Blob | Tree | Commit | Tag
  val to_string : t -> string
  val of_string : string -> t option
end

type mode = File | Exec | Dir | Link | Submodule

type entry = { mode : mode; name : string; hash : Hash.t }

(* a signature: "Name <email>", seconds since the epoch, "+0100" *)
type person = { id : string; time : int; tz : string }

type commit = {
  tree : Hash.t;
  parents : Hash.t list;
  author : person;
  committer : person;
  extra : string;    (* the other headers, verbatim, lines ending \n *)
  msg : string;      (* all after the blank line *)
}

type t = Blob of string | Tree of entry list | Commit of commit | Tag of string

exception Corrupt of string

val kind : t -> Kind.t
val parse : Kind.t -> string -> t
val print : t -> string
val hash : t -> Hash.t

val mode_bits : mode -> int

(* git's order of a tree's entries: by name, a directory's as if it
 * ended with '/' (so "a.c" < "a/" < "a0"); a file and a directory of
 * the same name are not equal, the file first (git9's entcmp) *)
val compare_entries : entry -> entry -> int

(* git9's notion of time: seconds plus the zone's offset, so that
 * "1600000000 +0100" is 1600003600 (parseauthor); history is ordered by
 * it *)
val local_time : person -> int

(* the message as git9 shows it: leading white space dropped *)
val message : commit -> string
