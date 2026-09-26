(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devdup.mli *)

open Types

(* the qids: N's 2N+1, Nctl's 2N+2 (dupgen's s+1) *)
let root = { path = 0; vers = 0; typ = Qt_dir }

let entries path =
  if path <> 0 then raise (Error enotdir)
  else
    let fds = (Proc.myproc ()).fgrp.fds in
    let l = ref [] in
    for fd = Array.length fds - 1 downto 0 do
      match fds.(fd) with
      | Some c ->
          let perm = match c.opened with Some { access = Oread } -> 0o400 | Some { access = Owrite } -> 0o200 | _ -> 0o600 in
          l := { Dev.dname = string_of_int fd; Dev.dqid = { path = (2 * fd) + 1; vers = 0; typ = Qt_file }; Dev.dlength = 0; Dev.dperm = perm }
               :: { Dev.dname = string_of_int fd ^ "ctl"; Dev.dqid = { path = (2 * fd) + 2; vers = 0; typ = Qt_file };
                    Dev.dlength = 0; Dev.dperm = 0o400 } :: !l
      | None -> ()
    done;
    !l

let init () =
  let d = Dev.default 'd' "dup" in
  Dev.register { d with
    Dev.attach = (fun _ -> Dev.attach 'd' 0 root);
    Dev.walk = Dev.tab_walk entries (fun _ -> root);
    Dev.stat = Dev.tab_stat "#d" entries (fun _ -> root);
    Dev.dirs = Dev.tab_dirs entries;
    Dev.open_ = (fun c m ->
      if c.qid.typ = Qt_dir then Dev.tab_open c m
      else if c.qid.path land 1 = 0 then begin
        if m.access <> Oread then raise (Error eperm);
        c
      end else begin
        (* the descriptor's channel, once more (dupopen) *)
        let p = Proc.myproc () in
        let f = Chan.fdtochan p ((c.qid.path - 1) / 2) (Some (if m.access = Oexec then Oread else m.access)) in
        Chan.incref f;
        f
      end);
    Dev.read = (fun c n off ->
      let p = Proc.myproc () in
      let f = Chan.fdtochan p ((c.qid.path - 2) / 2) None in
      let s = Printf.sprintf "%11d %s\n" f.offset f.cname in
      if off >= String.length s then "" else String.sub s off (min n (String.length s - off)));
  }
