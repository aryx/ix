(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Walk.mli *)

type change = Removed | Modified | Added | Untracked | Tracked

type opts = { show : change list; quiet : bool; bare : bool; base : Hash.t option; invalidate : bool; rel : string option; paths : string list }

let default = { show = []; quiet = false; bare = false; base = None; invalidate = false; rel = None; paths = [] }

exception Error of string

let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

let letter = function Removed -> 'R' | Modified -> 'M' | Added -> 'A' | Untracked -> 'U' | Tracked -> 'T'

type ent = { mutable state : Index9.state; mutable qid : Index9.qid; mutable mode : int; path : string; order : int }

(* the commit's side: git9 reads it through git/fs, .git/fs/HEAD/tree *)
type node = File of Object.entry | Dir of Hash.t

let lookup (st : Store.t) root path =
  let rec go h = function
    | [] -> Some (Dir h)
    | name :: rest -> (
        match Store.read st h with
        | Tree es -> (
            match List.find_opt (fun (e : Object.entry) -> e.name = name) es, rest with
            | Some ({ mode = Dir; _ } as e), _ -> go e.hash rest
            | Some { mode = Submodule; _ }, [] -> Some (Dir Query.empty_tree)
            | Some e, [] -> Some (File e)
            | _ -> None)
        | _ -> None) in
  go root (List.filter (fun s -> s <> "" && s <> ".") (String.split_on_char '/' path))

(* git9's pathcmp: a directory compares as if it ended with '/', and a
 * path below it is equal to it *)
let pathcmp a b adir =
  let la = String.length a and lb = String.length b in
  let rec go i =
    let ca = if i < la then Char.code a.[i] else 0 and cb = if i < lb then Char.code b.[i] else 0 in
    if ca <> cb then
      let ca = if ca = 0 && adir then Char.code '/' else ca in
      if ca = Char.code '/' && cb = Char.code '/' then 0 else if ca > cb then 1 else -1
    else if ca = 0 then 0
    else go (i + 1) in
  go 0

let run (r : Repo.t) o =
  let st = r.store in
  let printflg = if o.show = [] then [ Tracked; Added; Modified; Removed ] else o.show in
  let root = Fpath.to_string r.root in
  let gitdirmode = (Unix.stat (Fpath.to_string st.git)).st_perm land 0o777 in
  let fsmode (e : Object.entry) =
    match e.mode with
    | Exec -> gitdirmode
    | File | Link -> gitdirmode land 0o666
    | Dir | Submodule -> gitdirmode in
  let base_tree =
    let commit h = match Store.read st h with Commit c -> Some c.tree | _ -> None in
    match o.base with
    | Some h -> (match commit h with Some t -> Some t | None -> error "no such ref '%s'" (Hash.to_hex h))
    | None -> Option.bind (Refs.read st "HEAD") (fun h -> if Store.mem st h then commit h else None) in
  let in_tree path = match base_tree with None -> None | Some t -> lookup st t path in
  let isindexed = o.base = None in
  let staleidx = ref o.invalidate in
  let nslash, relapath =
    match o.rel with
    | None -> 0, ""
    | Some rel ->
        let p = Repo.cleanname rel in
        if p = "." then 0, ""
        else if p = ".." || String.starts_with ~prefix:"../" p then error "relative path escapes git root"
        else let rp = p ^ "/" in 0 + List.length (List.filter (( = ) '/') (List.of_seq (String.to_seq rp))), rp in
  let args = List.map (fun p -> if p = "." then "" else p) o.paths in
  let pfxmatch p =
    args = [] || List.exists (fun pfx ->
      pfx = "" || pfx = "." || (String.starts_with ~prefix:pfx p
        && (String.length p = String.length pfx || p.[String.length pfx] = '/'))) args in
  (* the index *)
  let from_index =
    if isindexed && not !staleidx then
      match (try Index9.read st.caps st.git with Index9.Corrupt n -> error ".git/INDEX9:%d: corrupt index" n) with
      | Some es -> Some (List.map (fun (e : Index9.entry) -> { state = e.state; qid = e.qid; mode = e.mode; path = e.path; order = e.order }) es)
      | None -> staleidx := true; None
    else None in
  let cleanidx = from_index = None in
  let idx =
    match from_index with
    | Some es -> es
    | None ->
        let t = match base_tree with Some t -> t | None -> error "chdir: %s: no tree" (if o.base = None then ".git/fs/HEAD/tree" else "base") in
        let acc = ref [] and n = ref 0 in
        let rec files prefix h =
          match Store.read st h with
          | Tree es -> List.iter (fun (e : Object.entry) ->
              let p = if prefix = "" then e.name else prefix ^ "/" ^ e.name in
              match e.mode with
              | Dir -> files p e.hash
              | Submodule -> ()
              | _ -> acc := { state = Tracked; qid = Noqid; mode = fsmode e; path = p; order = !n } :: !acc; incr n) es
          | _ -> () in
        let load p =
          match lookup st t p with
          | Some (Dir h) -> files (if p = "" || p = "." then "" else p) h
          | Some (File e) -> acc := { state = Tracked; qid = Noqid; mode = fsmode e; path = p; order = !n } :: !acc; incr n
          | None -> () in
        if !staleidx || args = [] then load "" else List.iter load args;
        List.rev !acc
  in
  let idx = Array.of_list (List.stable_sort (fun a b -> match compare a.path b.path with 0 -> compare a.order b.order | c -> c) idx) in
  let nidx = Array.length idx in
  let indexed path dir =
    let rec search lo hi r =
      if lo > hi then r = 0
      else
        let mid = (lo + hi) / 2 in
        let r = pathcmp path idx.(mid).path dir in
        if r < 0 then search lo (mid - 1) r else if r > 0 then search (mid + 1) hi r else true in
    search 0 (nidx - 1) (-1) in
  (* the disk *)
  let untracked = List.mem Untracked printflg in
  let wdir = ref [] and nw = ref 0 in
  let rec loadwdir path =
    let path = Repo.cleanname path in
    if path = ".git" || String.starts_with ~prefix:".git/" path then ()
    else
      match Unix.stat (Filename.concat root path) with
      | exception Unix.Unix_error _ -> ()
      | s when s.st_kind = S_DIR ->
          (match Sys.readdir (Filename.concat root path) with
           | names -> Array.iter (fun n -> loadent (path ^ "/" ^ n)) names
           | exception Sys_error _ -> ())
      | _ -> loadent path
  and loadent path =
    let path = Repo.cleanname path in
    match Unix.stat (Filename.concat root path) with
    | exception Unix.Unix_error _ -> ()
    | s ->
        if untracked || indexed path (s.st_kind = S_DIR) then
          if s.st_kind = S_DIR then loadwdir path else add path s
  and add path (s : Unix.stats) =
    wdir := { state = Tracked; qid = Index9.qid_of_stats s; mode = s.st_perm land 0o777; path; order = !nw } :: !wdir;
    incr nw in
  if args = [] then loadwdir "." else List.iter (fun a -> loadwdir (if a = "" then "." else a)) args;
  let wdir = Array.of_list (List.stable_sort (fun a b -> match compare a.path b.path with 0 -> compare a.order b.order | c -> c) !wdir) in
  let nwdir = Array.length wdir in
  (* checkedin: in the commit; with a clean index, an index entry not
   * removed (a disk entry never is: git9 compares the pointer) *)
  let checkedin ~from_idx (e : ent) change =
    if cleanidx then from_idx && e.state <> Removed
    else
      (* claude: a file of the commit; git9 tests the path with access(),
       * which a directory passes too: an index line left for a file that
       * became a directory then reads as its removal, and the next commit
       * drops the directory (plan_vcs.md, deliberate difference 6) *)
      let r = match in_tree e.path with Some (File _) -> true | _ -> false in
      if r && change then begin
        if e.state <> Removed then e.state <- Tracked;
        staleidx := true
      end;
      r in
  let now = Unix.gettimeofday () in
  let samedata (a : ent option) (b : ent) =
    match a with
    | Some a when a.qid = b.qid && a.qid <> Noqid && a.mode = b.mode && a.mode <> 0 -> true
    | _ -> (
        match in_tree b.path with
        | Some (File te) when te.mode <> Submodule -> (
            let disk = Filename.concat root b.path in
            match Store.read st te.hash with
            | Blob data ->
                let tx = fsmode te land 0o100 <> 0 and dx = b.mode land 0o100 <> 0 in
                let same = tx = dx && (try In_channel.with_open_bin disk In_channel.input_all = data with Sys_error _ -> false) in
                if same then Option.iter (fun (a : ent) ->
                  let recent = (Unix.stat disk).st_mtime >= now -. 2. in
                  a.qid <- (if recent then Noqid else b.qid);
                  a.mode <- b.mode;
                  staleidx := true) a;
                same
            | _ -> false)
        | _ -> false) in
  let out = ref [] and dirty = ref [] in
  let show flg path =
    if not (List.mem flg !dirty) then dirty := flg :: !dirty;
    if not o.quiet && List.mem flg printflg then begin
      let path = ref path and n = ref nslash in
      if !n > 0 then begin
        let i = ref 0 and p = !path in
        (try while !i < String.length relapath && !i < String.length p do
              if relapath.[!i] <> p.[!i] then raise Exit;
              if relapath.[!i] = '/' then (decr n; path := String.sub p (!i + 1) (String.length p - !i - 1));
              incr i done with Exit -> ())
      end;
      let prefix = if o.bare then "" else String.make 1 (letter flg) ^ " " in
      out := (prefix ^ String.concat "" (List.init (max 0 !n) (fun _ -> "../")) ^ !path) :: !out
    end in
  let i = ref 0 and j = ref 0 in
  while !i < nidx || !j < nwdir do
    while !i + 1 < nidx && idx.(!i).path = idx.(!i + 1).path do staleidx := true; incr i done;
    while !j + 1 < nwdir && wdir.(!j).path = wdir.(!j + 1).path do incr j done;
    if !i < nidx && not (pfxmatch idx.(!i).path) then incr i
    else begin
      let c = if !i >= nidx then 1 else if !j >= nwdir then -1 else compare idx.(!i).path wdir.(!j).path in
      if c = 0 then begin
        let e = idx.(!i) in
        (if e.state = Removed then
           (if checkedin ~from_idx:true e false then show Removed e.path else (e.state <- Untracked; staleidx := true))
         else if e.state = Added && not (checkedin ~from_idx:true e true) then show Added e.path
         else if not (samedata (Some e) wdir.(!j)) then show Modified e.path
         else show Tracked e.path);
        incr i; incr j
      end
      else if c < 0 then begin
        let e = idx.(!i) in
        if checkedin ~from_idx:true e false then show Removed e.path else (e.state <- Untracked; staleidx := true);
        incr i
      end
      else begin
        let w = wdir.(!j) in
        if checkedin ~from_idx:false w false then (if samedata None w then show Tracked w.path else show Modified w.path)
        else if untracked && pfxmatch w.path then show Untracked w.path;
        incr j
      end
    end
  done;
  if isindexed && !staleidx then
    Index9.write st.caps st.git
      (Array.to_list (Array.map (fun (e : ent) -> { Index9.state = e.state; qid = e.qid; mode = e.mode; path = e.path; order = e.order }) idx));
  List.rev !out, List.filter (fun c -> List.mem c !dirty) [ Removed; Modified; Added; Untracked ]
