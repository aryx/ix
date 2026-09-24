(* The objects the other side lacks, packed (git9's writepack:
 * readmeta, pickdeltas, genpack), for a push, a server's reply to a
 * fetch, and repack.
 *
 * Which objects: the commits reachable from [heads] and not from
 * [have] (Query.twixt), each with its tree, its subtrees and blobs,
 * less what the tips of [have] already hold. Which deltas: the objects
 * sorted so that likely bases are near (by kind, by a hash of their
 * path, by date), each tried against the ten before it (git9's window),
 * chains kept under 128, a delta kept when it saves more than 32 bytes
 * on git9's estimate. Written in date order, newest first, each delta
 * chain together, as REF deltas. *)

val pack : Store.t -> heads:Hash.t list -> have:Hash.t list -> string

(* git9's murmurhash2 (util.c), 32 bits *)
val murmurhash2 : string -> int
