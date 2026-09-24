(* Loose objects: one file per object, .git/objects/ce/013625030...,
 * holding "KIND SIZE\000CONTENT" deflated (git9's readloose and
 * writeobj).
 *
 * A file is written once and never changed, since its name is its
 * content's hash: to a temporary name, then renamed, so a reader never
 * sees half an object. *)

val path : Fpath.t -> Hash.t -> Fpath.t

(* from the .git directory; None if absent *)
val read : < Cap.open_in; .. > -> Fpath.t -> Hash.t -> (Object.Kind.t * string) option

(* written unless present; its hash *)
val write : < Cap.open_out; .. > -> Fpath.t -> Object.Kind.t -> string -> Hash.t

(* the hashes of all loose objects *)
val all : Fpath.t -> Hash.t list
