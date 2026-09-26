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

let mrepl = 0
let mbefore = 1
let mafter = 2
let mcreate = 4

let mode_of_int m =
  if m land lnot (16 lor 32 lor 64 lor 3) <> 0 then raise (Error ebadarg);
  { access = (match m land 3 with 0 -> Oread | 1 -> Owrite | 2 -> Ordwr | _ -> Oexec);
    trunc = m land 16 <> 0; cexec = m land 32 <> 0; rclose = m land 64 <> 0 }

(* a copy of the channel's fields (the same fid: see clone) *)
let copy c =
  { dev = c.dev; devno = c.devno; qid = c.qid; offset = 0; opened = None; cname = c.cname; umh = []; dri = 0;
    cref = 1; fid = c.fid }

(* a copy that is a file of its own (devmnt: a new fid) *)
let clone c = let nc = copy c in (Dev.find c.dev).Dev.clone c nc; nc

(* an unopened channel no one holds *)
let clunk c = if c.opened = None then (Dev.find c.dev).Dev.clunk c

let same a b = a.dev = b.dev && a.devno = b.devno && a.qid.path = b.qid.path

(*****************************************************************************)
(* Walking *)
(*****************************************************************************)

(* cleanname: "." and empty elements gone, ".." removing its parent
 * (at the root: the root) *)
let cleanname path =
  let rec go acc l =
    match l with
    | [] -> List.rev acc
    | ("" | ".") :: r -> go acc r
    | ".." :: r -> go (match acc with [] -> [] | _ :: a -> a) r
    | e :: r -> go (e :: acc) r in
  go [] (String.split_on_char '/' path)

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

let findmount (pg : pgrp) c = try Some (List.find (fun h -> same h.mpt c) pg.mnt) with Not_found -> None

(* a mount point replaced by its union's first member, the union kept
 * (the mount point's channel, the walk's own, dropped) *)
let domount (pg : pgrp) c =
  match findmount pg c with
  | Some { members = m :: _ as members } ->
      let nc = clone m.mchan in
      nc.cname <- c.cname;
      nc.umh <- members;
      clunk c;
      nc
  | _ -> c

let join name e = if name = "/" then "/" ^ e else name ^ "/" ^ e

(* one step: the union's members tried in order (the last one's error,
 * as walk's ewalks leave it) *)
let step c e =
  let members = match c.umh with [] -> [ c ] | ms -> List.map (fun m -> m.mchan) ms in
  let rec try_ ms last_err =
    match ms with
    | [] -> raise (Error (match last_err with Some e -> e | None -> enonexist))
    | m :: rest ->
        (try
          let nc = copy m in
          nc.qid <- (Dev.find m.dev).Dev.walk m nc e;
          nc.cname <- join c.cname e;
          nc
        with Error err -> try_ rest (Some err)) in
  try_ members None

(* walk's error when a name is missing past a batch's first *)
let doesnotexist = "does not exist"

(* the lexical parent of a name ("/" its own) *)
let parent name =
  match cleanname name with
  | [] -> "/"
  | es -> "/" ^ String.concat "/" (List.rev (List.tl (List.rev es)))

(* A path's names walked as 9pi's walk does: in batches, from a mount
 * point to the next (a server's walk takes a batch at once); a name
 * missing at a batch's first tried in the union's other members (the
 * last's error), further in "does not exist"; the error naming the path
 * as given, up to that name. ".." is lexical (the channel's name's
 * parent, walked again). A "#" path crosses no mount point. *)
let rec walk (p : proc) path nomount =
  if path = "" then nameerror path enonexist;
  let pg = p.pgrp in
  let sharp = path.[0] = '#' in
  let base, start =
    match path.[0] with
    | '/' -> p.slash, 1
    | '#' ->
        if String.length path < 2 then raise (Error ebadsharp);
        (* the letter a rune (UTF-8: '#Ι', 2 bytes) *)
        let b = Char.code path.[1] in
        let r, k =
          if b < 0x80 then b, 1
          else if b land 0xe0 = 0xc0 && String.length path > 2 then ((b land 0x1f) lsl 6) lor (Char.code path.[2] land 0x3f), 2
          else raise (Error ebadsharp) in
        let s = 1 + k in
        (* index_from wants a start inside the string (1.07) *)
        let j = if String.length path = s then s else try String.index_from path s '/' with Not_found -> String.length path in
        (Dev.find_rune r).Dev.attach (String.sub path s (j - s)), j
    | _ -> p.dot, 0 in
  let elems = elements path start in
  let n = List.length elems in
  let mount c = if sharp then c else domount pg c in
  (* batch: c the batch's start (its next name the first) *)
  let rec go c i batch l =
    match l with
    | [] -> c
    | ("..", _) :: rest ->
        let nc = if String.length c.cname > 0 && c.cname.[0] = '/' then walk p (parent c.cname) false else step c ".." in
        clunk c;
        go nc (i + 1) true rest
    | (e, stop) :: rest ->
        let nc =
          try step c e
          with Error err ->
            clunk c;
            nameerror (String.sub path 0 stop) (if c.qid.typ <> Qt_dir then enotdir else if batch then err else doesnotexist) in
        clunk c;
        if i = n - 1 && nomount then nc
        else begin
          let mc = mount nc in
          go mc (i + 1) (mc != nc) rest
        end in
  let c = clone base in
  c.umh <- base.umh;
  go (if n = 0 && nomount then c else mount c) 0 true elems

(* an error of namec's after the walk (the open, the create) named with
 * the whole path, unless it has no names ("/", "#c") *)
let named path f =
  let start = if path <> "" && path.[0] = '#' then (try String.index path '/' with Not_found -> String.length path) else 0 in
  try f () with Error e when elements path start <> [] -> nameerror path e

let namec p path = walk p path false
let namec_nomount p path = walk p path true

(*****************************************************************************)
(* Open, create *)
(*****************************************************************************)

(* a channel the device gives back (#d's, #s's) is already open: kept
 * as it is *)
let open_ c m =
  let nc = (Dev.find c.dev).Dev.open_ c m in
  if nc == c then begin
    c.opened <- Some m;
    c.offset <- 0;
    c.dri <- 0
  end;
  nc

let incref c = c.cref <- c.cref + 1

let close c =
  c.cref <- c.cref - 1;
  if c.cref = 0 && c.opened <> None then (Dev.find c.dev).Dev.close c

let dirs c =
  match c.umh with
  | [] -> (Dev.find c.dev).Dev.dirs c
  | ms -> List.concat (List.map (fun m -> (Dev.find m.mchan.dev).Dev.dirs m.mchan) ms)

let split path =
  let path = if String.length path > 1 && path.[String.length path - 1] = '/' then String.sub path 0 (String.length path - 1) else path in
  try
    let i = String.rindex path '/' in
    (if i = 0 then "/" else String.sub path 0 i), String.sub path (i + 1) (String.length path - i - 1)
  with Not_found -> ".", path

let rec create (p : proc) path m perm =
  let exists = try Some (namec p path) with Error _ -> None in
  match exists with
  | Some c -> named path (fun () -> open_ c { m with trunc = true })
  | None -> named path (fun () -> create_new p path m perm)

and create_new p path m perm =
      match () with () ->
      let dirname, name = split path in
      if name = "" || name = "." || name = ".." then raise (Error eexist);
      let d = namec p dirname in
      let target =
        match d.umh with
        | [] -> d
        | ms ->
            (try let mc = (List.find (fun mm -> mm.mcreate) ms).mchan in let t = clone mc in t.cname <- d.cname; t
             with Not_found -> raise (Error enocreate)) in
      (Dev.find target.dev).Dev.create target name m perm;
      target.cname <- join d.cname name;
      target.opened <- Some m;
      target.offset <- 0;
      target

(*****************************************************************************)
(* The namespace *)
(*****************************************************************************)

let bind (pg : pgrp) newc old flag =
  if (newc.qid.typ = Qt_dir) <> (old.qid.typ = Qt_dir) then raise (Error "inconsistent mount");
  let m = { mchan = newc; mcreate = flag land mcreate <> 0 } in
  match findmount pg old with
  | None ->
      let members =
        if flag land 3 = mrepl then [ m ]
        else if flag land 3 = mbefore then [ m; { mchan = old; mcreate = false } ]
        else [ { mchan = old; mcreate = false }; m ] in
      pg.mnt <- pg.mnt @ [ { mpt = old; members = members } ]
  | Some h ->
      h.members <-
        (if flag land 3 = mrepl then [ m ] else if flag land 3 = mbefore then m :: h.members else h.members @ [ m ])

let unmount (pg : pgrp) newc old =
  match findmount pg old with
  | None -> raise (Error eunmount)
  | Some h ->
      (match newc with
       | None -> pg.mnt <- List.filter (fun x -> x != h) pg.mnt
       | Some nc ->
           if not (List.exists (fun m -> same m.mchan nc) h.members) then raise (Error eunmount);
           h.members <- List.filter (fun m -> not (same m.mchan nc)) h.members;
           if h.members = [] then pg.mnt <- List.filter (fun x -> x != h) pg.mnt)

let pgrp_copy (pg : pgrp) = { mnt = List.map (fun h -> { mpt = h.mpt; members = h.members }) pg.mnt }

(*****************************************************************************)
(* The descriptors *)
(*****************************************************************************)

let nfd = 100

let fdalloc (p : proc) c =
  let fds = p.fgrp.fds in
  let rec go fd =
    if fd = Array.length fds then raise (Error enofd)
    else match fds.(fd) with None -> fds.(fd) <- Some c; fd | Some _ -> go (fd + 1) in
  go 0

let fdalloc_at (p : proc) fd c =
  let fds = p.fgrp.fds in
  if fd < 0 || fd >= Array.length fds then raise (Error ebadfd);
  let old = fds.(fd) in
  fds.(fd) <- Some c;
  match old with Some o when o != c -> close o | _ -> ()

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

let fgrp_copy (f : fgrp) =
  Array.iter (fun o -> match o with Some c -> incref c | None -> ()) f.fds;
  { fds = Array.copy f.fds; fref = 1 }
let fgrp_new () = { fds = Array.make nfd None; fref = 1 }

let fgrp_close (f : fgrp) =
  f.fref <- f.fref - 1;
  if f.fref = 0 then
    Array.iteri (fun fd o -> match o with Some c -> f.fds.(fd) <- None; close c | None -> ()) f.fds

let basename path = try let i = String.rindex path '/' in String.sub path (i + 1) (String.length path - i - 1) with Not_found -> path
