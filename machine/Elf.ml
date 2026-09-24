(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Elf.mli *)

type machine = Arm | Aarch64 | Other of int
type segment = { offset : int; vaddr : int; filesz : int; memsz : int; exec : bool }
type t = { machine : machine; entry : int; segments : segment list }

exception Bad of string

let parse s =
  if String.length s < 52 || String.sub s 0 4 <> "\x7fELF" then raise (Bad "not an ELF file");
  if s.[5] <> '\001' then raise (Bad "not little-endian");
  let wide = match s.[4] with '\001' -> false | '\002' -> true | _ -> raise (Bad "bad class") in
  let u16 o = String.get_uint16_le s o in
  let u32 o = Bits.of_int32 (String.get_int32_le s o) in
  (* 64-bit fields: the low 32 bits, the programs being small *)
  let addr o = if wide then u32 o else u32 o in
  let machine = match u16 18 with 40 -> Arm | 183 -> Aarch64 | n -> Other n in
  let entry = addr 24 in
  let phoff = if wide then u32 32 else u32 28 in
  let phentsize = u16 (if wide then 54 else 42) and phnum = u16 (if wide then 56 else 44) in
  let segments = List.filter_map (fun i ->
    let p = phoff + (i * phentsize) in
    if u32 p <> 1 then None
    else if wide then Some { offset = u32 (p + 8); vaddr = u32 (p + 16); filesz = u32 (p + 32); memsz = u32 (p + 40); exec = u32 (p + 4) land 1 <> 0 }
    else Some { offset = u32 (p + 4); vaddr = u32 (p + 8); filesz = u32 (p + 16); memsz = u32 (p + 20); exec = u32 (p + 24) land 1 <> 0 })
    (List.init phnum Fun.id) in
  { machine; entry; segments }
