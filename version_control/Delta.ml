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

(*****************************************************************************)
(* The encoder: content-defined chunks *)
(*****************************************************************************)

let minchunk = 128
let maxchunk = 8192
let splitmask = 0xff

let geartab = [|
  0x67ed26b7; 0x32da500c; 0x53d0fee0; 0xce387dc7; 0xcd406d90; 0x2e83a4d4;
  0x9fc9a38d; 0xb67259dc; 0xca6b1722; 0x6d2ea08c; 0x235cea2e; 0x3149bb5f;
  0x1beda787; 0x2a6b77d5; 0x2f22d9ac; 0x91fc0544; 0xe413acfa; 0x5a30ff7a;
  0xad6fdde0; 0x444fd0f5; 0x7ad87864; 0x58c5ff05; 0x8d2ec336; 0x2371f853;
  0x550f8572; 0x6aa448dd; 0x7c9ddbcf; 0x95221e14; 0x2a82ec33; 0xcbec5a78;
  0xc6795a0d; 0x243995b7; 0x1c909a2f; 0x4fded51c; 0x635d334b; 0x0e2b9999;
  0x2702968d; 0x856de1d5; 0x3325d60e; 0xeb6a7502; 0xec2a9844; 0x0905835a;
  0xa1820375; 0xa4be5cab; 0x96a6c058; 0x2c2ccd70; 0xba40fce3; 0xd794c46b;
  0x8fbae83e; 0xc3aa7899; 0x3d3ff8ed; 0xa0d42b5b; 0x571c0c97; 0xd2811516;
  0xf7e7b96c; 0x4fd2fcbd; 0xe2fdec94; 0x282cc436; 0x78e8e95c; 0x80a3b613;
  0xcfbee20c; 0xd4a32d1c; 0x2a12ff13; 0x6af82936; 0xe5630258; 0x8efa6a98;
  0x294fb2d1; 0xdeb57086; 0x5f0fddb3; 0xeceda7ce; 0x4c87305f; 0x3a6d3307;
  0xe22d2942; 0x9d060217; 0x1e42ed02; 0xb6f63b52; 0x4367f39f; 0x055cf262;
  0x03a461b2; 0x5ef9e382; 0x386bc03a; 0x2a1e79c7; 0xf1a0058b; 0xd4d2dea9;
  0x56baf37d; 0x5daff6cc; 0xf03a951d; 0xaef7de45; 0xa8f4581e; 0x3960b555;
  0xffbfff6d; 0xbe702a23; 0x8f5b6d6f; 0x061739fb; 0x98696f47; 0x3fd596d4;
  0x151eac6b; 0xa9fcc4f5; 0x69181a12; 0x3ac5a107; 0xb5198fe7; 0x96bcb1da;
  0x1b5ddf8e; 0xc757d650; 0x65865c3a; 0x8fc0a41a; 0x87435536; 0x99eda6f2;
  0x41874794; 0x29cff4e8; 0xb70efd9a; 0x3103f6e7; 0x84d2453b; 0x15a450bd;
  0x74f49af1; 0x60f664b1; 0xa1c86935; 0xfdafbce1; 0xe36353e3; 0x5d9ba739;
  0xbc0559ba; 0x708b0054; 0xd41d808c; 0xb2f31723; 0x9027c41f; 0xf136d165;
  0xb5374b12; 0x9420a6ac; 0x273958b6; 0xe6c2fad0; 0xebdc1f21; 0xfb33af8b;
  0xc71c25cd; 0xe9a2d8e5; 0xbeb38a50; 0xbceb7cc2; 0x4e4e73f0; 0xcd6c251d;
  0xde4c032c; 0x4b04ac30; 0x725b8b21; 0x4eb8c33b; 0x20d07b75; 0x0567aa63;
  0xb56b2bb7; 0xc1f5fd3a; 0xcafd35ca; 0x470dd4da; 0xfe4f94cd; 0xfb8de424;
  0xe8dbcf40; 0xfe50a37a; 0x62db5b5d; 0xf32f4ab6; 0x2c4a8a51; 0x18473dc0;
  0xfe0cbb6e; 0xfe399efd; 0xdf34ecc9; 0x6ccd5055; 0x46097073; 0x139135c2;
  0x721c76f6; 0x1c6a94b4; 0x6eee014d; 0x8a508e02; 0x3da538f5; 0x280d394f;
  0x5248a0c4; 0x3ce94c6c; 0x9a71ad3a; 0x8493dd05; 0xe43f0ab6; 0x18e4ed42;
  0x6c5c0e09; 0x42b06ec9; 0x8d330343; 0xa45b6f59; 0x2a573c0c; 0xd7fd3de6;
  0xeedeab68; 0x5c84dafc; 0xbbd1b1a8; 0xa3ce1ad1; 0x85b70bed; 0xb6add07f;
  0xa531309c; 0x8f8ab852; 0x564de332; 0xeac9ed0c; 0x73da402c; 0x3ec52761;
  0x43af2f4d; 0xd6ff45c8; 0x4c367462; 0xd553bd6a; 0x44724855; 0x3b2aa728;
  0x56e5eb65; 0xeaf16173; 0x33fa42ff; 0xd714bb5d; 0xfbd0a3b9; 0xaf517134;
  0x9416c8cd; 0x534cf94f; 0x548947c2; 0x34193569; 0x32f4389a; 0xfe7028bc;
  0xed73b1ed; 0x9db95770; 0x468e3922; 0x0440c3cd; 0x60059a62; 0x33504562;
  0x2b229fbd; 0x5174dca5; 0xf7028752; 0xd63c6aa8; 0x31276f38; 0x0646721c;
  0xb0191da8; 0xe00e6de0; 0x9eac1a6e; 0x9f7628a5; 0xed6c06ea; 0x0bb8af15;
  0xf119fb12; 0x38693c1c; 0x732bc0fe; 0x84953275; 0xb82ec888; 0x33a4f1b3;
  0x3099835e; 0x028a8782; 0x5fdd51d7; 0xc6c717b3; 0xb06caf71; 0x17c8c111;
  0x61bad754; 0x9fd03061; 0xe09df1af; 0x3bc9eb73; 0x85878413; 0x9889aaf2;
  0x3f5a9e46; 0x42c9f01f; 0x9984a4f4; 0xd5de43cc; 0xd294daed; 0xbecba2d2;
  0xf1f6e72c; 0x5551128a; 0x83af87e2; 0x6f0342ba;
|]

