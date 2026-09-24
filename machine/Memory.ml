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

type t = { mutable segs : segment list; mutable last : segment option }

exception Fault of int

let create () = { segs = []; last = None }

let map m ~base ~size name = m.segs <- { name; base; size; data = Bytes.make size '\000' } :: m.segs

let find_named m name = match List.find_opt (fun s -> s.name = name) m.segs with Some s -> s | None -> invalid_arg ("Memory: no segment " ^ name)

let resize m name ~size =
  let s = find_named m name in
  if size > Bytes.length s.data then begin
    let d = Bytes.make (max size (2 * Bytes.length s.data)) '\000' in
    Bytes.blit s.data 0 d 0 s.size;
    s.data <- d
  end
  else Bytes.fill s.data size (s.size - min s.size size) '\000';
  s.size <- size

let segment_end m name = let s = find_named m name in Bits.mask32 (s.base + s.size)

(* the segment holding [addr .. addr+n-1], and the offset *)
let locate m addr n =
  let inside s = let off = Bits.mask32 (addr - s.base) in if Bits.ule32 (off + n) s.size && Bits.ult32 off s.size then Some off else None in
  match m.last with
  | Some s when inside s <> None -> s, Option.get (inside s)
  | _ ->
      let rec go = function
        | [] -> raise (Fault addr)
        | s :: rest -> (match inside s with Some off -> m.last <- Some s; s, off | None -> go rest) in
      go m.segs

let load8 m a = let s, o = locate m a 1 in Char.code (Bytes.unsafe_get s.data o)
let load16 m a = let s, o = locate m a 2 in Bytes.get_uint16_le s.data o
let load32 m a = let s, o = locate m a 4 in Bits.of_int32 (Bytes.get_int32_le s.data o)
let load64 m a = let s, o = locate m a 8 in Bytes.get_int64_le s.data o
let store64 m a v = let s, o = locate m a 8 in Bytes.set_int64_le s.data o v
let store8 m a v = let s, o = locate m a 1 in Bytes.unsafe_set s.data o (Char.unsafe_chr (v land 0xff))
let store16 m a v = let s, o = locate m a 2 in Bytes.set_uint16_le s.data o (v land 0xffff)
let store32 m a v = let s, o = locate m a 4 in Bytes.set_int32_le s.data o (Bits.to_int32 v)

let write_string m a str = let s, o = locate m a (String.length str) in Bytes.blit_string str 0 s.data o (String.length str)
let read_string m a n = if n = 0 then "" else let s, o = locate m a n in Bytes.sub_string s.data o n

let read_cstring m a =
  let b = Buffer.create 32 in
  let rec go a = match load8 m a with 0 -> Buffer.contents b | c -> Buffer.add_char b (Char.chr c); go (Bits.mask32 (a + 1)) in
  go a
