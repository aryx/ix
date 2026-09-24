(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Delta.mli *)

type op = Copy of { off : int; len : int } | Insert of string
type t = { base_size : int; size : int; ops : op list }

exception Corrupt of string

let corrupt s = raise (Corrupt s)

let decode s =
  let n = String.length s in
  let pos = ref 0 in
  let byte () = if !pos >= n then corrupt "truncated delta"; let c = Char.code s.[!pos] in incr pos; c in
  let varint () =
    let rec go shift acc = let c = byte () in let acc = acc lor ((c land 0x7f) lsl shift) in if c land 0x80 <> 0 then go (shift + 7) acc else acc in
    go 0 0 in
  let base_size = varint () in
  let size = varint () in
  let ops = ref [] in
  while !pos < n do
    let c = byte () in
    if c land 0x80 <> 0 then begin
      (* in order: OCaml evaluates the operands of lor right to left *)
      let v = ref 0 in
      let part bit shift = if c land bit <> 0 then v := !v lor (byte () lsl shift) in
      part 0x01 0; part 0x02 8; part 0x04 16; part 0x08 24;
      let off = !v in
      v := 0;
      part 0x10 0; part 0x20 8; part 0x40 16;
      let len = !v in
      ops := Copy { off; len = (if len = 0 then 0x10000 else len) } :: !ops
    end
    else if c = 0 then corrupt "delta: reserved instruction 0"
    else begin
      if !pos + c > n then corrupt "truncated delta";
      ops := Insert (String.sub s !pos c) :: !ops;
      pos := !pos + c
    end
  done;
  { base_size; size; ops = List.rev !ops }

let encode d =
  let b = Buffer.create 64 in
  let varint v = let rec go v = if v >= 0x80 then (Buffer.add_char b (Char.chr (0x80 lor (v land 0x7f))); go (v lsr 7)) else Buffer.add_char b (Char.chr v) in go v in
  varint d.base_size;
  varint d.size;
  List.iter (function
    | Insert s ->
        (* at most 127 bytes an instruction *)
        let rec go i = if i < String.length s then begin
            let k = min 127 (String.length s - i) in
            Buffer.add_char b (Char.chr k); Buffer.add_substring b s i k; go (i + k) end in
        go 0
    | Copy { off; len } ->
        let rec go off len = if len > 0 then begin
            let l = min len 0xffffff in
            let parts = ref [] and op = ref 0x80 in
            List.iteri (fun k v -> if v <> 0 then (op := !op lor (1 lsl k); parts := v :: !parts))
              [ off land 0xff; (off lsr 8) land 0xff; (off lsr 16) land 0xff; (off lsr 24) land 0xff;
                l land 0xff; (l lsr 8) land 0xff; (l lsr 16) land 0xff ];
            Buffer.add_char b (Char.chr !op);
            List.iter (fun v -> Buffer.add_char b (Char.chr v)) (List.rev !parts);
            go (off + l) (len - l) end in
        go off len) d.ops;
  Buffer.contents b

let apply base d =
  if String.length base <> d.base_size then corrupt "delta: mismatched source size";
  let out = Buffer.create d.size in
  List.iter (function
    | Insert s -> Buffer.add_string out s
    | Copy { off; len } ->
        if off + len > String.length base then corrupt "garbled delta: out of bounds copy";
        Buffer.add_substring out base off len) d.ops;
  if Buffer.length out <> d.size then corrupt "truncated delta";
  Buffer.contents out
