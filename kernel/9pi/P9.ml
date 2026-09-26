(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See P9.mli *)

open Types

type fid = int
type tag = int
type perm = int

module Request = struct
  type t =
    | Version of int * string
    | Auth of fid * string * string
    | Attach of fid * fid option * string * string
    | Walk of fid * fid * string list
    | Open of fid * int
    | Create of fid * string * perm * int
    | Read of fid * int * int
    | Write of fid * int * string
    | Clunk of fid
    | Remove of fid
    | Stat of fid
    | Wstat of fid * dir
    | Flush of tag
end

module Response = struct
  type t =
    | Version of int * string
    | Auth of qid
    | Attach of qid
    | Error of string
    | Walk of qid list
    | Open of qid * int
    | Create of qid * int
    | Read of string
    | Write of int
    | Clunk
    | Remove
    | Stat of dir
    | Wstat
    | Flush
end

type message_type = T of Request.t | R of Response.t

type message = { tag : tag; mtyp : message_type }

let notag = 0xffff
(* ~0: -1, as a 32-bit word (Machine.le32 writes its low 32 bits) *)
let nofid = -1
let io_header_size = 24

(*****************************************************************************)
(* Encoding *)
(*****************************************************************************)

let byte v = String.make 1 (Char.chr (v land 0xff))
let le16 v = byte v ^ byte (v lsr 8)
let le32 v = Machine.le32 v
let le64 v = le32 v ^ le32 (if v < 0 then -1 else 0)
let str s = le16 (String.length s) ^ s

(* a perm's 4 bytes: DMDIR from the sign *)
let perm32 p =
  let v = p land 0x3fffffff in
  byte v ^ byte (v lsr 8) ^ byte (v lsr 16) ^ byte ((v lsr 24) lor (if p < 0 then 0x80 else 0))

let encode m =
  let typ, body =
    match m.mtyp with
    | T r ->
        (match r with
         | Request.Version (msize, v) -> 100, le32 msize ^ str v
         | Request.Auth (afid, uname, aname) -> 102, le32 afid ^ str uname ^ str aname
         | Request.Attach (fid, afid, uname, aname) ->
             104, le32 fid ^ le32 (match afid with Some a -> a | None -> nofid) ^ str uname ^ str aname
         | Request.Flush oldtag -> 108, le16 oldtag
         | Request.Walk (fid, newfid, names) ->
             110, le32 fid ^ le32 newfid ^ le16 (List.length names) ^ String.concat "" (List.map str names)
         | Request.Open (fid, mode) -> 112, le32 fid ^ byte mode
         | Request.Create (fid, name, perm, mode) -> 114, le32 fid ^ str name ^ perm32 perm ^ byte mode
         | Request.Read (fid, off, count) -> 116, le32 fid ^ le64 off ^ le32 count
         | Request.Write (fid, off, data) -> 118, le32 fid ^ le64 off ^ le32 (String.length data) ^ data
         | Request.Clunk fid -> 120, le32 fid
         | Request.Remove fid -> 122, le32 fid
         | Request.Stat fid -> 124, le32 fid
         | Request.Wstat (fid, d) -> let s = Dev.encode d in 126, le32 fid ^ le16 (String.length s) ^ s)
    | R _ -> raise (Error "P9.encode: a response") in
  let body = byte typ ^ le16 m.tag ^ body in
  le32 (String.length body + 4) ^ body

(*****************************************************************************)
(* Decoding *)
(*****************************************************************************)

let get8 s o = Char.code s.[o]
let get16 s o = get8 s o lor (get8 s (o + 1) lsl 8)
let get32 s o = Machine.get_le32 s o
let getstr s o = let n = get16 s o in String.sub s (o + 2) n, o + 2 + n
let getqid s o = { typ = (if get8 s o land 0x80 <> 0 then Qt_dir else Qt_file); vers = Dev.getu31 s (o + 1); path = Dev.getu31 s (o + 5) }

let decode s =
  try
    let typ = get8 s 4 and tag = get16 s 5 in
    let o = 7 in
    let r =
      match typ with
      | 101 -> let v, _ = getstr s (o + 4) in Response.Version (get32 s o, v)
      | 103 -> Response.Auth (getqid s o)
      | 105 -> Response.Attach (getqid s o)
      | 107 -> Response.Error (fst (getstr s o))
      | 109 -> Response.Flush
      | 111 ->
          let n = get16 s o in
          let rec qids i = if i = n then [] else getqid s (o + 2 + (13 * i)) :: qids (i + 1) in
          Response.Walk (qids 0)
      | 113 -> Response.Open (getqid s o, get32 s (o + 13))
      | 115 -> Response.Create (getqid s o, get32 s (o + 13))
      | 117 -> let n = get32 s o in Response.Read (String.sub s (o + 4) n)
      | 119 -> Response.Write (get32 s o)
      | 121 -> Response.Clunk
      | 123 -> Response.Remove
      | 125 -> let n = get16 s o in Response.Stat (Dev.decode (String.sub s (o + 2) n))
      | 127 -> Response.Wstat
      | _ -> raise (Error ebadstat) in
    { tag = tag; mtyp = R r }
  with Invalid_argument _ -> raise (Error ebadstat)
