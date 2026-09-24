(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Record.mli *)

type width = W8 | W16 | W32
type value = Null | Int of width * int | Text of string

exception Invalid_type of int

let get4 b off = Int32.to_int (Bytes.get_int32_be b off) land 0xffffffff
let put4 b off v = Bytes.set_int32_be b off (Int32.of_int v)
let get2 b off = Bytes.get_uint16_be b off
let put2 b off v = Bytes.set_uint16_be b off (v land 0xffff)

let get_varint32 b off =
  let byte i = Char.code (Bytes.get b (off + i)) land 0x7f in
  (byte 0 lsl 21) lor (byte 1 lsl 14) lor (byte 2 lsl 7) lor byte 3

(* claude: chidb's putVarint32 keeps 28 bits, 7 a byte, the high bit
 * set on the first three *)
let put_varint32 b off v =
  let at i shift more = Bytes.set b (off + i) (Char.chr (((v lsr shift) land 0x7f) lor if more then 0x80 else 0)) in
  at 0 21 true; at 1 14 true; at 2 7 true; at 3 0 false

let type_of = function
  | Null -> 0
  | Int (W8, _) -> 1
  | Int (W16, _) -> 2
  | Int (W32, _) -> 4
  | Text s -> (2 * String.length s) + 13

let pack (vs : value list) : string =
  let header = 1 + List.fold_left (fun n v -> n + (match v with Text _ -> 4 | Null | Int _ -> 1)) 0 vs in
  let data = List.fold_left (fun n v -> n + (match v with Null -> 0 | Int (W8, _) -> 1 | Int (W16, _) -> 2 | Int (W32, _) -> 4 | Text s -> String.length s)) 0 vs in
  let b = Bytes.make (header + data) '\000' in
  Bytes.set b 0 (Char.chr (header land 0xff));
  let h = ref 1 and d = ref header in
  List.iter (fun v ->
    (match v with
     | Text _ -> put_varint32 b !h (type_of v); h := !h + 4
     | Null | Int _ -> Bytes.set b !h (Char.chr (type_of v)); incr h);
    match v with
    | Null -> ()
    | Int (W8, n) -> Bytes.set b !d (Char.chr (n land 0xff)); incr d
    | Int (W16, n) -> put2 b !d n; d := !d + 2
    | Int (W32, n) -> put4 b !d n; d := !d + 4
    | Text s -> Bytes.blit_string s 0 b !d (String.length s); d := !d + String.length s) vs;
  Bytes.to_string b

(* the types, in the header at [off] *)
let types b off =
  let size = Char.code (Bytes.get b off) in
  let rec go pos acc =
    (* claude: the byte read once, into a variable: reading it again after
     * the list cell's allocation miscompiles on arm64 (OCaml 4.11 to 5.3),
     * the second read reusing an address a minor GC made stale
     * (docs/plan_bugs_ocaml.md) *)
    if pos >= size then List.rev acc
    else
      let c = Char.code (Bytes.get b (off + pos)) in
      if c land 0x80 <> 0 then go (pos + 4) (get_varint32 b (off + pos) :: acc) else go (pos + 1) (c :: acc)
  in
  size, go 1 []

let width_of = function
  | 0 -> 0 | 1 -> 1 | 2 -> 2 | 4 -> 4
  | t when t >= 13 && (t - 13) mod 2 = 0 -> (t - 13) / 2
  | t -> raise (Invalid_type t)

let packed_size b off =
  let size, ts = types b off in
  size + List.fold_left (fun n t -> n + width_of t) 0 ts

let unpack b off : value list =
  let size, ts = types b off in
  let d = ref (off + size) in
  List.map (fun t ->
    let at = !d in
    d := !d + width_of t;
    match t with
    | 0 -> Null
    | 1 -> Int (W8, Bytes.get_int8 b at)
    | 2 -> Int (W16, Bytes.get_int16_be b at)
    | 4 -> Int (W32, Int32.to_int (Bytes.get_int32_be b at))
    | t -> Text (Bytes.sub_string b at ((t - 13) / 2))) ts
