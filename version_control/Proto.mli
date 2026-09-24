(* git's wire protocol, version 0 and 1 as git9 speaks it (proto.c):
 * pkt-lines, capabilities, and the transports.
 *
 * A pkt-line is its length in 4 hex digits (the 4 included) and its
 * bytes; "0000", the flush, ends a list. The first line of the
 * server's references carries its capabilities after a NUL:
 *
 *   003f1f7a7a47... HEAD\000multi_ack side-band-64k symref=HEAD:refs/heads/master
 *   003d0e4c55d6... refs/heads/master
 *   0000
 *
 * The transports: a local repository (git9 runs its own git/serve -w
 * over a pipe: here tinygit serve -w over a socketpair), git:// (TCP,
 * port 9418, the request "git-upload-pack /path\000host=h\000" as the
 * first pkt-line), ssh ("ssh host git-upload-pack path"; $GIT_SSH, as
 * C git reads it, instead of ssh). http(s), through Plan 9's webfs in
 * git9, is not here yet (plan_vcs.md, decision 9). *)

type direction = Upload | Receive

type transport = Local | Git | Ssh

type conn = {
  transport : transport;
  rd : Unix.file_descr;
  wr : Unix.file_descr;
  child : int option;
  mutable multiack : bool;
  mutable sideband : bool;
  mutable sideband64k : bool;
  mutable report : bool;
  mutable symref : (string * string) option;
}

exception Error of string

type pkt = Flush | Pkt of string

(* a pkt-line; "ERR msg" raises Error *)
val read_pkt : conn -> pkt
val write_pkt : conn -> string -> unit
val flush : conn -> unit

(* n bytes, fewer at the end of the stream *)
val read_raw : conn -> int -> string
val write_raw : conn -> string -> unit

(* the capabilities after the first line's NUL *)
val parse_caps : conn -> string -> unit

(* git9's parseuri: (proto, host, port, path); "host:path" is ssh *)
val parse_uri : string -> (string * string * string * string) option

(* [print] gets git9's "uri: \"...\"" line, printed for a remote *)
val connect : print:(string -> unit) -> string -> direction -> conn

(* the connection over standard input and output, for serve *)
val stdio : unit -> conn

(* the write side closed, so the other side reads to its end *)
val close_write : conn -> unit
val close : conn -> unit

(* the first position of [sub] in [s] from [from] *)
val find_sub : string -> string -> int -> int option

(* git's rules for a reference's name (git9's okref) *)
val okref : string -> bool
