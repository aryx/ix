(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Save.mli *)

type who = { name : string; email : string }
type commit = { author : who; committer : who; msg : string; date : int; parents : Hash.t list }

exception Error of string

let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

type dirent = { mutable name : string option; mutable mode : Object.mode; mutable hash : Hash.t; fresh : bool }

let save (r : Repo.t) c paths =
  let st = r.store in
  let root = Fpath.to_string r.root in
  let index = match Index9.read st.caps st.git with
    | Some es -> es
    | None -> error "open index: .git/INDEX9 does not exist"
    | exception Index9.Corrupt n -> error ".git/INDEX9:%d: corrupt index" n in
  (* a path's last line decides *)
  let states = Hashtbl.create 64 in
  List.iter (fun (e : Index9.entry) -> Hashtbl.replace states e.path e.state) index;
  let tracked p = match Hashtbl.find_opt states p with Some s -> s <> Index9.Removed | None -> false in
  let write o = Store.write st o in
  let rec treeify (tree : Object.entry list) paths off =
    let ents = ref (List.map (fun (e : Object.entry) -> { name = Some e.name; mode = e.mode; hash = e.hash; fresh = false }) tree) in
    let dirent name =
      match List.find_opt (fun d -> d.name = Some name) !ents with
      | Some d -> d
      | None -> let d = { name = Some name; mode = File; hash = Hash.zero; fresh = true } in ents := !ents @ [ d ]; d in
    let rec loop = function
      | [] -> ()
      | s :: _ as all ->
          let ne = match String.index_from_opt s off '/' with Some i -> i - off | None -> String.length s - off in
          let prefix = String.sub s 0 (off + ne) in
          let slash = off + ne < String.length s in
          (* the path, and the paths below the same element *)
          let rec group acc = function
            | p :: rest when slash && String.starts_with ~prefix p
                             && (String.length p = off + ne || p.[off + ne] = '/') -> group (p :: acc) rest
            | rest -> List.rev acc, rest in
          let mine, rest = match all with p :: rest -> let g, rest = group [ p ] rest in g, rest | [] -> [], [] in
          let d = try Some (Unix.stat (Filename.concat root prefix)) with Unix.Unix_error _ -> None in
          let e = dirent (String.sub s off ne) in
          if e.mode = Link then error "symlinks may not be modified: %s" prefix;
          if e.mode = Submodule then error "submodules may not be modified: %s" prefix;
          let isdir = match d with Some d -> d.st_kind = S_DIR | None -> false in
          (if d = None || (not slash && isdir && tracked prefix) then e.name <- None
           else if slash && isdir then begin
             let sub = match Store.read st e.hash with Tree es -> es | _ -> [] | exception Store.Missing _ -> [] in
             e.mode <- Dir;
             let n, h = treeify sub mine (off + ne + 1) in
             e.hash <- h;
             if n = 0 then e.name <- None
           end
           else if (not slash) && not isdir then begin
             if tracked prefix then begin
               let data = In_channel.with_open_bin (Filename.concat root prefix) In_channel.input_all in
               e.mode <- (if (Option.get d).st_perm land 0o100 <> 0 then Exec else File);
               e.hash <- write (Blob data)
             end
             else e.name <- None
           end
           (* claude: git9 leaves an entry it has just made here (an
            * untracked directory, or a file on the way to a path) with
            * a zero hash; such an entry is dropped *)
           else if e.fresh then e.name <- None);
          loop rest
    in
    loop paths;
    if !ents = [] then error "%s: refusing to update empty directory" (String.sub (List.hd paths) 0 off);
    let es = List.filter_map (fun d -> Option.map (fun name -> { Object.mode = d.mode; name; hash = d.hash }) d.name) !ents in
    let es = List.sort Object.compare_entries es in
    List.length es, write (Tree es)
  in
  let head_tree =
    match Refs.read st "HEAD" with
    | None -> []
    | Some h -> (
        match Store.read st h with
        | Commit cm -> (match Store.read st cm.tree with Tree es -> es | _ -> error "could not read tree for commit %s" (Hash.to_hex h))
        | _ -> error "could not read HEAD %s" (Hash.to_hex h)
        | exception Store.Missing _ -> []) in
  let paths = List.sort_uniq compare (List.filter (fun p -> p <> "" && p <> ".") paths) in
  let _, tree = treeify head_tree paths 0 in
  let person (w : who) = { Object.id = Printf.sprintf "%s <%s>" w.name w.email; time = c.date; tz = "+0000" } in
  write (Commit { tree; parents = c.parents; author = person c.author; committer = person c.committer; extra = ""; msg = c.msg })
