(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devenv.mli *)

open Types

let maxenvsize = 16300

(* the configuration, '#ec': devno 1 *)
let conf = { vars = []; last_path = 0 }

let egrp (c : chan) = if c.devno = 1 then conf else (Proc.myproc ()).egrp

let root = { path = 0; vers = 0; typ = Qt_dir }

let lookup eg path =
  try List.find (fun e -> e.epath = path) eg.vars with Not_found -> raise (Error enonexist)

(* an entry: devdir's, the device number 0 (#ec's too, as devattach) *)
let dir_of c e =
  let d = Dev.mkdir c e.ename { path = e.epath; vers = e.evers; typ = Qt_file } (String.length e.evalue) 0o666 in
  { d with d_dev = 0 }

let copy (eg : egrp) =
  { vars = List.map (fun e -> { ename = e.ename; evalue = e.evalue; epath = e.epath; evers = e.evers }) eg.vars;
    last_path = eg.last_path }

(* envremove: the last variable takes the removed one's place *)
let remove (c : chan) =
  if c.qid.typ = Qt_dir then raise (Error eperm);
  let eg = egrp c in
  let e = lookup eg c.qid.path in
  let rec replace l = match l with
    | [] -> []
    | x :: r -> if x == e then (match List.rev r with [] -> [] | last :: rest_rev -> last :: List.rev rest_rev) else x :: replace r in
  eg.vars <- replace eg.vars

let init () =
  let d = Dev.default 'e' "env" in
  Dev.register { d with
    Dev.attach = (fun spec ->
      if spec <> "" && spec <> "c" then raise (Error ebadarg);
      let c = Dev.attach 'e' (if spec = "c" then 1 else 0) root in
      c.cname <- "#e" ^ spec;
      c);
    Dev.walk = (fun c nc name ->
      if c.qid.typ <> Qt_dir then raise (Error enotdir)
      else if name = ".." then root
      else
        try let e = List.find (fun e -> e.ename = name) (egrp c).vars in { path = e.epath; vers = e.evers; typ = Qt_file }
        with Not_found -> raise (Error enonexist));
    Dev.stat = (fun c ->
      if c.qid.typ = Qt_dir then { (Dev.mkdir c "#e" root 0 0o775) with d_dev = 0 } else dir_of c (lookup (egrp c) c.qid.path));
    Dev.dirs = (fun c -> List.map (dir_of c) (egrp c).vars);
    Dev.open_ = (fun c m ->
      if c.qid.typ = Qt_dir then begin if m.access <> Oread then raise (Error eperm) end
      else begin
        let e = lookup (egrp c) c.qid.path in
        if m.access <> Oread && c.devno = 1 then raise (Error eperm);
        if m.trunc && e.evalue <> "" then begin e.evers <- e.evers + 1; e.evalue <- "" end
      end;
      c);
    Dev.create = (fun c name _ _ ->
      if c.qid.typ <> Qt_dir then raise (Error eperm);
      let eg = egrp c in
      if List.exists (fun e -> e.ename = name) eg.vars then raise (Error eexist);
      eg.last_path <- eg.last_path + 1;
      let e = { ename = name; evalue = ""; epath = eg.last_path; evers = 0 } in
      eg.vars <- eg.vars @ [ e ];
      c.qid <- { path = e.epath; vers = 0; typ = Qt_file });
    Dev.read = (fun c n off ->
      let e = lookup (egrp c) c.qid.path in
      if off >= String.length e.evalue then "" else String.sub e.evalue off (min n (String.length e.evalue - off)));
    Dev.write = (fun c s off ->
      let n = String.length s in
      if n = 0 then 0
      else begin
        if off > maxenvsize || n > maxenvsize - off then raise (Error "read or write too large");
        let e = lookup (egrp c) c.qid.path in
        let v = e.evalue in
        let len = max (String.length v) (off + n) in
        let nv = String.make len '\000' in
        String.blit v 0 nv 0 (String.length v);
        String.blit s 0 nv off n;
        e.evalue <- nv;
        e.evers <- e.evers + 1;
        n
      end);
    Dev.remove = remove;
    Dev.close = (fun c ->
      match c.opened with Some m when m.rclose -> (try remove c with Error _ -> ()) | _ -> ());
  }
