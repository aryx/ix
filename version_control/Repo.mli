(* The repository a command runs in: the nearest directory, from the
 * current one up, holding .git/HEAD (git9's findrepo and gitinit). *)

type t = {
  root : Fpath.t;       (* the work tree *)
  rel : int;            (* how many levels below root the command ran *)
  cwd : string;         (* that directory, relative to root, "" at root *)
  store : Store.t;
}

exception Not_a_repository

val find : Store.caps -> t

(* a repository at a known root *)
val at : Store.caps -> Fpath.t -> t

(* Plan 9's cleanname: "./a//b/../c" is "a/c", "" and "./" are ".";
 * a leading ".." stays *)
val cleanname : string -> string

(* a command's path argument relative to the root, cleaned, as git9's
 * programs make them: "./CWD/ARG", or an absolute path inside the
 * root; None for an absolute path outside *)
val relative : t -> string -> string option
