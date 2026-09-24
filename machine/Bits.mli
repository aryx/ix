(* The arithmetic that depends on the width of OCaml's int: 63 bits
 * natively, 32 under js_of_ocaml (plan_arm.md, decision 3). A 32-bit
 * machine word is an int holding its 32 bits: natively 0 to 2^32-1,
 * under js_of_ocaml the same bits as a signed int; the functions here
 * give the same answers either way, and nothing else in machine/ may
 * compare, print or extend a word without them.
 *
 *   field 0xe0823103 12 4 = 3           (bits 12-15: Rd)
 *   sign_extend 24 0xfffffe = -2        (a branch's imm24)
 *   ror32 0xff 8 = 0xff000000
 *   signed32 0xff000000 = -16777216 *)

(* bits lo .. lo+n-1 of w, n < 31 *)
val field : int -> int -> int -> int
val bit : int -> int -> bool

val sign_extend : int -> int -> int

(* the word, 32 bits kept *)
val mask32 : int -> int
val ror32 : int -> int -> int

(* the word read as signed, or as unsigned (natively; under
 * js_of_ocaml an int cannot hold 2^31 and above, and unsigned32 is
 * only for printing: see to_hex32) *)
val signed32 : int -> int
val unsigned32 : int -> int

(* unsigned comparison of two words: the only kind the machine does;
 * a plain ( <= ) on words is wrong under js_of_ocaml, where a word
 * with bit 31 set is negative *)
val ule32 : int -> int -> bool
val ult32 : int -> int -> bool

(* a word from and to the Int32 the Bytes accessors use *)
val of_int32 : int32 -> int
val to_int32 : int -> int32

(* a + b + carry_in (0 or 1): the sum, the carry out of bit 31, and
 * the signed overflow (ARM's C and V after an addition; a subtraction
 * a - b is a + lnot b + 1, so its C is "no borrow") *)
val add_carry : int -> int -> int -> int * bool * bool

(* the 64-bit product of two words, unsigned or signed: (low, high) *)
val mul64 : signed:bool -> int -> int -> int * int

(* shifts of a word by 0-31 *)
val lsl32 : int -> int -> int
val lsr32 : int -> int -> int
val asr32 : int -> int -> int

(* "0x%x" of the unsigned value, whatever the width *)
val to_hex32 : int -> string
