(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Log.mli *)

type filter = { elt : string; mutable show : bool; mutable subs : filter list }

let rec add f path =
  let p, rest = match String.index_opt path '/' with
    | Some i -> String.sub path 0 i, Some (String.sub path (i + 1) (String.length path - i - 1))
    | None -> path, None in
  let rest = Option.map (fun r -> let i = ref 0 in while !i < String.length r && r.[!i] = '/' do incr i done; String.sub r !i (String.length r - !i)) rest in
  let sub = match List.find_opt (fun s -> s.elt = p) f.subs with
    | Some s -> s.show <- s.show || rest = None; s
    | None -> let s = { elt = p; show = rest = None; subs = [] } in f.subs <- f.subs @ [ s ]; s in
  Option.iter (add sub) rest

let filter paths = let f = { elt = ""; show = false; subs = [] } in List.iter (add f) paths; f

let rec matches1 (t : Store.t) f (a : Object.t option) (b : Object.t option) =
  f.show
  || (match a, b with
      | Some a, Some b when Object.kind a <> Object.kind b -> true
      | Some (Tree _), _ | None, _ -> check t f a b
      | Some _, _ -> false)

and check t f a b =
  let lookup sub = function
    | Some (Object.Tree es) -> (match List.find_opt (fun (e : Object.entry) -> e.name = sub.elt) es with Some e -> e.hash | None -> Hash.zero)
    | _ -> Hash.zero in
  let read h = if Hash.compare h Hash.zero = 0 then None else Some (Store.read t h) in
  List.exists (fun sub ->
    let ha = lookup sub a and hb = lookup sub b in
    Hash.compare ha hb <> 0 && matches1 t sub (read ha) (read hb)) f.subs

let matches t filter (c : Object.commit) =
  match filter with
  | None -> true
  | Some f ->
      let tree = Some (Store.read t c.tree) in
      match c.parents with
      | [] -> matches1 t f tree None
      | ps -> List.exists (fun p -> match Store.read t p with
          | Commit pc -> matches1 t f tree (Some (Store.read t pc.tree))
          | _ -> false) ps

let ctime secs =
  let tm = Unix.gmtime (float_of_int secs) in
  Printf.sprintf "%s %s %2d %02d:%02d:%02d GMT %d\n"
    (String.sub "SunMonTueWedThuFriSat" (tm.tm_wday * 3) 3) (String.sub "JanFebMarAprMayJunJulAugSepOctNovDec" (tm.tm_mon * 3) 3)
    tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec (tm.tm_year + 1900)

let show ~short h (c : Object.commit) =
  let msg = Object.message c in
  if short then
    let first = match String.index_opt msg '\n' with Some i -> String.sub msg 0 i | None -> msg in
    Printf.sprintf "%s %s\n" (Hash.to_hex h) first
  else
    let b = Buffer.create 256 in
    Printf.bprintf b "Hash:\t%s\nAuthor:\t%s\n" (Hash.to_hex h) c.author.id;
    if c.author.id <> c.committer.id then Printf.bprintf b "Committer:\t%s\n" c.committer.id;
    Printf.bprintf b "Date:\t%s\n" (ctime (Object.local_time c.author));
    (* each line after a tab; a last newline ends a line, it does not
     * start one *)
    let lines = String.split_on_char '\n' msg in
    let lines = if msg <> "" && msg.[String.length msg - 1] = '\n' then List.rev (List.tl (List.rev lines)) else lines in
    List.iter (fun l -> if msg <> "" then Printf.bprintf b "\t%s\n" l) lines;
    Buffer.add_string b "\n";
    Buffer.contents b
