(* The server side: git9's git/serve (serve.c), on its standard input
 * and output, for git daemon's place, ssh, or a local clone.
 *
 * The first pkt-line names the service and the repository,
 * "git-upload-pack /path\000host=h\000"; the repository is that path
 * (under -r's prefix: git9 binds the prefix to / and the repository to
 * /, a namespace; here the paths are joined and ".." refused). Offered:
 * HEAD and refs/heads/*, the capabilities "symref=HEAD:... no-thin",
 * nothing else: no side-band, no multi_ack, no report-status. Upload:
 * the wants, the haves (the first one we have ACKed, NAK at a flush
 * and at the end otherwise), then the pack, raw. Receive (with -w):
 * the updates, the pack to the end of the input, then the references
 * under .git/_lock, each checked against the old hash; if HEAD names
 * nothing and no reference existed, it is pointed at the updated
 * branch whose commit is newest. *)

exception Fatal of string

val serve : Store.caps -> allow_write:bool -> prefix:string option -> Proto.conn -> unit
