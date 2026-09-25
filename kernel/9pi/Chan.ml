(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Chan.mli *)

open Types

let mode_of_int m =
  if m land lnot (16 lor 32 lor 64 lor 3) <> 0 then raise (Error ebadarg);
  { access = (match m land 3 with 0 -> Oread | 1 -> Owrite | 2 -> Ordwr | _ -> Oexec);
    trunc = m land 16 <> 0; cexec = m land 32 <> 0; rclose = m land 64 <> 0 }

(* a path's elements, each with the offset of its end in the path ("."
 * and empty ones dropped) *)
let elements path start =
  let n = String.length path in
  let rec go i acc =
    if i >= n then List.rev acc
    else
      let j = try String.index_from path i '/' with Not_found -> n in
      let e = String.sub path i (j - i) in
      go (j + 1) (if e = "" || e = "." then acc else (e, j) :: acc) in
  go start []

let clone c = { dev = c.dev; qid = c.qid; offset = 0; opened = None; cname = c.cname }

let namec (p : proc) path =
  if path = "" then nameerror path enonexist;
  let base, start =
    match path.[0] with
    | '/' -> p.slash, 1
    | '#' ->
        if String.length path < 2 then raise (Error ebadsharp);
        let j = try String.index_from path 2 '/' with Not_found -> String.length path in
        (Dev.find path.[1]).Dev.attach (String.sub path 2 (j - 2)), j
    | _ -> p.dot, 0 in
  let d = Dev.find base.dev in
  List.fold_left
    (fun c (e, stop) ->
      let q = try d.Dev.walk c e with Error err -> nameerror (String.sub path 0 stop) err in
      c.qid <- q;
      c.cname <- (if c.cname = "/" then "/" ^ e else c.cname ^ "/" ^ e);
      c)
    (clone base) (elements path start)

let open_ c m =
  (Dev.find c.dev).Dev.open_ c m;
  c.opened <- Some m;
  c.offset <- 0

let close c = if c.opened <> None then (Dev.find c.dev).Dev.close c

let fdalloc (p : proc) c =
  let fds = p.fgrp.fds in
  let rec go fd =
    if fd = Array.length fds then raise (Error enofd)
    else match fds.(fd) with None -> fds.(fd) <- Some c; fd | Some _ -> go (fd + 1) in
  go 0

let fdtochan (p : proc) fd access =
  let fds = p.fgrp.fds in
  if fd < 0 || fd >= Array.length fds then raise (Error ebadfd);
  match fds.(fd) with
  | None -> raise (Error ebadfd)
  | Some c ->
      (match access, c.opened with
       | None, _ -> ()
       | Some _, None -> raise (Error ebadusefd)
       | Some a, Some m ->
           let a = if a = Oexec then Oread else a and has = if m.access = Oexec then Oread else m.access in
           if a <> has && has <> Ordwr then raise (Error ebadusefd));
      c

let basename path = try let i = String.rindex path '/' in String.sub path (i + 1) (String.length path - i - 1) with Not_found -> path
