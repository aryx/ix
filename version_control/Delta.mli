(* Deltas: an object as copies from a base object and inserted bytes
 * (git9's applydelta, and delta.c's encoder, phase 7).
 *
 * On the wire, the sizes of the base and of the result (7-bit groups,
 * least significant first), then instructions: a byte with its top bit
 * set copies, its low 7 bits saying which bytes of an offset (4) and a
 * length (3) follow, a length of 0 meaning 0x10000; a byte 1-127 inserts
 * that many bytes, which follow.
 *
 *    base "hello world", result "hello there":
 *    0b 0b | 91 00 06 | 05 't' 'h' 'e' 'r' 'e'
 *            copy 6 from 0   insert 5
 *
 * The instructions are a variant here, decoded once and applied. *)

type op = Copy of { off : int; len : int } | Insert of string

type t = { base_size : int; size : int; ops : op list }

exception Corrupt of string

val decode : string -> t
val encode : t -> string

(* the result, checked against the base's size and the result's *)
val apply : string -> t -> string
