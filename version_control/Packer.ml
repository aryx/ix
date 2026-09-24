(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Packer.mli *)

let murmurhash2 (s : string) =
  let m = 0x5bd1e995 and mask = 0xffffffff in
  let mul a b = (a * b) land mask in
  let n = String.length s in
  let h = ref ((2928213749 lxor n) land mask) in
  let byte i = Char.code s.[i] in
  let nw = n land (lnot 3) in
  let i = ref 0 in
  while !i < nw do
    let k = byte !i lor (byte (!i + 1) lsl 8) lor (byte (!i + 2) lsl 16) lor (byte (!i + 3) lsl 24) in
    let k = mul k m in
    let k = k lxor (k lsr 24) in
    let k = mul k m in
    h := mul !h m;
    h := !h lxor k;
    i := !i + 4
  done;
  (match n land 3 with
   | 3 -> h := !h lxor (byte (nw + 2) lsl 16) lxor (byte (nw + 1) lsl 8) lxor byte nw; h := mul !h m
   | 2 -> h := !h lxor (byte (nw + 1) lsl 8) lxor byte nw; h := mul !h m
   | 1 -> h := !h lxor byte nw; h := mul !h m
   | _ -> ());
  h := !h lxor (!h lsr 13);
  h := mul !h m;
  h := !h lxor (!h lsr 15);
  !h

type meta = {
  hash : Hash.t;
  kind : Object.Kind.t;
  path : int;
  mtime : int;
  mutable delta : (meta * Delta.t) option;
  mutable nchain : int;
  mutable head : meta option;
  mutable order : int;
}

let code : Object.Kind.t -> int = function Commit -> 1 | Tree -> 2 | Blob -> 3 | Tag -> 4

let pack (st : Store.t) ~heads ~have =
  let has = Hashtbl.create 1024 in
  let metas = ref [] in
  let add collect hash kind path mtime =
    if not (Hashtbl.mem has hash) then begin
      Hashtbl.add has hash ();
      if collect then metas := { hash; kind; path; mtime; delta = None; nchain = 0; head = None; order = 0 } :: !metas
    end in
  let rec loadtree collect h dpath mtime =
    if not (Hashtbl.mem has h) then
      match Store.read st h with
      | Tree es ->
          let dh = murmurhash2 dpath in
          add collect h Tree dh mtime;
          List.iter (fun (e : Object.entry) ->
            if not (Hashtbl.mem has e.hash) then
              match e.mode with
              | Submodule -> ()
              | Dir -> loadtree collect e.hash (dpath ^ "/" ^ e.name) mtime
              | File | Exec | Link -> add collect e.hash Blob (dh lxor murmurhash2 e.name) mtime) es
      | _ -> prerr_endline (Printf.sprintf "load: %s: not tree" (Hash.to_hex h)) in
  let loadcommit collect h =
    if not (Hashtbl.mem has h) then
      match Store.read st h with
      | Commit c ->
          let mtime = Object.local_time c.committer in
          add collect h Commit 0 mtime;
          loadtree collect c.tree "" mtime
      | _ -> prerr_endline (Printf.sprintf "load: %s: not commit" (Hash.to_hex h)) in
  let twixt = Query.twixt st heads have in
  if twixt <> [] then begin
    List.iter (fun h -> if Hash.compare h Hash.zero <> 0 then loadcommit false h) have;
    List.iter (loadcommit true) twixt
  end;
  (* pickdeltas: kind, path (descending), date, hash *)
  let meta = Array.of_list (List.rev !metas) in
  Array.stable_sort (fun a b ->
    if a.kind <> b.kind then compare (code a.kind) (code b.kind)
    else if a.path <> b.path then compare b.path a.path
    else if a.mtime <> b.mtime then compare a.mtime b.mtime
    else Hash.compare a.hash b.hash) meta;
  let n = Array.length meta in
  let data = Array.make n "" and tables = Array.make n None in
  for i = 0 to n - 1 do
    let m = meta.(i) in
    if m.kind <> Commit && m.kind <> Tag then begin
      let d = match Store.read_raw st m.hash with Some (_, d) -> d | None -> raise (Store.Missing m.hash) in
      data.(i) <- d;
      tables.(i) <- Some (Delta.table d);
      if i >= 11 then (tables.(i - 11) <- None; data.(i - 11) <- "");
      let best = ref (String.length d) in
      for j = max 0 (i - 10) to i - 1 do
        let p = meta.(j) in
        match tables.(j) with
        | Some t when p.nchain < 128 && p.kind = m.kind ->
            let dl = Delta.deltify t d in
            let sz = Delta.estimate dl in
            if sz + 32 < !best then begin
              best := sz;
              m.delta <- Some (p, dl);
              m.nchain <- p.nchain + 1;
              m.head <- (match p.head with Some h -> Some h | None -> Some p)
            end
        | _ -> ()
      done
    end
  done;
  (* genpack's order: by the chain head's date, newest first; a chain
   * together, shortest first (git9 breaks the heads' ties by address:
   * here by their place in the sort above) *)
  Array.iteri (fun i m -> m.order <- i) meta;
  let hd m = match m.head with Some h -> h | None -> m in
  let order = Array.copy meta in
  Array.stable_sort (fun a b ->
    let ah = hd a and bh = hd b in
    if ah.mtime <> bh.mtime then compare bh.mtime ah.mtime
    else if ah != bh then compare bh.order ah.order
    else if a.nchain <> b.nchain then compare a.nchain b.nchain
    else compare a.mtime b.mtime) order;
  Pack.write (Array.to_list (Array.map (fun m ->
    match m.delta with
    | Some (p, d) -> Pack.Ref_delta (p.hash, d)
    | None -> (match Store.read_raw st m.hash with Some (k, d) -> Pack.Whole (k, d) | None -> raise (Store.Missing m.hash))) order))
