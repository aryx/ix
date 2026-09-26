(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Dev.mli *)

open Types

type t = {
  dc : char;
  name : string;
  attach : string -> chan;
  walk : chan -> chan -> string -> qid;
  clone : chan -> chan -> unit;
  clunk : chan -> unit;
  stat : chan -> dir;
  dirs : chan -> dir list;
  open_ : chan -> mode -> chan;
  create : chan -> string -> mode -> int -> unit;
  read : chan -> int -> int -> string;
  write : chan -> string -> int -> int;
  remove : chan -> unit;
  wstat : chan -> dir -> unit;
  close : chan -> unit;
}

let perm () = raise (Error eperm)

let default dc name = {
  dc = dc;
  name = name;
  attach = (fun _ -> perm ());
  walk = (fun _ _ _ -> perm ());
  clone = (fun _ _ -> ());
  clunk = (fun _ -> ());
  stat = (fun _ -> perm ());
  dirs = (fun _ -> perm ());
  open_ = (fun _ _ -> perm ());
  create = (fun _ _ _ _ -> perm ());
  read = (fun _ _ _ -> perm ());
  write = (fun _ _ _ -> perm ());
  remove = (fun _ -> perm ());
  wstat = (fun _ _ -> perm ());
  close = (fun _ -> ());
}

let devtab = ref []

let register d = devtab := !devtab @ [ d ]

let all () = !devtab

let find dc =
  try List.find (fun d -> d.dc = dc) !devtab
  with Not_found -> raise (Error ebadsharp)

let attach dc devno qid =
  { dev = dc; devno = devno; qid = qid; offset = 0; opened = None; cname = "#" ^ String.make 1 dc;
    umh = []; dri = 0; cref = 1; fid = 0 }

let eve = ref ""
let kerndate = ref 0
let seconds = ref (fun () -> 0)

let mkdir (c : chan) name qid length perm =
  { d_name = name; d_qid = qid; d_perm = perm; d_length = length; d_lenhi = 0; d_atime = !seconds (); d_mtime = !kerndate;
    d_uid = !eve; d_gid = !eve; d_muid = !eve; d_type = c.dev; d_dev = c.devno }

(*****************************************************************************)
(* A fixed tree *)
(*****************************************************************************)

type dirtab = { dname : string; dqid : qid; dlength : int; dperm : int }

let tab_walk entries parent (c : chan) (_ : chan) name =
  if c.qid.typ <> Qt_dir then raise (Error enotdir)
  else if name = ".." then parent c.qid.path
  else
    try (List.find (fun d -> d.dname = name) (entries c.qid.path)).dqid
    with Not_found -> raise (Error enonexist)

let tab_stat root entries parent (c : chan) =
  let q = parent c.qid.path in
  if q.path = c.qid.path then mkdir c root c.qid 0 0o555
  else
    try
      let d = List.find (fun d -> d.dqid.path = c.qid.path) (entries q.path) in
      mkdir c d.dname d.dqid d.dlength d.dperm
    with Not_found -> raise (Error enonexist)

let tab_dirs entries (c : chan) = List.map (fun d -> mkdir c d.dname d.dqid d.dlength d.dperm) (entries c.qid.path)

let tab_open (c : chan) m =
  if c.qid.typ = Qt_dir && m.access <> Oread then raise (Error eisdir);
  c

(*****************************************************************************)
(* The machine-independent entry *)
(*****************************************************************************)

