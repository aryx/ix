(* Pushing: git9's git/send (send.c, sendpack).
 *
 * Our side: the branches given (-b, as refs/heads/X), or all
 * references (-a, as listrefs names them), and the ones to delete (-r,
 * the zero hash). Their side: the references the server lists. A
 * branch is sent only if theirs is an ancestor of ours (else "remote
 * has diverged"), unless forced; then the update lines ("OLD NEW REF",
 * report-status asked for on the first if the server offers it), a
 * flush, and a pack of what they lack. The output, for push.rc:
 *
 *   update refs/heads/master 0e4c... 1f7a...
 *   uptodate refs/heads/front *)

type opts = { all : bool; force : bool; branches : string list; removed : string list }

(* Proto.Error on a failure (the server's, or "remote diverged") *)
val send : Store.t -> Proto.conn -> opts -> print:(string -> unit) -> eprint:(string -> unit) -> unit
