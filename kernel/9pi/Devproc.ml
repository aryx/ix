(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devproc.mli *)

open Types

(* procdir, in its order *)
let files = [ "args", 0o660; "ctl", 0o000; "fd", 0o444; "fpregs", 0o000; "kregs", 0o400; "mem", 0o000;
              "note", 0o000; "noteid", 0o664; "notepg", 0o000; "ns", 0o444; "proc", 0o400; "regs", 0o000;
              "segment", 0o444; "status", 0o444; "text", 0o000; "wait", 0o400; "profile", 0o400; "syscall", 0o400 ]

let knamelen = 28
let numsize = 12
let statsize = (2 * knamelen) + 12 + (9 * 12)

(* the qids: a process's directory pid*32, its files pid*32 + i + 1 *)
let root = { path = 0; vers = 0; typ = Qt_dir }

let procs () = List.fold_right (fun o acc -> match o with Some p when p.state <> Zombie -> p :: acc | _ -> acc)
                 (Array.to_list Proc.procs) []

let find pid = try List.find (fun p -> p.pid = pid) (procs ()) with Not_found -> raise (Error "process exited")

let entries path =
  if path = 0 then
    List.map (fun p -> { Dev.dname = string_of_int p.pid; Dev.dqid = { path = p.pid * 32; vers = p.pid; typ = Qt_dir };
                         Dev.dlength = 0; Dev.dperm = 0o555 }) (procs ())
  else if path land 31 = 0 then begin
    let pid = path / 32 in
    ignore (find pid);
    let rec go i l = match l with
      | [] -> []
      | (name, perm) :: r ->
          { Dev.dname = name; Dev.dqid = { path = (pid * 32) + i + 1; vers = pid; typ = Qt_file };
            Dev.dlength = (if name = "status" then statsize else 0); Dev.dperm = perm } :: go (i + 1) r in
    go 0 files
  end
  else raise (Error enotdir)

let parent path = if path land 31 = 0 then root else { path = path land lnot 31; vers = path / 32; typ = Qt_dir }

let name_of path = fst (List.nth files ((path land 31) - 1))

let readstr off n s = if off >= String.length s then "" else String.sub s off (min n (String.length s - off))
let field w s = let s = if String.length s > w then String.sub s 0 w else s in s ^ String.make (w - String.length s) ' '
let num v = let s = string_of_int v in String.make (max 0 (numsize - 1 - String.length s)) ' ' ^ s ^ " "

let status p =
  let st = if p.psstate <> "" then p.psstate
    else match p.state with Running -> "Running" | Runnable -> "Ready" | Sleeping _ -> "Wakeme" | Zombie -> "Moribund" in
  (* the segments but the stack ("mostly non-existent") *)
  let mem = List.fold_left (fun n s -> if s.kind = Stack then n else n + (s.top - s.base)) 0 p.segs in
  field knamelen p.text ^ field knamelen !Dev.eve ^ field 12 st
  ^ num 0 ^ num 0 ^ num ((!Proc.ticks - p.start) * 10) ^ num 0 ^ num 0 ^ num (mem / 1024) ^ num 10 ^ num 10
  ^ String.make (statsize - (2 * knamelen) - 12 - (8 * numsize)) ' '

(* %.Nx: hex, zero-padded to w digits *)
let hex w v = let s = Printf.sprintf "%x" v in String.make (max 0 (w - String.length s)) '0' ^ s

let segment p =
  String.concat "" (List.map (fun s ->
    let name = match s.kind with Text -> "Text" | Data -> "Data" | Bss -> "Bss" | Stack -> "Stack" in
    Printf.sprintf "%-6s %c %s %s %4d\n" name (if s.kind = Text then 'R' else ' ') (hex 8 s.base) (hex 8 s.top) 1) p.segs)

let fds p =
  let b = Buffer.create 256 in
  Buffer.add_string b (p.dot.cname ^ "\n");
  Array.iteri (fun i o -> match o with
    | Some c ->
        let m = match c.opened with Some { access = Oread } -> 'r' | Some { access = Owrite } -> 'w' | _ -> 'R' in
        Buffer.add_string b (Printf.sprintf "%3d %c %c %4d (%s %5d %s) %5d %8d %s\n" i m c.dev c.devno
                               (hex 16 c.qid.path) c.qid.vers (hex 2 (if c.qid.typ = Qt_dir then 0x80 else 0)) 8192
                               c.offset c.cname)
    | None -> ()) p.fgrp.fds;
  Buffer.contents b

let ns p =
  String.concat "" (List.concat (List.map (fun h ->
    List.map (fun m -> Printf.sprintf "bind %s%s %s\n" (if m.mcreate then "-c " else "") m.mchan.cname h.mpt.cname) h.members)
    p.pgrp.mnt)) ^ "cd " ^ p.dot.cname ^ "\n"

let init () =
  let d = Dev.default 'p' "proc" in
  Dev.register { d with
    Dev.attach = (fun _ -> Dev.attach 'p' 0 root);
    Dev.walk = (fun c nc name ->
      if c.qid.path = 0 && name <> ".." then begin
        (* a pid, even one not listed yet *)
        let pid = try int_of_string name with Failure _ -> raise (Error enonexist) in
        ignore (find pid);
        { path = pid * 32; vers = pid; typ = Qt_dir }
      end
      else Dev.tab_walk entries parent c nc name);
    Dev.stat = Dev.tab_stat "#p" entries parent;
    Dev.dirs = Dev.tab_dirs entries;
    Dev.open_ = Dev.tab_open;
    Dev.read = (fun c n off ->
      let p = find (c.qid.path / 32) in
      match name_of c.qid.path with
      | "status" -> readstr off n (status p)
      | "args" -> readstr off n p.args
      | "fd" -> readstr off n (fds p)
      | "ns" -> readstr off n (ns p)
      | "noteid" -> readstr off n (num p.noteid)
      | "segment" -> readstr off n (segment p)
      | _ -> raise (Error eperm));
    Dev.write = (fun c s _ ->
      let p = find (c.qid.path / 32) in
      (match name_of c.qid.path with
       | "ctl" ->
           if s = "kill" || s = "kill\n" then ignore (Proc.postnote p "sys: killed" Nexit)
           else raise (Error ebadctl)
       | "note" -> ignore (Proc.postnote p s Nuser)
       | "notepg" ->
           List.iter (fun q -> if q.noteid = p.noteid then ignore (Proc.postnote q s Nuser)) (procs ())
       | _ -> raise (Error eperm));
      String.length s);
  }
