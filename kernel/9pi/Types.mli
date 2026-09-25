(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* mini-9pi's data (plan_9pi.md): Plan 9's kernel structures as records
 * and variants. Stage A has the files (qids, channels: no mount table
 * yet), the processes, their segments; the rest comes with the stages
 * (9P's messages, notes, the namespace: B). *)

(*****************************************************************************)
(* Errors *)
(*****************************************************************************)

(* Plan 9's error(): the kernel's work abandoned, the system call
 * failing with the message (errstr) *)
exception Error of string

(* principia's error strings (kernel/core/error.c) *)
val enonexist : string
val ebadsharp : string
val enotdir : string
val eisdir : string
val eperm : string
val ebadusefd : string
val ebadarg : string
val ebadfd : string
val enofd : string
val ebadexec : string
val enovmem : string
val esoverlap : string
val enegoff : string
val egreg : string

(* Plan 9's nameerror: "'name' error" *)
val nameerror : string -> string -> 'a

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
