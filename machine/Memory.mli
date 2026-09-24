(* A guest's memory: segments of bytes at addresses, each checked on
 * every access; the bus the CPU loads and stores through (plan_arm.md,
 * decision 4). An access outside every segment raises Fault, the
 * guest's segmentation fault.
 *
 *   map m ~base:0x80a0 ~size:0x6ee8 "text"
 *   load32 m 0x80cc                       the word at the entry
 *
 * Addresses and values are words (Bits): compared unsigned, so that
 * the same code is right under js_of_ocaml. Little-endian. Unaligned
 * words and halfwords are allowed, as ARMv6 and later allow them to
 * user programs. *)

type t

exception Fault of int

val create : unit -> t

(* a zeroed segment *)
val map : t -> base:int -> size:int -> string -> unit

(* a segment of the caller's bytes (a board's RAM) *)
val map_bytes : t -> base:int -> string -> Bytes.t -> unit

(* a device: loads and stores of 1, 2 or 4 bytes by offset in its range
 * (a board's registers); the last mapped wins where ranges overlap *)
type device = { read : int -> int -> int; write : int -> int -> int -> unit }

val map_device : t -> base:int -> size:int -> string -> device -> unit

(* the segment's end grown or shrunk (brk); its end *)
val resize : t -> string -> size:int -> unit
val segment_end : t -> string -> int

val load8 : t -> int -> int
val load16 : t -> int -> int
val load32 : t -> int -> int
val store8 : t -> int -> int -> unit
val store16 : t -> int -> int -> unit
val store32 : t -> int -> int -> unit

(* arm64's doublewords, as Int64 (an int has 63 bits, or 32 under
 * js_of_ocaml) *)
val load64 : t -> int -> int64
val store64 : t -> int -> int64 -> unit

val write_string : t -> int -> string -> unit
val read_string : t -> int -> int -> string

(* a NUL-terminated string at the address *)
val read_cstring : t -> int -> string
