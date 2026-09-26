(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devsys.mli *)

open Types

let files = [ "osversion", 0o444; "config", 0o444; "hostowner", 0o664; "hostdomain", 0o664; "sysname", 0o664;
              "drivers", 0o444; "reboot", 0o660; "sysstat", 0o666 ]

let root = { path = 0; vers = 0; typ = Qt_dir }

let entries path =
  if path <> 0 then raise (Error enotdir)
  else
    let rec go i l = match l with
      | [] -> []
      | (name, perm) :: r ->
          { Dev.dname = name; Dev.dqid = { path = i; vers = 0; typ = Qt_file };
            Dev.dlength = (if name = "hostdomain" then 48 else 0); Dev.dperm = perm } :: go (i + 1) r in
    go 1 files

let name_of path = fst (List.nth files (path - 1))

let hostdomain = ref ""
let sysname = ref ""

let readstr off n s = if off >= String.length s then "" else String.sub s off (min n (String.length s - off))

(* a written name: its newline dropped *)
let chomp s = let n = String.length s in if n > 0 && s.[n - 1] = '\n' then String.sub s 0 (n - 1) else s

let init () =
  let d = Dev.default 'k' "sys" in
  Dev.register { d with
    Dev.attach = (fun _ -> Dev.attach 'k' 0 root);
    Dev.walk = Dev.tab_walk entries (fun _ -> root);
    Dev.stat = Dev.tab_stat "#k" entries (fun _ -> root);
    Dev.dirs = Dev.tab_dirs entries;
    Dev.open_ = Dev.tab_open;
    Dev.read = (fun c n off ->
      match name_of c.qid.path with
      | "osversion" -> readstr off n "pad's version"
      | "hostowner" -> readstr off n !Dev.eve
      | "hostdomain" -> readstr off n !hostdomain
      | "sysname" -> readstr off n !sysname
      | "drivers" ->
          readstr off n (String.concat "" (List.map (fun (d : Dev.t) -> "#" ^ String.make 1 d.Dev.dc ^ " " ^ d.Dev.name ^ "\n") (Dev.all ())))
      | "config" | "sysstat" -> ""
      | _ -> raise (Error egreg));
    Dev.write = (fun c s off ->
      (match name_of c.qid.path with
       | "hostowner" ->
           let s = chomp s in
           if s = "" then raise (Error ebadarg);
           Dev.eve := s
       | "hostdomain" -> hostdomain := chomp s
       | "sysname" -> if off <> 0 || s = "" then raise (Error ebadarg); sysname := chomp s
       | "sysstat" -> ()
       | _ -> raise (Error eperm));
      String.length s);
  }
