(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* Plan 9's devices (Dev, devtab, dev.c): each a record of functions on
 * channels, found by its letter ('#c' the console). A system call on a
 * file is its device's function on the file's channel. Also what most
 * devices share: a fixed tree of files (Dirtab, devgen), and the
 * directory entry's machine-independent form (convD2M, convM2D: what
 * stat, a directory's read and 9P carry). *)

open Types

type t = {
  dc : char;
  name : string;
  (* a channel on the device's root; the spec after "#c" *)
  attach : string -> chan;
  (* [walk c nc name]: one step from a directory c to nc (c's copy): the
   * name's qid ("..": the parent's), or Error *)
  walk : chan -> chan -> string -> qid;
  (* [clone c nc]: nc, c's copy, made a file of its own (devmnt: a new
   * fid); an unopened channel dropped (devmnt: its fid clunked) *)
  clone : chan -> chan -> unit;
  clunk : chan -> unit;
  (* the file's entry; a directory's entries *)
  stat : chan -> dir;
  dirs : chan -> dir list;
  (* the channel opened: itself, or another (#s's posted channel, #d's
   * descriptor) *)
  open_ : chan -> mode -> chan;
  (* [create c name mode perm]: c, a directory, becomes the new file,
   * opened *)
  create : chan -> string -> mode -> int -> unit;
  (* [read c n off]: at most n bytes at off (not a directory's: dirs);
   * [write c s off]: how many *)
  read : chan -> int -> int -> string;
  write : chan -> string -> int -> int;
  remove : chan -> unit;
  (* the entry changed (its name, its length, its mode...) *)
  wstat : chan -> dir -> unit;
  close : chan -> unit;
}

(* a device (its letter, its name: "cons") whose every function fails
 * (Eperm), but close: the base the devices override *)
val default : char -> string -> t

(* the devices, and one by its letter (Error: '#x' unknown) *)
val register : t -> unit
val find : char -> t
val all : unit -> t list

(* [attach dc devno qid]: a new channel on a device's file (devattach) *)
val attach : char -> int -> qid -> chan

(* the kernel's owner (eve: the hostowner, #k/hostowner); when it was
 * made (kerndate: its devices' files' times, the bootdir's header) *)
val eve : string ref
val kerndate : int ref

(* the time now (seconds(): 9pi's clock starts at 0, the boot) *)
val seconds : (unit -> int) ref

(* an entry of a device's file (devdir: made at kerndate, read now,
 * eve's): [mkdir c name qid length perm] *)
val mkdir : chan -> string -> qid -> int -> int -> dir

(*****************************************************************************)
(* A fixed tree (Dirtab, devgen) *)
(*****************************************************************************)

(* a file: its name, qid, length and rwx bits *)
type dirtab = { dname : string; dqid : qid; dlength : int; dperm : int }

(* [tree name entries parent]: a device's walk, stat, dirs, open from
 * its directories' entries (by the directory's qid path) and each
 * file's parent directory (by its qid path); its root's name ("#c") *)
val tab_walk : (int -> dirtab list) -> (int -> qid) -> chan -> chan -> string -> qid
val tab_stat : string -> (int -> dirtab list) -> (int -> qid) -> chan -> dir
val tab_dirs : (int -> dirtab list) -> chan -> dir list

(* the checks of devopen: a directory opened for reading only *)
val tab_open : chan -> mode -> chan

(*****************************************************************************)
(* The machine-independent entry *)
(*****************************************************************************)

(* convD2M; convM2D (Error ebadstat). The 32-bit fields that are
 * unsigned (times, the qid's path and version, the device) are their low
 * 31 bits: a time since 2004 is past 2^30, a Pi1 int's (u31) *)
val encode : dir -> string
val decode : string -> dir
val u31 : int -> string
val getu31 : string -> int -> int

(* a directory's entries from index [dri], as many whole ones as fit in
 * n bytes (devdirread): the bytes, how many *)
val dirread : dir list -> int -> int -> string * int
