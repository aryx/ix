(* A row's values, packed as bytes: a record.
 *
 * A header of types, then the values, no separators:
 *
 *      07 | 00 | 80 80 80 11 | 04 | 61 62 | 00 00 01 2c
 *      |    |    |             |    |       |
 *      |    |    |             |    "ab"    300
 *      |    |    |             a 4-byte integer
 *      |    |    text of (17 - 13) / 2 = 2 bytes
 *      |    NULL (the primary key, stored as the row's key instead)
 *      the header's size, this byte included
 *
 * (the row (1, "ab", 300) of t(id INTEGER PRIMARY KEY, name TEXT,
 * n INTEGER), as chidb writes it; checked). The types are SQLite's
 * serial types, cut to five: 0 NULL, 1, 2 and 4 for integers of 1, 2
 * and 4 bytes, big-endian and signed, and 2n+13 for a text of n bytes.
 * chidb writes a text's type as a varint of 4 bytes always (7 bits a
 * byte, the high bit set on all but the last), the others as 1 byte;
 * a reader takes a type with its high bit set as a varint.
 *
 * References: SQLite's record format ("The Database File Format",
 * section "Record Format", sqlite.org), where a varint takes from 1
 * to 9 bytes; chidb's fileformat page, "Database records" (checked:
 * docs/chidb-website/chidb/fileformat.html). *)

(* an integer's size in the record *)
type width = W8 | W16 | W32

type value =
  | Null
  | Int of width * int      (* the value, sign-extended from its width *)
  | Text of string

(* a record that is none of these types (chidb's SQL_NOTVALID) *)
exception Invalid_type of int

val pack : value list -> string

(* the record at [off] in the bytes *)
val unpack : Bytes.t -> int -> value list

(* its size in bytes, header included, from its header *)
val packed_size : Bytes.t -> int -> int

(* 4-byte varints and big-endian integers, as chidb's util.c *)
val get_varint32 : Bytes.t -> int -> int
val put_varint32 : Bytes.t -> int -> int -> unit
val get4 : Bytes.t -> int -> int
val put4 : Bytes.t -> int -> int -> unit
val get2 : Bytes.t -> int -> int
val put2 : Bytes.t -> int -> int -> unit
