(* An object's name: the SHA-1 of its type, size and content (git9's
 * Hash, 20 bytes).
 *
 *   of_object "blob" "hello\n" = hash of "blob 6\000hello\n"
 *                              = ce013625030ba8dba906f756967f9e9ca394464a
 *
 * (checked with git hash-object). Equal content has one name,
 * wherever it is and whoever wrote it: that is git's first idea. *)

type t = Sha1.t

(* 40 zeros: git's "no object" (a branch created or deleted, on the
 * wire) *)
val zero : t

val of_object : string -> string -> t

val to_hex : t -> string
val of_hex : string -> t
val is_hex : string -> bool
val compare : t -> t -> int
