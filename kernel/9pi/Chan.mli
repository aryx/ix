(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* Names, channels and the namespace (principia's chan.c, pgrp.c,
 * sysfile.c's fd functions). A path is walked from the process's root
 * ("/": cleaned first, ".." lexical, as Plan 9's cleanname), its current
 * directory, or a device ("#c/cons"); at each step, a mount point (the
 * process's Pgrp) is replaced by what is bound there: a union, whose
 * members are tried in order. Binding adds to a union (MREPL, MBEFORE,
 * MAFTER; MCREATE: where create goes). The file descriptors too. *)

open Types

(* the flags of bind and mount *)
val mrepl : int
val mbefore : int
val mafter : int
val mcreate : int

(* an open's mode from its bits (openmode: Error on unknown bits) *)
val mode_of_int : int -> mode

(* a copy of a channel, a file of its own (devmnt's: a new fid); an
 * unopened channel no one holds dropped (devmnt: its fid clunked) *)
val clone : chan -> chan
val clunk : chan -> unit

(* the same file (eqchan: its device, instance, qid path) *)
val same : chan -> chan -> bool

(* [namec p path]: the channel of [path], through the mount points; the
 * last element's too unless [nomount] (a mount point itself: bind's
 * and mount's target). Error "'path' error" when an element is missing
 * (the path up to that element). *)
val namec : proc -> string -> chan
val namec_nomount : proc -> string -> chan

(* [named path f]: f's error named with the whole path (namec's, after
 * the walk: an open's, a create's), unless the path has no names *)
val named : string -> (unit -> 'a) -> 'a

(* [create p path mode perm]: the file created (in the directory's
 * union: its first MCREATE member) and opened; an existing one opened
 * and truncated (Error eexist with OEXCL) *)
val create : proc -> string -> mode -> int -> chan

(* a channel opened, by its device (possibly another channel); one more
 * holder; one less (the device's close at the last) *)
val open_ : chan -> mode -> chan
val incref : chan -> unit
val close : chan -> unit

(* a directory's entries, over its union *)
val dirs : chan -> dir list

(* [bind pg newc old flag]: newc added to the union at old (cmount:
 * Error emount when one is a directory and not the other); [unmount
 * pg newc old] (None: all of old's union) *)
val bind : pgrp -> chan -> chan -> int -> unit
val unmount : pgrp -> chan option -> chan -> unit

(* a namespace's copy (RFNAMEG: pgrpcpy) *)
val pgrp_copy : pgrp -> pgrp

(* a free descriptor given the channel (Error enofd); [fdalloc_at]:
 * that one (dup's second argument), its channel closed *)
val fdalloc : proc -> chan -> int
val fdalloc_at : proc -> int -> chan -> unit

(* [fdtochan p fd access]: the descriptor's channel, open for [access]
 * (None: any; Error ebadfd, ebadusefd) *)
val fdtochan : proc -> int -> access option -> chan

(* descriptors' tables: a copy (RFFDG: dupfgrp), a new empty one
 * (RFCFDG), one released (closefgrp: its channels closed by its last
 * process) *)
val fgrp_copy : fgrp -> fgrp
val fgrp_new : unit -> fgrp
val fgrp_close : fgrp -> unit
val nfd : int

(* the last element of a path *)
val basename : string -> string
