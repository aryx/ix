(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devarch.mli *)

open Types

let files = [ "cputype", "ARM 1176JZF-S 0\n"; "cputemp", "0\n" ]

let root = { path = 0; vers = 0; typ = Qt_dir }

let entries path =
  if path <> 0 then raise (Error enotdir)
  else
    let rec go i l = match l with
      | [] -> []
      | (name, _) :: r ->
          { Dev.dname = name; Dev.dqid = { path = i; vers = 0; typ = Qt_file }; Dev.dlength = 0; Dev.dperm = 0o444 }
          :: go (i + 1) r in
    go 1 files

let init () =
  let d = Dev.default 'P' "arch" in
  Dev.register { d with
    Dev.attach = (fun _ -> Dev.attach 'P' 0 root);
    Dev.walk = Dev.tab_walk entries (fun _ -> root);
    Dev.stat = Dev.tab_stat "#P" entries (fun _ -> root);
    Dev.dirs = Dev.tab_dirs entries;
    Dev.open_ = Dev.tab_open;
    Dev.read = (fun c n off ->
      let s = snd (List.nth files (c.qid.path - 1)) in
      if off >= String.length s then "" else String.sub s off (min n (String.length s - off)));
  }