let byte v = String.make 1 (Char.chr (v land 0xff))
let le16 v = byte v ^ byte (v lsr 8)
let le32 v = Machine.le32 v
(* an int as 8 bytes: the Pi1's ints are 31 bits, the high word 0 *)
let le64 v = le32 v ^ le32 (if v < 0 then -1 else 0)
let str s = le16 (String.length s) ^ s

(* a 32-bit unsigned field kept as its low 31 bits (a time, past 2^30
 * since 2004: the Pi1's ints; 2^31, in 2038, is out of reach), bit 31
 * written 0; -1 (~0: wstat's unchanged) all ones *)
let u31 v =
  if v = -1 then le32 (-1) else byte v ^ byte (v lsr 8) ^ byte (v lsr 16) ^ byte ((v lsr 24) land 0x7f)

(* wstat's "unchanged" fields (-1) written back as all ones *)
let encode d =
  let dir = d.d_qid.typ = Qt_dir in
  let body =
    le16 (Char.code d.d_type) ^ u31 d.d_dev
    ^ byte (if dir then 0x80 else 0) ^ u31 d.d_qid.vers ^ u31 d.d_qid.path ^ le32 0
    (* the mode: DMDIR the top byte's bit *)
    ^ (if d.d_perm = -1 then le32 (-1)
       else byte d.d_perm ^ byte (d.d_perm lsr 8) ^ byte (d.d_perm lsr 16) ^ byte ((d.d_perm lsr 24) lor (if dir then 0x80 else 0)))
    ^ u31 d.d_atime ^ u31 d.d_mtime
    (* the length: d_lenhi's 2^30s over d_length's 30 bits *)
    ^ (if d.d_length = -1 then le64 (-1)
       else byte d.d_length ^ byte (d.d_length lsr 8) ^ byte (d.d_length lsr 16)
            ^ byte (((d.d_length lsr 24) land 0x3f) lor ((d.d_lenhi land 3) lsl 6)) ^ le32 (d.d_lenhi lsr 2))
    ^ str d.d_name ^ str d.d_uid ^ str d.d_gid ^ str d.d_muid in
  le16 (String.length body) ^ body

let get8 s o = Char.code s.[o]
let get16 s o = get8 s o lor (get8 s (o + 1) lsl 8)
(* a 32-bit field as C's int: ~0, wstat's "unchanged", is -1 *)
let get32 s o = Machine.get_le32 s o

(* u31's reading: a 32-bit field's low 31 bits (~0: -1) *)
let getu31 s o =
  if get32 s o = -1 then -1 else get16 s o lor (get8 s (o + 2) lsl 16) lor ((get8 s (o + 3) land 0x7f) lsl 24)
let getstr s o =
  let n = get16 s o in
  if o + 2 + n > String.length s then raise (Error ebadstat);
  String.sub s (o + 2) n, o + 2 + n

let decode s =
  if String.length s < 49 || get16 s 0 + 2 > String.length s then raise (Error ebadstat);
  let name, o = getstr s 41 in
  let uid, o = getstr s o in
  let gid, o = getstr s o in
  let muid, _ = getstr s o in
  (* the mode's bits but DMDIR (the qid's type), or -1 (~0) *)
  let mode = if get32 s 21 = -1 then -1 else get8 s 21 lor (get8 s 22 lsl 8) lor (get8 s 23 lsl 16) lor ((get8 s 24 land 0x3f) lsl 24) in
  { d_type = Char.chr (get8 s 2); d_dev = getu31 s 4;
    d_qid = { typ = (if get8 s 8 land 0x80 <> 0 then Qt_dir else Qt_file); vers = getu31 s 9; path = getu31 s 13 };
    d_perm = mode; d_atime = getu31 s 25; d_mtime = getu31 s 29;
    (* ~0 (wstat's unchanged): -1 *)
    d_length = (if get32 s 33 = -1 then -1 else get16 s 33 lor (get8 s 35 lsl 16) lor ((get8 s 36 land 0x3f) lsl 24));
    d_lenhi = (if get32 s 33 = -1 then -1 else (get8 s 36 lsr 6) lor (get16 s 37 lsl 2));
    d_name = name; d_uid = uid; d_gid = gid; d_muid = muid }

let rec drop n l = if n <= 0 then l else match l with [] -> [] | _ :: r -> drop (n - 1) r

let dirread dirs dri n =
  let b = Buffer.create n in
  let rec go l k =
    match l with
    | [] -> k
    | d :: rest ->
        let e = encode d in
        if Buffer.length b + String.length e > n then k else begin Buffer.add_string b e; go rest (k + 1) end in
  let k = go (drop dri dirs) 0 in
  if k = 0 && drop dri dirs <> [] then raise (Error "i/o count too small");
  Buffer.contents b, k
