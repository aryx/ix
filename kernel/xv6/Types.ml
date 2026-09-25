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

type itype = Free | Dir | File | Devnode

type inode = { inum : int; mutable iref : int }

type pipe = {
  pdata : Bytes.t;
  mutable nread : int;
  mutable nwrite : int;
  mutable readopen : bool;
  mutable writeopen : bool;
}

type file_kind = Pipe_end of pipe | Inode_file of inode | Device of inode * int

type file = {
  kind : file_kind;
  mutable fref : int;
  readable : bool;
  writable : bool;
  mutable off : int;
}

type chan =
  | Ticks
  | Child_of of int
  | Pipe_readable of pipe
  | Pipe_writable of pipe
  | Console_input

type state = Runnable | Running | Sleeping of chan | Zombie

type proc = {
  pid : int;
  slot : int;
  mutable state : state;
  mutable pgdir : int;
  mutable sz : int;
  mutable parent : int;
  mutable killed : bool;
  mutable xstate : int;
  ofile : file option array;
  mutable cwd : inode;
  mutable name : string;
}
