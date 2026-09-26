(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devstub.mli *)

open Types

let root = { path = 0; vers = 0; typ = Qt_dir }

let stub dc name attached =
  let entries path = if path = 0 then [] else raise (Error enotdir) in
  let d = Dev.default dc name in
  Dev.register { d with
    Dev.attach = (fun _ -> attached (); Dev.attach dc 0 root);
    Dev.walk = Dev.tab_walk entries (fun _ -> root);
    Dev.stat = Dev.tab_stat ("#" ^ String.make 1 dc) entries (fun _ -> root);
    Dev.dirs = Dev.tab_dirs entries;
    Dev.open_ = Dev.tab_open;
  }

let rxmit = ref false

(* kbmap's letter a rune, κ (U+03BA): a private byte *)
let kbmap () = let d = Char.chr 0xba in stub d "kbmap" (fun () -> ()); Dev.set_rune d 0x3ba
let ether () = stub 'l' "ether" (fun () -> ())
let ip () = stub 'I' "ip" (fun () -> if not !rxmit then begin rxmit := true; Proc.kproc "rxmitproc" end)
let uart () = stub 't' "uart" (fun () -> ())
