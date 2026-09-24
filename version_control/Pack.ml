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