(* the length of the chunk starting at [pos] *)
let nextblk s pos e =
  if e - pos < minchunk then e - pos
  else
    let e = min e (pos + maxchunk) in
    let rec go p gh =
      if p = e then p
      else
        let gh = ((gh lsl 1) + geartab.(Char.code s.[p])) land 0xffffffff in
        if gh land splitmask = 0 then p + 1 else go (p + 1) gh
    in
    go (pos + minchunk) 0 - pos

(* the base's chunks by their bytes, the first of equal ones kept *)
type table = { base : string; chunks : (string, int) Hashtbl.t }

let table base =
  let chunks = Hashtbl.create 64 in
  let n = String.length base in
  let rec go pos =
    if pos < n then begin
      let len = nextblk base pos n in
      let c = String.sub base pos len in
      if not (Hashtbl.mem chunks c) then Hashtbl.add chunks c pos;
      go (pos + len)
    end in
  go 0;
  { base; chunks }

let deltify t target =
  let n = String.length target in
  (* a copy stops at the base's end, or at 2^24 - 1, as far as a copy's
   * offset can say *)
  let eb = min (String.length t.base) ((1 lsl 24) - 1) in
  let rec go pos acc =
    if pos >= n then List.rev acc
    else
      let len = nextblk target pos n in
      match Hashtbl.find_opt t.chunks (String.sub target pos len) with
      | Some off ->
          let p = ref (pos + len) and q = ref (off + len) in
          while !p < n && !q < eb && target.[!p] = t.base.[!q] do incr p; incr q done;
          let len = !p - pos in
          go (pos + len) (Copy { off; len } :: acc)
      | None -> go (pos + len) (Insert (String.sub target pos len) :: acc)
  in
  { base_size = String.length t.base; size = n; ops = go 0 [] }

let estimate d = List.fold_left (fun sz op -> sz + match op with Copy _ -> 7 | Insert s -> String.length s + 1) 32 d.ops
