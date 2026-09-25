(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Dev.mli *)

open Types

type t = {
  dc : char;
  attach : string -> chan;
  walk : chan -> string -> qid;
  open_ : chan -> mode -> unit;
  read : chan -> int -> int -> string;
  write : chan -> string -> int -> int;
  close : chan -> unit;
}

let devtab = ref []

let register d = devtab := !devtab @ [ d ]

let find dc =
  try List.find (fun d -> d.dc = dc) !devtab
  with Not_found -> raise (Error ebadsharp)

let attach dc qid = { dev = dc; qid = qid; offset = 0; opened = None; cname = "#" ^ String.make 1 dc }

type dirtab = { dname : string; dqid : qid; dlength : int; dperm : int }

let walk_tab entries parent (c : chan) name =
  if c.qid.typ <> Qt_dir then raise (Error enotdir)
  else if name = ".." then parent c.qid.path
  else
    try (List.find (fun d -> d.dname = name) (entries c.qid.path)).dqid
    with Not_found -> raise (Error enonexist)

let open_tab (c : chan) m =
  if c.qid.typ = Qt_dir && m.access <> Oread then raise (Error eisdir)

let no_write (_ : chan) (_ : string) (_ : int) = raise (Error eperm)
