(* A repository's objects, wherever they are: packs, then loose files
 * (git9's readobject and readidxobject, and its object cache).
 *
 * The packs are opened when first needed and again when an object is
 * not found (a fetch may have added one: git9's refreshpacks). *)

type caps = < Cap.open_in; Cap.open_out >

type t = {
  caps : caps;
  git : Fpath.t;          (* the .git directory *)
  mutable packs : Pack.t list option;
  cache : (Hash.t, Object.t) Hashtbl.t;
}

exception Missing of Hash.t

val open_git : caps -> Fpath.t -> t

val read_raw : t -> Hash.t -> (Object.Kind.t * string) option
val read : t -> Hash.t -> Object.t   (* or Missing *)
val mem : t -> Hash.t -> bool
val write : t -> Object.t -> Hash.t

(* a unique object whose hex name starts with the prefix, at least 8
 * digits as git9's expandprefix wants *)
val expand : t -> string -> Hash.t option

(* all objects, loose then packed (git9's ols.c) *)
val all : t -> Hash.t list

(* forget the packs, after one is added or removed *)
val refresh : t -> unit
