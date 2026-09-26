(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#M', the mount driver (principia's devmnt.c): the files of a 9P
 * server (dossrv, ramfs, rio...) as channels, each a fid. A mount is a
 * connection, a channel to the server (#s/dos, a pipe's end), and its
 * 9P session (Tversion once, then an attach per mount); a remote file's
 * walk, open, read... is an RPC on it. Replies come back in any order:
 * one process at a time reads the connection and hands each reply to its
 * tag's waiter (mountmux). *)

open Types

(* [mount c aname]: the server on c attached (Tversion the first time,
 * then Tattach): its root's channel (sysmount's) *)
val attach : chan -> string -> chan

(* Tauth (fauth): the server's refusal (dossrv needs none) as Error *)
val auth : chan -> string -> chan

(* Tversion (fversion): the message size agreed *)
val version : chan -> int -> string -> int

(* the device registered *)
val init : unit -> unit
