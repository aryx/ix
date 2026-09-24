(* Fetching: git9's git/get (get.c, fetchpack).
 *
 * The server lists its references; for each of HEAD, refs/heads/*,
 * refs/tags/* (or the one branch asked for), what we have of it is our
 * copy, refs/remotes/UPSTREAM/X or refs/tags/UPSTREAM/X. We want what
 * differs and we lack ("want H", the capabilities on the first), then
 * say what we have: those copies, the -h heads, then their ancestors
 * newest first, up to 256 ("have H"), and "done". The pack comes back,
 * in side-band packets if the server offered them, and is checked,
 * indexed and saved. The output is for the scripts:
 *
 *   uri: "git://host/path"                     (a remote)
 *   symref HEAD refs/heads/master
 *   remote refs/heads/master 1f7a... local 0e4c...
 *
 * (local 0000... for what we had no copy of). *)

type opts = {
  upstream : string;           (* -u, "origin" *)
  heads : Hash.t list;         (* -h: more haves *)
  listonly : bool;             (* -l *)
  branch : string option;      (* -b: only that branch *)
}

(* the output lines through [print], progress and warnings through
 * [eprint]; Proto.Error or Object.Corrupt on a failure *)
val fetch : Store.t -> Proto.conn -> opts -> print:(string -> unit) -> eprint:(string -> unit) -> unit

(* helpers Send and Serve share: 40 hex digits at a string's start; a
 * line's fields between blanks; a C string's end at a NUL *)
val hparse : string -> Hash.t option
val fields : string -> string -> string list
val cut_nul : string -> string
