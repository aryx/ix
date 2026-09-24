(* References: names for commits, files under .git holding a hash or
 * "ref: " and another reference's name (git9's ref.c: readref,
 * listrefs).
 *
 *   .git/HEAD               ref: refs/heads/master
 *   .git/refs/heads/master  1f7a7a472abf3dd9643fd615f6da379c4acb3e3a
 *
 * A name is looked for as given, then under refs/, refs/heads/,
 * refs/remotes/, refs/tags/, the first file found deciding; then as an
 * abbreviated hash. C git also keeps references in one file,
 * .git/packed-refs, a "HASH NAME" line each: read here after the loose
 * file of each place (git9 does not: deliberate difference 2). *)

(* its hash; the store is for abbreviations *)
val read : Store.t -> string -> Hash.t option

(* what HEAD points to, "refs/heads/master", unless detached *)
val head_ref : Fpath.t -> string option

(* all references under refs/, as "heads/master", sorted *)
val list : Store.t -> (string * Hash.t) list

(* written through a temporary file and a rename; "refs/heads/x" or
 * "HEAD" *)
val write : Store.t -> string -> Hash.t -> unit
val write_symbolic : Store.t -> string -> string -> unit
val remove : Store.t -> string -> unit
