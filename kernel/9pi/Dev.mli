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
 * file is its device's function on the file's channel. *)

open Types

type t = {
  dc : char;
  (* a channel on the device's root; the spec after "#c" *)
  attach : string -> chan;
  (* one step from a directory: the name's qid ("..": the parent's), or
   * Error *)
  walk : chan -> string -> qid;
  (* the channel opened (the checks, the device's state) *)
  open_ : chan -> mode -> unit;
  (* [read c n off]: at most n bytes at off; [write c s off]: how many *)
  read : chan -> int -> int -> string;
  write : chan -> string -> int -> int;
  close : chan -> unit;
}

(* the devices, and one by its letter (Error: '#x' unknown) *)
val register : t -> unit
val find : char -> t

(* [attach dc qid]: a new channel on a device's file (devattach) *)
val attach : char -> qid -> chan

(* A device whose files are a fixed tree (Plan 9's Dirtab and devgen):
 * a directory's entries, by the directory's qid path; each entry's
 * name, qid, length and permissions (rwx bits: DMDIR, 1 lsl 31, is past
 * the Pi1's 31-bit ints; a directory is its qid's type) *)
type dirtab = { dname : string; dqid : qid; dlength : int; dperm : int }

(* walk by the tree: [walk_tab entries parent c name] *)
val walk_tab : (int -> dirtab list) -> (int -> qid) -> chan -> string -> qid

(* the checks of devopen: a directory opened for reading only *)
val open_tab : chan -> mode -> unit

(* errors of a device's missing function *)
val no_write : chan -> string -> int -> int
