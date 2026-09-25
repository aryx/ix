(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* tiny-mkfs: the disk image of tiny-os v6's file system, made on the
 * host, as xv6's mkfs.c makes xv6's (plan_tiny_os.md, "v6's design").
 * The format is xv6's, less its log and its link counts:
 *
 *     tiny-mkfs fs.img cat echo sh ...   a root directory with the files
 *                                        (by their base names) and the
 *                                        console's device node
 *     tiny-mkfs -l fs.img                the image read back: each name
 *                                        of the root, its inode, type, size
 *
 * The disk, in blocks of 1 KB:
 *
 *     0             the superblock: a magic, the size in blocks, the
 *                   inodes' number, where the inodes, the bitmap and
 *                   the data start (six words)
 *     1 .. 4        the inodes, 64 bytes each, 16 a block: a type (0
 *                   free, 1 a directory, 2 a file, 3 a device), the
 *                   device's number, the size, 12 direct blocks and
 *                   one indirect (256 more); inode 1 is the root
 *     5             the bitmap, a bit per block, set when used
 *     6 ..          the data
 *
 * A directory is 16-byte entries: an inode's number (0: a free entry),
 * then a name of at most 12 bytes, padded with zeros. Every word is
 * little-endian and 4 bytes, as the kernel's C reads them.
 *
 * Only the kernel's C and this must agree on the format; mini-xv6, in
 * OCaml, could start from it (its xv6 format adds the log and nlink).
 *
 * With -fat, t6's file system (tiny-os's free kernel), MS-DOS's idea:
 *
 *     tiny-mkfs -fat fs.img cat sh ...   the same, in the FAT format
 *     tiny-mkfs -l fs.img                reads either
 *
 *     0             the superblock: a magic, the size in blocks, where
 *                   the FAT starts, its blocks, the root's first block
 *     1 .. 8        the FAT: a word per block of the disk, 0 free,
 *                   0xffffffff a chain's end, else the next block of
 *                   the file (the superblock's and the FAT's own blocks
 *                   are chains' ends, so never free)
 *     9 ..          the data: the root directory, then the files
 *
 * A directory is a chain of 32-byte entries: a name of at most 20
 * bytes, a type (0 free, 1 a directory, 2 a file, 3 a device), the
 * file's first block (0 when it has none) and its size. No inodes: a
 * file is its entry, so it has one name; no "." or "..": t6 resolves
 * ".." in a path by its text, as Plan 9's cleanname. *)

let bsize = 1024
let nblocks = 2048                        (* 2 MB *)
let ninodes = 64
let magic = 0x7f5f0001
let inodestart = 1 and bmapstart = 1 + (ninodes * 64 / bsize)
let datastart = bmapstart + 1
let ndirect = 12 and nindirect = bsize / 4
let t_dir = 1 and t_file = 2 and t_dev = 3

(*****************************************************************************)
(* Making *)
(*****************************************************************************)

let make files =
  let disk = Bytes.make (nblocks * bsize) '\000' in
  let put32 at v = Bytes.set_int32_le disk at (Int32.of_int v) in
  let next_block = ref datastart and next_inode = ref 1 in
  let alloc_block () =
    if !next_block >= nblocks then failwith "the disk is full";
    incr next_block; !next_block - 1 in
  (* an inode of a type, its data written in blocks *)
  let inode typ major data =
    let inum = !next_inode in
    if inum >= ninodes then failwith "no inode left";
    incr next_inode;
    let at = (inodestart * bsize) + (inum * 64) in
    let n = (String.length data + bsize - 1) / bsize in
    if n > ndirect + nindirect then failwith "a file too large";
    let indirect = if n > ndirect then alloc_block () else 0 in
    for k = 0 to n - 1 do
      let b = alloc_block () in
      Bytes.blit_string data (k * bsize) disk (b * bsize) (min bsize (String.length data - (k * bsize)));
      if k < ndirect then put32 (at + 12 + (4 * k)) b else put32 ((indirect * bsize) + (4 * (k - ndirect))) b
    done;
    put32 at typ; put32 (at + 4) major; put32 (at + 8) (String.length data);
    if indirect <> 0 then put32 (at + 12 + (4 * ndirect)) indirect;
    inum in
  let dirent inum name =
    if String.length name > 12 then failwith ("a name longer than 12: " ^ name);
    let b = Bytes.make 16 '\000' in
    Bytes.set_int32_le b 0 (Int32.of_int inum);
    Bytes.blit_string name 0 b 4 (String.length name);
    Bytes.to_string b in
  (* the root is inode 1: its entries name the files made after it *)
  let root = 1 in
  next_inode := 2;
  let entries = List.map (fun (name, data) -> dirent (inode t_file 0 data) name) files in
  let console = dirent (inode t_dev 1 "") "console" in
  let dir = String.concat "" ([ dirent root "."; dirent root ".." ] @ entries @ [ console ]) in
  let after = !next_inode in
  next_inode := root;
  ignore (inode t_dir 0 dir);
  next_inode := after;
  (* the superblock, and the used blocks in the bitmap *)
  List.iteri (fun k v -> put32 (4 * k) v) [ magic; nblocks; ninodes; inodestart; bmapstart; datastart ];
  for b = 0 to !next_block - 1 do
    let at = (bmapstart * bsize) + (b / 8) in
    Bytes.set disk at (Char.chr (Char.code (Bytes.get disk at) lor (1 lsl (b mod 8))))
  done;
  Bytes.to_string disk

(* the FAT format *)
let fat_magic = 0x7f5f0006
let fatstart = 1 and fatblocks = nblocks * 4 / bsize
let fat_data = fatstart + fatblocks

let make_fat files =
  let disk = Bytes.make (nblocks * bsize) '\000' in
  let put32 at v = Bytes.set_int32_le disk at (Int32.of_int v) in
  let fat b v = put32 ((fatstart * bsize) + (4 * b)) v in
  let next = ref fat_data in
  (* data in a chain of fresh blocks, its first returned (0 if empty) *)
  let chain data =
    let n = (String.length data + bsize - 1) / bsize in
    if !next + n > nblocks then failwith "the disk is full";
    let first = if n = 0 then 0 else !next in
    for k = 0 to n - 1 do
      let b = !next + k in
      Bytes.blit_string data (k * bsize) disk (b * bsize) (min bsize (String.length data - (k * bsize)));
      fat b (if k = n - 1 then 0xffffffff else b + 1)
    done;
    next := !next + n;
    first in
  let entry name typ first size =
    if String.length name > 20 then failwith ("a name longer than 20: " ^ name);
    let b = Bytes.make 32 '\000' in
    Bytes.blit_string name 0 b 0 (String.length name);
    List.iteri (fun k v -> Bytes.set_int32_le b (20 + (4 * k)) (Int32.of_int v)) [ typ; first; size ];
    Bytes.to_string b in
  let root = !next in
  incr next;
  let entries = List.map (fun (name, data) -> entry name t_file (chain data) (String.length data)) files in
  let dir = String.concat "" (entries @ [ entry "console" t_dev 0 0 ]) in
  if String.length dir > bsize then failwith "too many files for the root's block";
  Bytes.blit_string dir 0 disk (root * bsize) (String.length dir);
  fat root 0xffffffff;
  for b = 0 to fat_data - 1 do fat b 0xffffffff done;
  List.iteri (fun k v -> put32 (4 * k) v) [ fat_magic; nblocks; fatstart; fatblocks; root ];
  Bytes.to_string disk

(*****************************************************************************)
(* Reading back *)
(*****************************************************************************)

let list_fat disk =
  let get32 at = Int32.to_int (String.get_int32_le disk at) land 0xffffffff in
  let root = get32 16 in
  List.init (bsize / 32) (fun e ->
    let at = (root * bsize) + (e * 32) in
    let name = String.sub disk at 20 in
    let name = match String.index_opt name '\000' with Some i -> String.sub name 0 i | None -> name in
    if get32 (at + 20) = 0 then "" else Printf.sprintf "%-20s %d %4d %d\n" name (get32 (at + 20)) (get32 (at + 24)) (get32 (at + 28)))
  |> String.concat ""

let list disk =
  let get32 at = Int32.to_int (String.get_int32_le disk at) land 0xffffffff in
  if get32 0 = fat_magic then list_fat disk else begin
  if get32 0 <> magic then failwith "not a tiny-os file system";
  let inode inum = (get32 (4 * 3) * bsize) + (inum * 64) in
  let block ino k = if k < ndirect then get32 (ino + 12 + (4 * k)) else get32 ((get32 (ino + 12 + (4 * ndirect)) * bsize) + (4 * (k - ndirect))) in
  let root = inode 1 in
  let size = get32 (root + 8) in
  List.init (size / 16) (fun e ->
    let at = (block root (e * 16 / bsize) * bsize) + (e * 16 mod bsize) in
    let inum = get32 at in
    let name = String.sub disk (at + 4) 12 in
    let name = match String.index_opt name '\000' with Some i -> String.sub name 0 i | None -> name in
    let ino = inode inum in
    Printf.sprintf "%-12s %2d %d %d\n" name inum (get32 ino) (get32 (ino + 8)))
  |> String.concat ""
  end

let main (caps : < Cap.argv; Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr; .. >) =
  let read f = Files.read caps (Fpath.v f) in
  try
    match List.tl (Array.to_list (CapSys.argv caps)) with
    | [ "-l"; img ] -> Console.print caps (list (read img)); 0
    | "-fat" :: img :: files -> Files.write caps (Fpath.v img) (make_fat (List.map (fun f -> Filename.basename f, read f) files)); 0
    | img :: files when img.[0] <> '-' ->
        Files.write caps (Fpath.v img) (make (List.map (fun f -> Filename.basename f, read f) files)); 0
    | _ -> Console.eprint caps "usage: tiny-mkfs [-fat] fs.img file... | tiny-mkfs -l fs.img\n"; 2
  with Failure e | Sys_error e -> Console.eprint caps ("tiny-mkfs: " ^ e ^ "\n"); 1

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
