(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Exe.mli *)

type format = Elf | Plan9

type image = { text : Bytes.t; data : Bytes.t; bss : int; text_start : int; data_start : int; entry : int }

let headr = function
  | Plan9, _ -> 32
  | Elf, Asm.Arm -> Link.rnd (52 + (3 * 32)) 16
  | Elf, Asm.Arm64 -> Link.rnd (64 + (3 * 56)) 16

let page = 4096

(* the bytes of a file, grown as written at an offset (5l's seek and
 * cput) *)
type out = { mutable b : Bytes.t; mutable len : int }

let at o off (s : Bytes.t) =
  if Bytes.length s > 0 then
  let n = off + Bytes.length s in
  if n > Bytes.length o.b then (let b = Bytes.make (max n (2 * Bytes.length o.b)) '\000' in Bytes.blit o.b 0 b 0 o.len; o.b <- b);
  (Bytes.blit s 0 o.b off (Bytes.length s);
   o.len <- max o.len n)

(* little-endian fields; [w] 2 bytes, [l] 4, [q] 8 *)
let fields (fs : [ `W of int | `L of int | `Q of int | `S of string ] list) =
  let b = Buffer.create 64 in
  List.iter (function
    | `W v -> Buffer.add_uint16_le b (v land 0xffff)
    | `L v -> Buffer.add_int32_le b (Int32.of_int v)
    | `Q v -> Buffer.add_int64_le b (Int64.of_int v)
    | `S s -> Buffer.add_string b s) fs;
  Buffer.to_bytes b

(* ELF, as goken's liblk/elf.c (elf32, elf64) writes it: three program
 * headers (text, data and bss, an empty one for Plan 9's symbols) and
 * three sections, the table after the data as 5l puts it. 5l puts it
 * at HEADR+text+data, which is inside the data's page when the data is
 * large: there, and only there, TinyLd puts it after the data *)
let elf arch (i : image) =
  let is64 = arch = Asm.Arm64 in
  let h = headr (Elf, arch) and tsize = Bytes.length i.text and dsize = Bytes.length i.data in
  let doff = Link.rnd (h + tsize) page in
  (* the headers and the names: 22 bytes, of which the header says 14 (5l's) *)
  let names = "\000.text\000.data\000.strtab\000\000" in
  let shsize = (if is64 then 3 * 64 else 3 * 40) + String.length names in
  let shoff = h + tsize + dsize in
  let shoff = if dsize > 0 && shoff + shsize > doff && shoff < doff + dsize then doff + dsize else shoff in
  let addr v = if is64 then `Q v else `L v in
  let phdr typ off va filesz memsz prot align =
    if is64 then fields [ `L typ; `L prot; `Q off; `Q va; `Q va; `Q filesz; `Q memsz; `Q align ]
    else fields [ `L typ; `L off; `L va; `L va; `L filesz; `L memsz; `L prot; `L align ]
  in
  let shdr name typ flags va off size align =
    if is64 then fields [ `L name; `L typ; `Q flags; `Q va; `Q off; `Q size; `L 0; `L 0; `Q align; `Q 0 ]
    else fields [ `L name; `L typ; `L flags; `L va; `L off; `L size; `L 0; `L 0; `L align; `L 0 ]
  in
  let ehsize, phsize, shentsize = if is64 then 64, 56, 64 else 52, 32, 40 in
  let header = fields
      [ `S "\127ELF"; `S (String.make 1 (Char.chr (if is64 then 2 else 1))); `S "\001\001\000\000"; `S (String.make 7 '\000');
        `W 2 (* EXEC *); `W (if is64 then 183 else 40); `L 1; addr i.entry; addr ehsize; addr shoff;
        `L (if is64 then 0 else 0x5000200) (* EABI 5, for Linux *);
        `W ehsize; `W phsize; `W 3; `W shentsize; `W 3; `W 2 ] in
  let o = { b = Bytes.create 0; len = 0 } in
  at o 0 header;
  at o ehsize (phdr 1 h i.text_start tsize tsize 5 page);
  at o (ehsize + phsize) (phdr 1 doff i.data_start dsize (dsize + i.bss) (if is64 then 6 else 7) page);
  at o (ehsize + (2 * phsize)) (phdr 0 (h + tsize + dsize) 0 0 0 4 4);
  at o h i.text;
  at o doff i.data;
  at o shoff (Bytes.cat
    (Bytes.concat Bytes.empty
       [ shdr 1 1 6 i.text_start h tsize 0x10000; shdr 7 1 3 i.data_start doff dsize 0x10000;
         shdr 13 3 (1 lsl 5) 0 (shoff + shsize - String.length names) 14 1 ])
    (Bytes.of_string names));
  Bytes.sub o.b 0 o.len

(* Plan 9's a.out (5l's asmb, H_PLAN9): a big-endian header, the text,
 * the data right after it *)
let plan9 arch (i : image) =
  let magic = match arch with Asm.Arm -> 0x647 | Asm.Arm64 -> Link.error "no Plan 9 a.out for arm64 yet" in
  let be v = let b = Bytes.create 4 in Bytes.set_int32_be b 0 (Int32.of_int v); b in
  Bytes.concat Bytes.empty
    ([ be magic; be (Bytes.length i.text); be (Bytes.length i.data); be i.bss; be 0; be i.entry; be 0; be 0 ]
     @ [ i.text; i.data ])

let write format arch file i =
  let b = match format with Elf -> elf arch i | Plan9 -> plan9 arch i in
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o755 file (fun oc -> Out_channel.output_bytes oc b)
