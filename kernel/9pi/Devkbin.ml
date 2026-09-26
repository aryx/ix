(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devkbin.mli *)

open Types

let qdir = 0 and qkbd = 1
let root = { path = qdir; vers = 0; typ = Qt_dir }

let entries path =
  if path <> qdir then raise (Error enotdir)
  else [ { Dev.dname = "kbin"; Dev.dqid = { path = qkbd; vers = 0; typ = Qt_file }; Dev.dlength = 0; Dev.dperm = 0o200 } ]

let busy = ref false

(* its letter a private byte, its rune U+0399 (Ι, iota) *)
let dc = Char.chr 0x99

let init () =
  let d = Dev.default dc "kbin" in
  Dev.register { d with
    Dev.drune = 0x399;
    Dev.attach = (fun _ -> Dev.attach dc 0 root);
    Dev.walk = Dev.tab_walk entries (fun _ -> root);
    Dev.stat = Dev.tab_stat "#\206\153" entries (fun _ -> root);
    Dev.dirs = Dev.tab_dirs entries;
    Dev.open_ = (fun c m ->
      if c.qid.path = qkbd then begin
        if !busy then raise (Error einuse);
        busy := true
      end;
      Dev.tab_open c m);
    Dev.close = (fun c -> if c.qid.path = qkbd then busy := false);
    Dev.read = (fun _ _ _ -> "");
    Dev.write = (fun c s _ ->
      if c.qid.path <> qkbd then raise (Error egreg);
      for i = 0 to String.length s - 1 do Kbd.kbdputsc (Char.code s.[i]) done;
      String.length s);
  }
