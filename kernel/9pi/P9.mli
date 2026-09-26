(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* 9P2000, the file protocol (principia's fcall.h, convS2M/convM2S), as
 * xix's Protocol_9P designs it: a message is its tag and a request (T)
 * or a response (R), each a variant. Here the client's half: requests
 * encoded, responses decoded (devmnt). Offsets, counts, fids and qid
 * paths are ints (the Pi1's 31 bits: no file past 1GB). *)

open Types

type fid = int
type tag = int

(* a create's permissions: the rwx bits, DMDIR as the int's sign (bit
 * 31 is past the Pi1's ints: Syscall reads it so) *)
type perm = int

module Request : sig
  type t =
    | Version of int * string          (* msize, "9P2000" *)
    | Auth of fid * string * string    (* afid, uname, aname *)
    | Attach of fid * fid option * string * string   (* fid, afid, uname, aname *)
    | Walk of fid * fid * string list  (* fid, newfid, names *)
    | Open of fid * int                (* the open's mode bits *)
    | Create of fid * string * perm * int
    | Read of fid * int * int          (* offset, count *)
    | Write of fid * int * string
    | Clunk of fid
    | Remove of fid
    | Stat of fid
    | Wstat of fid * dir
    | Flush of tag
end

module Response : sig
  type t =
    | Version of int * string
    | Auth of qid
    | Attach of qid
    | Error of string
    | Walk of qid list
    | Open of qid * int                (* iounit *)
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

(* xix's {tag; typ}: mtyp, as a qid has a typ (ocaml-light's records
 * are not told apart by their type) *)
type message = { tag : tag; mtyp : message_type }

(* NOTAG, NOFID; IOHDRSZ (a read's or write's header) *)
val notag : tag
val nofid : fid
val io_header_size : int

(* a request's bytes (size[4] first) *)
val encode : message -> string

(* a response from its bytes (size[4] first; Error ebadstat when
 * malformed or a request) *)
val decode : string -> message
