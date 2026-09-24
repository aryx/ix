(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Cursor.mli *)

type entry = Row of { key : int; data : Bytes.t } | Entry of { key : int; pkey : int }
type t = { root : int; entries : entry array; mutable pos : int }
type seek = Eq | Gt | Ge | Lt | Le

let key = function Row r -> r.key | Entry e -> e.key

let root t = t.root

let open_ bt root =
  let _, cells = Btree.cells bt root in
  let entries = List.filter_map (function
    | Btree.Table_leaf { key; data } -> Some (Row { key; data })
    | Btree.Index_leaf { key; pkey } | Btree.Index_internal { key; pkey; _ } -> Some (Entry { key; pkey })
    | Btree.Table_internal _ -> None) cells in
  { root; entries = Array.of_list entries; pos = -1 }

let rewind t =
  let empty = Array.length t.entries = 0 in
  t.pos <- (if empty then -1 else 0);
  not empty

let next t = t.pos + 1 < Array.length t.entries && (t.pos <- t.pos + 1; true)
let prev t = t.pos - 1 >= 0 && (t.pos <- t.pos - 1; true)

let seek t kind k =
  let n = Array.length t.entries in
  let ok e = match kind with Eq -> key e = k | Gt -> key e > k | Ge -> key e >= k | Lt -> key e < k | Le -> key e <= k in
  let rec up i = if i >= n then false else if ok t.entries.(i) then (t.pos <- i; true) else up (i + 1) in
  let rec down i = if i < 0 then false else if ok t.entries.(i) then (t.pos <- i; true) else down (i - 1) in
  match kind with Eq | Gt | Ge -> up 0 | Lt | Le -> down (n - 1)

let current t = if t.pos < 0 then invalid_arg "Cursor.current: unpositioned" else t.entries.(t.pos)
