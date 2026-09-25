(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* Names and channels (principia's chan.c, sysfile.c's fd functions):
 * a path turned into a channel (namec) from the process's root ("/"),
 * its current directory, or a device ("#c/cons"); the file descriptors.
 * Stage A: no mount table yet (bind and mount: stage B), a walk is its
 * device's. *)

open Types

(* an open's mode from its bits (openmode: Error on unknown bits) *)
val mode_of_int : int -> mode

(* [namec p path]: the channel of [path] (Error "'path' error" when an
 * element is missing: the path up to that element) *)
val namec : proc -> string -> chan

(* a channel opened, by its device; closed *)
val open_ : chan -> mode -> unit
val close : chan -> unit

(* a free descriptor given the channel (Error enofd) *)
val fdalloc : proc -> chan -> int

(* [fdtochan p fd access]: the descriptor's channel, open for [access]
 * (None: any; Error ebadfd, ebadusefd) *)
val fdtochan : proc -> int -> access option -> chan

(* the last element of a path *)
val basename : string -> string
