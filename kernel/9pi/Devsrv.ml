(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devsrv.mli *)

open Types

type srv = { sname : string; spath : int; sperm : int; sowner : string; mutable schan : chan option }

let srvs = ref []
let last_path = ref 0

let root = { path = 0; vers = 0; typ = Qt_dir }

let lookup path = try List.find (fun s -> s.spath = path) !srvs with Not_found -> raise (Error enonexist)

(* its owner the process's user when made (the hostowner, maybe not
 * named yet: ''), its group eve's *)
let dir_of c s = { (Dev.mkdir c s.sname { path = s.spath; vers = 0; typ = Qt_file } 0 s.sperm) with d_uid = s.sowner }

let remove (c : chan) =
  if c.qid.typ = Qt_dir then raise (Error eperm);
  let s = lookup c.qid.path in
  if s.sname = "boot" then raise (Error eperm);
  srvs := List.filter (fun x -> x != s) !srvs;
  match s.schan with Some sc -> Chan.close sc | None -> ()

let init () =
  let d = Dev.default 's' "srv" in
  Dev.register { d with
    Dev.attach = (fun _ -> Dev.attach 's' 0 root);
    Dev.walk = (fun c nc name ->
      if c.qid.typ <> Qt_dir then raise (Error enotdir)
      else if name = ".." then root
      else try { path = (List.find (fun s -> s.sname = name) !srvs).spath; vers = 0; typ = Qt_file }
           with Not_found -> raise (Error enonexist));
    Dev.stat = (fun c -> if c.qid.typ = Qt_dir then Dev.mkdir c "#s" root 0 0o777 else dir_of c (lookup c.qid.path));
    Dev.dirs = (fun c -> List.map (dir_of c) !srvs);
    Dev.open_ = (fun c m ->
      if c.qid.typ = Qt_dir then Dev.tab_open c m
      else begin
        let s = lookup c.qid.path in
        match s.schan with
        | None -> raise (Error "device shut down")
        | Some sc ->
            if m.trunc then raise (Error "srv file already exists");
            (match sc.opened with
             | Some sm when sm.access <> m.access && sm.access <> Ordwr -> raise (Error eperm)
             | _ -> ());
            Chan.incref sc;
            sc
      end);
    Dev.create = (fun c name _ perm ->
      if List.exists (fun s -> s.sname = name) !srvs then raise (Error eexist);
      incr last_path;
      let s = { sname = name; spath = !last_path; sperm = perm land 0o777; sowner = !Dev.eve; schan = None } in
      srvs := s :: !srvs;
      c.qid <- { path = s.spath; vers = 0; typ = Qt_file });
    Dev.write = (fun c buf _ ->
      let s = lookup c.qid.path in
      let fd = try int_of_string (String.trim buf) with Failure _ -> raise (Error ebadarg) in
      if s.schan <> None then raise (Error ebadusefd);
      let sc = Chan.fdtochan (Proc.myproc ()) fd None in
      if sc == c then raise (Error "can't post #s file");
      Chan.incref sc;
      s.schan <- Some sc;
      String.length buf);
    Dev.remove = remove;
    Dev.close = (fun c -> match c.opened with Some m when m.rclose -> (try remove c with Error _ -> ()) | _ -> ());
  }
