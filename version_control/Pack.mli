(* Packs: many objects in one file, most stored as deltas against
 * others, and an index to find them (git9's pack.c: readpacked,
 * searchindex; indexpack and writepack in phase 7).
 *
 *   .pack:  "PACK" | version 2 | count | entry ... | SHA-1 of the above
 *   entry:  type and size (3 bits, then 7-bit groups) | zlib stream
 *           an OFS delta first says how far back its base is,
 *           a REF delta its base's hash
 *   .idx:   "\377tOc" | version 2 | fanout[256] | hashes, sorted |
 *           CRCs | 31-bit offsets (top bit: an index into) 64-bit
 *           offsets | the pack's SHA-1 | the index's SHA-1
 *
 * fanout[b] counts the hashes whose first byte is at most b, so a
 * lookup is a binary search in [fanout[b-1], fanout[b]). A pack's
 * entries have no lengths: each ends where its zlib stream does.
 *
 * References: git's Documentation/gitformat-pack.txt (from memory),
 * the formats; git9's pack.c, the reader followed. *)

type t

(* the pack beside the given .idx *)
val open_idx : < Cap.open_in; .. > -> Fpath.t -> t

val mem : t -> Hash.t -> bool

(* the object, its deltas applied; a REF delta's base may be anywhere:
 * [base] finds it *)
val read : t -> base:(Hash.t -> (Object.Kind.t * string) option) -> Hash.t -> (Object.Kind.t * string) option

val hashes : t -> Hash.t list

(* the .idx files of a repository's .git *)
val all : Fpath.t -> Fpath.t list
