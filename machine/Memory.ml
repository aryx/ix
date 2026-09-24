(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Memory.mli *)

type segment = { name : string; base : int; mutable size : int; mutable data : Bytes.t }

(* the segment of the last access, its fields copied: the fast path
 * reads them without allocating (a lookup returning a pair and an
 * option cost a tenth of the interpreter's time, callgrind) *)
type t = { mutable segs : segment list; mutable base : int; mutable size : int; mutable data : Bytes.t }

exception Fault of int

let create () = { segs = []; base = 0; size = 0; data = Bytes.empty }

(* the cache forgotten when a segment changes *)
let forget m = m.size <- 0; m.data <- Bytes.empty

let map m ~base ~size name =
  m.segs <- { name; base; size; data = Bytes.make size '\000' } :: m.segs;
  forget m

let find_named m name : segment = match List.find_opt (fun (s : segment) -> s.name = name) m.segs with Some s -> s | None -> invalid_arg ("Memory: no segment " ^ name)

let resize m name ~size =
  let s = find_named m name in
  if size > Bytes.length s.data then begin
    let d = Bytes.make (max size (2 * Bytes.length s.data)) '\000' in
    Bytes.blit s.data 0 d 0 s.size;
    s.data <- d
  end
  else Bytes.fill s.data size (s.size - min s.size size) '\000';
  s.size <- size;
  forget m

let segment_end m name = let s = find_named m name in Bits.mask32 (s.base + s.size)

(* [addr .. addr+n-1] inside a segment of [base], [size]: the offset;
 * both tests, as under js_of_ocaml off + n may wrap *)
let fits ~base ~size addr n =
  let off = Bits.mask32 (addr - base) in
  Bits.ult32 off size && Bits.ule32 (off + n) size

(* the offset of [addr .. addr+n-1] in m.data, the cache filled on a miss *)
let offset m addr n =
  if fits ~base:m.base ~size:m.size addr n then Bits.mask32 (addr - m.base)
  else
    let rec go = function
      | [] -> raise (Fault addr)
      | (s : segment) :: rest ->
          if fits ~base:s.base ~size:s.size addr n then begin
            m.base <- s.base; m.size <- s.size; m.data <- s.data;
            Bits.mask32 (addr - s.base)
          end
          else go rest in
    go m.segs

let load8 m a = let o = offset m a 1 in Char.code (Bytes.unsafe_get m.data o)
let load16 m a = let o = offset m a 2 in Bytes.get_uint16_le m.data o
let load32 m a = let o = offset m a 4 in Bits.of_int32 (Bytes.get_int32_le m.data o)
let load64 m a = let o = offset m a 8 in Bytes.get_int64_le m.data o
let store64 m a v = let o = offset m a 8 in Bytes.set_int64_le m.data o v
let store8 m a v = let o = offset m a 1 in Bytes.unsafe_set m.data o (Char.unsafe_chr (v land 0xff))
let store16 m a v = let o = offset m a 2 in Bytes.set_uint16_le m.data o (v land 0xffff)
let store32 m a v = let o = offset m a 4 in Bytes.set_int32_le m.data o (Bits.to_int32 v)

let write_string m a str = if str <> "" then let o = offset m a (String.length str) in Bytes.blit_string str 0 m.data o (String.length str)
let read_string m a n = if n = 0 then "" else let o = offset m a n in Bytes.sub_string m.data o n

let read_cstring m a =
  let b = Buffer.create 32 in
  let rec go a = match load8 m a with 0 -> Buffer.contents b | c -> Buffer.add_char b (Char.chr c); go (Bits.mask32 (a + 1)) in
  go a
