(* SHA-1, the name of every git object (git9 takes it from Plan 9's
 * libsec, sha1.c).
 *
 * A message is padded to a multiple of 64 bytes (a 1 bit, zeros, its
 * length in bits as a 64-bit big-endian number) and each 64-byte
 * block stirred into five 32-bit words by 80 rounds; the digest is the
 * five words, big-endian, 20 bytes.
 *
 *   Sha1.to_hex (Sha1.string "abc") = "a9993e364706816aba3e25717850c26c9cd0d89d"
 *
 * SHA-1 is broken for collisions (the SHAttered attack, 2017, from
 * memory); git kept it and hardened it, and git's newer SHA-256 object
 * format is the road not taken here, as it is in git9.
 *
 * References: FIPS PUB 180-4, "Secure Hash Standard" (NIST, 2015;
 * from memory), the algorithm; the test vector above checked against
 * Python's hashlib. *)

(* 20 bytes *)
type t = private string

val string : string -> t

(* the digest of the concatenation, without building it *)
val strings : string list -> t

val to_hex : t -> string

(* 40 lowercase hex digits, or Invalid_argument *)
val of_hex : string -> t

(* the 20 raw bytes, as in a tree entry or a pack index *)
val of_raw : string -> t
val raw : t -> string
