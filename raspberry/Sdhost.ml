(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Sdhost.mli *)

type storage = { read : int -> int -> string; write : int -> string -> unit; size : int }

type transfer = { write : bool; start : int; total : int; mutable pos : int; buf : Buffer.t; mutable block : string }

type t = {
  card : storage option;
  resp : int array;
  mutable arg : int;
  mutable blksizecnt : int;
  mutable control0 : int;
  mutable control1 : int;
  mutable interrupt : int;
  mutable irptmask : int;
  mutable irpten : int;
  mutable app : bool;
  mutable xfer : transfer option;
  line : bool -> unit;
}

(* the interrupt bits *)
let cmddone = 1 and datadone = 2 and err = 1 lsl 15 and ctoerr = 1 lsl 16

let create ~card ~line =
  { card; resp = Array.make 4 0; arg = 0; blksizecnt = 0; control0 = 0; control1 = 0; interrupt = 0;
    irptmask = 0xffffffff; irpten = 0; app = false; xfer = None; line }

let update t = t.line (t.interrupt land t.irpten <> 0)

(* an event, when its status is enabled *)
let raise_ t bits =
  let bits = bits land t.irptmask in
  let bits = if bits land 0xffff0000 <> 0 then bits lor err else bits in
  t.interrupt <- t.interrupt lor bits;
  update t

