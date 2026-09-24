(* zlib streams: deflate's compressed blocks in a two-byte header and
 * an Adler-32 checksum (principia's lib_strings/libflate, which git9
 * uses for its loose objects and packs).
 *
 * A deflate stream is a sequence of blocks: stored (bytes as they
 * are), or Huffman-coded over two alphabets, literals and lengths in
 * one, distances in the other, a length and a distance meaning "copy
 * that many bytes from that far back" (LZ77). A block's codes are the
 * fixed ones of the format or are sent at its start (dynamic), as code
 * lengths, themselves Huffman-coded.
 *
 *    zlib:     | 78 01 | block ... block (the last one flagged) | adler32 |
 *
 * inflate reads all three kinds; deflate writes fixed-code blocks
 * only, with a greedy LZ77 over hash chains: smaller than dynamic
 * codes to write, and git reads any valid stream (an object's name is
 * the hash of its uncompressed bytes, so two compressors give the
 * same repository).
 *
 * References: P. Deutsch, RFC 1951, "DEFLATE Compressed Data Format
 * Specification version 1.3", and P. Deutsch and J-L. Gailly, RFC
 * 1950, "ZLIB Compressed Data Format Specification version 3.3" (1996;
 * from memory), the formats; M. Adler's puff.c, in zlib's contrib/
 * (from memory), the canonical-code decoding by counts used here. *)

exception Corrupt of string

(* the stream starting at [pos] of [s]: its bytes uncompressed, and
 * the position just past it (a pack's objects are streams end to
 * end, their compressed sizes nowhere) *)
val inflate : ?pos:int -> string -> string * int

val deflate : string -> string
