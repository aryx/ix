(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The SD card's image (-drive file=F,if=sd): a file read and written
 * in place, as QEMU does; with snapshot=on, the writes kept in memory
 * (by 512-byte block), the file untouched. At the executable's edge:
 * the board sees only the record. *)

open Ix_raspberry

let file path ~snapshot : Sdhost.storage =
  let fd = Unix.openfile path (if snapshot then [ O_RDONLY ] else [ O_RDWR ]) 0 in
  let size = (Unix.LargeFile.fstat fd).st_size |> Int64.to_int in
  let written : (int, Bytes.t) Hashtbl.t = Hashtbl.create 64 in
  let block_of off =
    let b = off / 512 in
    match Hashtbl.find_opt written b with
    | Some blk -> blk
    | None ->
        let blk = Bytes.make 512 '\000' in
        ignore (Unix.lseek fd (b * 512) SEEK_SET);
        let rec fill o = if o < 512 then match Unix.read fd blk o (512 - o) with 0 -> () | n -> fill (o + n) in
        fill 0;
        blk in
  (* whole blocks (the controller's reads), else byte by byte *)
  let read off len =
    if off mod 512 = 0 && len = 512 then Bytes.to_string (block_of off)
    else String.init len (fun i -> Bytes.get (block_of (off + i)) ((off + i) mod 512)) in
  let write off data =
    if snapshot then
      String.iteri (fun i c -> let blk = block_of (off + i) in Bytes.set blk ((off + i) mod 512) c; Hashtbl.replace written ((off + i) / 512) blk) data
    else begin
      ignore (Unix.lseek fd off SEEK_SET);
      ignore (Unix.write_substring fd data 0 (String.length data))
    end in
  { read; write; size }