(*****************************************************************************)
(* The card, QEMU's (hw/sd/sd.c) *)
(*****************************************************************************)

let crc7 bytes n =
  let crc = ref 0 in
  for i = 0 to n - 1 do
    let b = ref (Char.code (Bytes.get bytes i)) in
    for _ = 1 to 8 do
      crc := !crc lsl 1;
      if (!crc lxor !b) land 0x80 <> 0 then crc := !crc lxor 0x09;
      b := !b lsl 1
    done;
    crc := !crc land 0x7f
  done;
  !crc

let finish b = Bytes.set b 15 (Char.chr ((crc7 b 15 lsl 1) lor 1)); b

let cid () =
  let b = Bytes.make 16 '\000' in
  let set i v = Bytes.set b i (Char.chr (v land 0xff)) in
  set 0 0xaa; Bytes.blit_string "XY" 0 b 1 2; Bytes.blit_string "QEMU!" 0 b 3 5; set 8 0x01;
  set 9 0xde; set 10 0xad; set 11 0xbe; set 12 0xef;
  set 13 ((2006 - 2000) / 10); set 14 (((2006 mod 10) lsl 4) lor 2);
  finish b

(* a standard capacity card's CSD (version 1), its size by C_SIZE *)
let csd size =
  let b = Bytes.make 16 '\000' in
  let set i v = Bytes.set b i (Char.chr (v land 0xff)) in
  let hw = 9 and cmult = 9 and sectsize = (1 lsl 6) - 1 and wpsize = (1 lsl 8) - 1 in
  let csize = (size lsr (cmult + hw)) - 1 in
  List.iteri set [ 0x00; 0x26; 0x00; 0x32; 0x5f; 0x50 lor hw; 0xe0 lor ((csize lsr 10) land 3); (csize lsr 2) land 0xff;
                   0x3f lor ((csize lsl 6) land 0xc0); 0xfc lor ((cmult - 2) lsr 1);
                   0x40 lor (((cmult - 2) lsl 7) land 0x80) lor (sectsize lsr 1); ((sectsize lsl 7) land 0x80) lor wpsize;
                   0x90 lor (hw lsr 2); 0x20 lor ((hw lsl 6) land 0xc0); 0 ];
  finish b

(* a 136-bit response: bits 127-8 in RESP3-0 *)
let r2 t b =
  let g i = Char.code (Bytes.get b i) in
  t.resp.(3) <- (g 0 lsl 16) lor (g 1 lsl 8) lor g 2;
  t.resp.(2) <- (g 3 lsl 24) lor (g 4 lsl 16) lor (g 5 lsl 8) lor g 6;
  t.resp.(1) <- (g 7 lsl 24) lor (g 8 lsl 16) lor (g 9 lsl 8) lor g 10;
  t.resp.(0) <- (g 11 lsl 24) lor (g 12 lsl 16) lor (g 13 lsl 8) lor g 14

let rca = 0x4567
let status = 0x900                    (* ready for data, the transfer state *)

let command t cmd =
  let r1 v = t.resp.(0) <- v in
  let app = t.app in
  t.app <- false;
  match t.card with
  | None -> raise_ t ctoerr
  | Some card ->
      let blocks () = let n = (t.blksizecnt lsr 16) land 0xffff and bs = t.blksizecnt land 0x3ff in n, bs in
      let start write ~multi =
        let n, bs = blocks () in
        let total = if multi then n * bs else bs in
        t.xfer <- Some { write; start = t.arg; total; pos = 0; buf = Buffer.create 512; block = "" } in
      (match cmd, app with
       | 0, _ -> r1 0
       | 8, _ -> r1 (t.arg land 0xfff)
       | 55, _ -> t.app <- true; r1 (status lor 0x20)
       | 41, true -> r1 0x80ffff00                                    (* powered up, its voltages, SDSC: QEMU's *)
       | 2, _ -> r2 t (cid ())
       | 3, _ -> r1 (rca lsl 16)
       | 9, _ -> r2 t (csd card.size)
       | 7, _ -> r1 status; raise_ t datadone                         (* R1b: busy, then done *)
       | 12, _ -> r1 status; t.xfer <- None; raise_ t datadone
       | (6 | 16 | 13), _ -> r1 status
       | 17, _ -> r1 status; start false ~multi:false
       | 18, _ -> r1 status; start false ~multi:true
       | 24, _ -> r1 status; start true ~multi:false
       | 25, _ -> r1 status; start true ~multi:true
       | _ -> raise_ t ctoerr);
      raise_ t cmddone

(* the data port: the transfer's next word *)
let data_read t =
  match t.xfer, t.card with
  | Some x, Some card when not x.write && x.pos < x.total ->
      (* a block read at a time, served a word at a time *)
      if x.pos mod 512 = 0 then x.block <- card.read (x.start + x.pos) (min 512 (x.total - x.pos));
      let v = String.get_int32_le x.block (x.pos mod 512) |> Int32.to_int |> Bits.mask32 in
      x.pos <- x.pos + 4;
      if x.pos >= x.total then (t.xfer <- None; raise_ t datadone);
      v
  | _ -> 0

let data_write t v =
  match t.xfer, t.card with
  | Some x, Some card when x.write && x.pos < x.total ->
      Buffer.add_int32_le x.buf (Int32.of_int v);
      x.pos <- x.pos + 4;
      if Buffer.length x.buf >= 512 || x.pos >= x.total then begin
        card.write (x.start + x.pos - Buffer.length x.buf) (Buffer.contents x.buf);
        Buffer.clear x.buf
      end;
      if x.pos >= x.total then (t.xfer <- None; raise_ t datadone)
  | _ -> ()

let read t off _ =
  match off with
  | 0x04 -> t.blksizecnt
  | 0x08 -> t.arg
  | 0x10 | 0x14 | 0x18 | 0x1c -> t.resp.((off - 0x10) / 4)
  | 0x20 -> data_read t
  | 0x24 ->                                                   (* the card there; data inhibit while transferring *)
      (7 lsl 16) lor (1 lsl 19)
      lor (match t.xfer with Some x -> 2 lor 4 lor (if x.write then (1 lsl 8) lor (1 lsl 10) else (1 lsl 9) lor (1 lsl 11)) | None -> 0)
  | 0x28 -> t.control0
  | 0x2c -> t.control1 lor (if t.control1 land 1 <> 0 then 2 else 0)   (* the clock stable once enabled *)
  | 0x30 -> t.interrupt
  | 0x34 -> t.irptmask
  | 0x38 -> t.irpten
  | 0xfc -> 0x2402 lsl 16                                     (* SDHCI 3.0, vendor 0x24: QEMU's *)
  | _ -> 0

let write t off _ v =
  match off with
  | 0x04 -> t.blksizecnt <- v
  | 0x08 -> t.arg <- v
  | 0x0c -> command t ((v lsr 24) land 0x3f)
  | 0x20 -> data_write t v
  | 0x28 -> t.control0 <- v
  | 0x2c ->
      (* the resets done at once *)
      if v land (1 lsl 24) <> 0 then (t.interrupt <- 0; t.xfer <- None; t.irpten <- 0);
      if v land (1 lsl 26) <> 0 then t.xfer <- None;
      t.control1 <- v land lnot (7 lsl 24); update t
  | 0x30 -> t.interrupt <- t.interrupt land lnot v; update t
  | 0x34 -> t.irptmask <- v
  | 0x38 -> t.irpten <- v; update t
  | _ -> ()

let device t = { Memory.read = read t; write = write t }
