(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Pack.mli *)

type t = {
  pack : string;
  idx : string;
  count : int;
  (* resolved objects by offset, so that a delta chain's bases are
   * inflated once; emptied past a size (git9's cache is by hash) *)
  cache : (int, Object.Kind.t * string) Hashtbl.t;
  mutable cached : int;
}

exception Corrupt = Object.Corrupt

let corrupt fmt = Printf.ksprintf (fun s -> raise (Corrupt s)) fmt

let u32 s pos = Int32.to_int (String.get_int32_be s pos) land 0xffffffff

let open_idx caps (f : Fpath.t) =
  let idx = Files.read caps f in
  let pack = Files.read caps (Fpath.set_ext ".pack" f) in
  if String.length idx < 8 + 1024 || String.sub idx 0 8 <> "\xfftOc\000\000\000\002" then corrupt "%s: not an index v2" (Fpath.to_string f);
  if String.length pack < 12 || String.sub pack 0 4 <> "PACK" then corrupt "%s: not a pack" (Fpath.to_string f);
  { pack; idx; count = u32 idx (8 + 255 * 4); cache = Hashtbl.create 64; cached = 0 }

let fanout t b = if b < 0 then 0 else u32 t.idx (8 + b * 4)
let hash_at t i = Sha1.of_raw (String.sub t.idx (8 + 1024 + i * 20) 20)

let find t (h : Hash.t) =
  let raw = Sha1.raw h in
  let b = Char.code raw.[0] in
  let rec search lo hi =
    if lo >= hi then None
    else
      let mid = (lo + hi) / 2 in
      let c = String.compare (String.sub t.idx (8 + 1024 + mid * 20) 20) raw in
      if c = 0 then Some mid else if c < 0 then search (mid + 1) hi else search lo mid
  in
  search (fanout t (b - 1)) (fanout t b)

let offset t i =
  let off = u32 t.idx (8 + 1024 + (t.count * 24) + (i * 4)) in
  if off land 0x80000000 = 0 then off
  else Int64.to_int (String.get_int64_be t.idx (8 + 1024 + (t.count * 28) + ((off land 0x7fffffff) * 8)))

let mem t h = find t h <> None
let hashes t = List.init t.count (hash_at t)

(* an entry's header: its type code, its size, where what follows is *)
let header s pos =
  let c = Char.code s.[pos] in
  let rec size pos c shift acc =
    if c land 0x80 = 0 then acc, pos
    else let c = Char.code s.[pos] in size (pos + 1) c (shift + 7) (acc lor ((c land 0x7f) lsl shift)) in
  let n, pos = size (pos + 1) c 4 (c land 0x0f) in
  (c lsr 4) land 7, n, pos

let kind_of_code : int -> Object.Kind.t option = function
  | 1 -> Some Commit | 2 -> Some Tree | 3 -> Some Blob | 4 -> Some Tag | _ -> None

let rec read_at t ~base off =
  match Hashtbl.find_opt t.cache off with
  | Some o -> o
  | None ->
      let code, size, pos = header t.pack off in
      let inflate pos =
        let d, _ = Zlib.inflate ~pos t.pack in
        if String.length d <> size then corrupt "pack entry at %d: size %d, not %d" off (String.length d) size;
        d in
      let o =
        match kind_of_code code, code with
        | Some k, _ -> k, inflate pos
        | None, 6 ->
            (* the distance back: 7-bit groups, most significant first,
             * each continuation adding one (git9's readodelta) *)
            let rec dist pos acc =
              let c = Char.code t.pack.[pos] in
              let acc = (acc lsl 7) lor (c land 0x7f) in
              if c land 0x80 <> 0 then dist (pos + 1) (acc + 1) else acc, pos + 1 in
            let c0 = Char.code t.pack.[pos] in
            let d, pos = if c0 land 0x80 = 0 then c0, pos + 1 else dist (pos + 1) ((c0 land 0x7f) + 1) in
            if d > off then corrupt "junk offset -%d (from %d)" d off;
            let k, b = read_at t ~base (off - d) in
            k, Delta.apply b (Delta.decode (inflate pos))
        | None, 7 -> (
            let h = Sha1.of_raw (String.sub t.pack pos 20) in
            let b = match find t h with Some i -> Some (read_at t ~base (offset t i)) | None -> base h in
            match b with
            | Some (k, b) -> k, Delta.apply b (Delta.decode (inflate (pos + 20)))
            | None -> corrupt "missing delta base %s" (Hash.to_hex h))
        | None, _ -> corrupt "unknown type %d at %d" code off
      in
      if t.cached > 64 * 1024 * 1024 then (Hashtbl.reset t.cache; t.cached <- 0);
      Hashtbl.replace t.cache off o;
      t.cached <- t.cached + String.length (snd o);
      o

let read t ~base h = Option.map (fun i -> read_at t ~base (offset t i)) (find t h)

let all git =
  let dir = Fpath.(git / "objects" / "pack") in
  match Sys.readdir (Fpath.to_string dir) with
  | fs -> Array.to_list fs |> List.sort compare |> List.filter (fun f -> Filename.check_suffix f ".idx") |> List.map (fun f -> Fpath.(dir / f))
  | exception Sys_error _ -> []

(*****************************************************************************)
(* Writing *)
(*****************************************************************************)

type entry = Whole of Object.Kind.t * string | Ref_delta of Hash.t * Delta.t

let code_of_kind : Object.Kind.t -> int = function Commit -> 1 | Tree -> 2 | Blob -> 3 | Tag -> 4

(* type in bits 4-6, the size's low 4 bits, then 7-bit groups *)
let header_bytes b ty len =
  let first = (ty lsl 4) lor (len land 0xf) in
  let rest = len lsr 4 in
  if rest = 0 then Buffer.add_char b (Char.chr first)
  else begin
    Buffer.add_char b (Char.chr (first lor 0x80));
    let rec go n = if n >= 0x80 then (Buffer.add_char b (Char.chr (0x80 lor (n land 0x7f))); go (n lsr 7)) else Buffer.add_char b (Char.chr n) in
    go rest
  end

let write entries =
  let b = Buffer.create 4096 in
  Buffer.add_string b "PACK";
  let be32 n = let x = Bytes.create 4 in Bytes.set_int32_be x 0 (Int32.of_int n); Buffer.add_bytes b x in
  be32 2;
  be32 (List.length entries);
  List.iter (function
    | Whole (k, data) -> header_bytes b (code_of_kind k) (String.length data); Buffer.add_string b (Zlib.deflate data)
    | Ref_delta (base, d) ->
        let enc = Delta.encode d in
        header_bytes b 7 (String.length enc);
        Buffer.add_string b (Sha1.raw base);
        Buffer.add_string b (Zlib.deflate enc)) entries;
  let body = Buffer.contents b in
  body ^ Sha1.raw (Sha1.string body)

let name pack = Sha1.to_hex (Sha1.of_raw (String.sub pack (String.length pack - 20) 20))

(*****************************************************************************)
(* Indexing *)
(*****************************************************************************)

type raw = { off : int; stop : int; kind : [ `Whole of Object.Kind.t | `Ofs of int | `Ref of Hash.t ]; data : string }

let index pack ~base =
  if String.length pack < 32 || String.sub pack 0 8 <> "PACK\000\000\000\002" then corrupt "invalid header";
  let count = u32 pack 8 in
  (* the entries, in order *)
  let raws = Array.make count { off = 0; stop = 0; kind = `Ofs 0; data = "" } in
  let pos = ref 12 in
  for i = 0 to count - 1 do
    let off = !pos in
    let code, _, p = header pack off in
    let kind, p =
      match kind_of_code code, code with
      | Some k, _ -> `Whole k, p
      | None, 6 ->
          let c0 = Char.code pack.[p] in
          let rec dist pos acc =
            let c = Char.code pack.[pos] in
            let acc = (acc lsl 7) lor (c land 0x7f) in
            if c land 0x80 <> 0 then dist (pos + 1) (acc + 1) else acc, pos + 1 in
          let d, p = if c0 land 0x80 = 0 then c0, p + 1 else dist (p + 1) ((c0 land 0x7f) + 1) in
          `Ofs (off - d), p
      | None, 7 -> `Ref (Sha1.of_raw (String.sub pack p 20)), p + 20
      | None, _ -> corrupt "unknown type %d at %d" code off in
    let data, stop = Zlib.inflate ~pos:p pack in
    raws.(i) <- { off; stop; kind; data };
    pos := stop
  done;
  (* resolved: by offset, and by hash for REF deltas *)
  let by_off = Hashtbl.create count and by_hash = Hashtbl.create count in
  let resolved = Array.make count None in
  let resolve i =
    let r = raws.(i) in
    let whole k d = Some (k, d) in
    let o = match r.kind with
      | `Whole k -> whole k r.data
      | `Ofs boff -> Option.map (fun (k, b) -> k, Delta.apply b (Delta.decode r.data)) (Hashtbl.find_opt by_off boff)
      | `Ref h ->
          let b = match Hashtbl.find_opt by_hash h with Some o -> Some o | None -> base h in
          Option.map (fun (k, b) -> k, Delta.apply b (Delta.decode r.data)) b in
    Option.iter (fun (k, d) ->
      let h = Hash.of_object (Object.Kind.to_string k) d in
      resolved.(i) <- Some h;
      Hashtbl.replace by_off r.off (k, d);
      Hashtbl.replace by_hash h (k, d)) o in
  let rec passes nvalid =
    Array.iteri (fun i o -> if o = None then resolve i) resolved;
    let n = Array.fold_left (fun n o -> if o <> None then n + 1 else n) 0 resolved in
    if n < count then (if n = nvalid then corrupt "fix point reached too early: %d/%d" n count else passes n) in
  passes 0;
  (* the index *)
  let objs = Array.init count (fun i -> Option.get resolved.(i), raws.(i)) in
  Array.sort (fun (a, _) (b, _) -> Hash.compare a b) objs;
  let b = Buffer.create (1072 + count * 28) in
  let be32 n = let x = Bytes.create 4 in Bytes.set_int32_be x 0 (Int32.of_int n); Buffer.add_bytes b x in
  Buffer.add_string b "\xfftOc\000\000\000\002";
  let c = ref 0 in
  for i = 0 to 255 do
    while !c < count && Char.code (Sha1.raw (fst objs.(!c))).[0] <= i do incr c done;
    be32 !c
  done;
  Array.iter (fun (h, _) -> Buffer.add_string b (Sha1.raw h)) objs;
  Array.iter (fun (_, r) -> be32 (Zlib.crc32 ~pos:r.off ~len:(r.stop - r.off) pack)) objs;
  let big = ref [] in
  Array.iter (fun (_, r) ->
    if r.off < 1 lsl 31 then be32 r.off
    else (be32 ((1 lsl 31) lor List.length !big); big := r.off :: !big)) objs;
  List.iter (fun off -> let x = Bytes.create 8 in Bytes.set_int64_be x 0 (Int64.of_int off); Buffer.add_bytes b x) (List.rev !big);
  Buffer.add_string b (String.sub pack (String.length pack - 20) 20);
  let body = Buffer.contents b in
  body ^ Sha1.raw (Sha1.string body)
