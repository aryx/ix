(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Types.mli *)

exception Error of string

let enonexist = "file does not exist"
let ebadsharp = "unknown device in # filename"
let enotdir = "not a directory"
let eisdir = "file is a directory"
let eperm = "permission denied"
let ebadusefd = "inappropriate use of fd"
let ebadarg = "bad arg in system call"
let ebadfd = "fd out of range or not open"
let enofd = "no free file descriptors"
let ebadexec = "exec header invalid"
let enovmem = "virtual memory allocation failed"
let esoverlap = "segments overlap"
let enegoff = "negative i/o offset"
let egreg = "jmk added reentrancy for threads"

(* %#q: quoted as rc quotes, a quote doubled (short names only: the
 * C's elision of a long one's prefix is not here yet) *)
let nameerror name err =
  let b = Buffer.create 64 in
  Buffer.add_char b '\'';
  for i = 0 to String.length name - 1 do
    if name.[i] = '\'' then Buffer.add_char b '\'';
    Buffer.add_char b name.[i]
  done;
  Buffer.add_string b "' ";
  Buffer.add_string b err;
  raise (Error (Buffer.contents b))

(*****************************************************************************)
(* Files: qids, open modes, channels *)
(*****************************************************************************)

(* a file's identity on its server (Plan 9's Qid): its path, unique on
 * the server, its version, whether a directory (QTDIR) *)
type qid_type = Qt_dir | Qt_file

type qid = { path : int; vers : int; typ : qid_type }

(* an open's access (OREAD 0, OWRITE 1, ORDWR 2, OEXEC 3) and its flags
 * (OTRUNC 16, OCEXEC 32: closed by exec, ORCLOSE 64: removed by close) *)
type access = Oread | Owrite | Ordwr | Oexec

type mode = { access : access; trunc : bool; cexec : bool; rclose : bool }

(* a channel (Plan 9's Chan): a file of a device (its letter: '/' the
 * root, 'c' the console...), where it is, open or not; its name as
 * the process named it (fd2path, errors) *)
type chan = {
  dev : char;
  mutable qid : qid;
  mutable offset : int;
  mutable opened : mode option;
  mutable cname : string;
}

(*****************************************************************************)
(* Processes *)
(*****************************************************************************)

(* a segment of a process's memory, [base, top): its pages in the
 * process's table (Mmu) *)
type seg_kind = Text | Data | Bss | Stack

type segment = { kind : seg_kind; base : int; mutable top : int }

(* the file descriptors (Plan 9's Fgrp: a record, to be shared by
 * rfork) *)
type fgrp = { fds : chan option array }

(* what a sleeping process waits for *)
type wait_chan = Console_input

type state = Runnable | Running | Sleeping of wait_chan | Zombie

type proc = {
  pid : int;
  slot : int;
  mutable state : state;
  mutable parent : int;
  (* the memory: its table, its segments *)
  mutable pgdir : int;
  mutable segs : segment list;
  (* the files: the descriptors, the root and the current directory *)
  mutable fgrp : fgrp;
  mutable slash : chan;
  mutable dot : chan;
  (* the last error (errstr), the program's name, how it exited *)
  mutable errstr : string;
  mutable text : string;
  mutable exitstr : string;
}
