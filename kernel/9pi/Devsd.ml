(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devsd.mli *)

open Types

(* the qids (devsd's QID(d, u, p, t)): the controller's letter, the
 * unit, the partition, the type *)
let qtopdir = 1 and qtopctl = 2 and qunitdir = 3 and qctl = 4 and qraw = 5 and qpart = 6
let idno = Char.code 'M'
let qid d u p t = (d lsl 20) lor (u lsl 12) lor (p lsl 4) lor t
let typ path = path land 15
let part_of path = (path lsr 4) land 255

let sdmaxio = 2048 * 1024
let dmexcl = 1 lsl 29

(* a partition: sectors [start, end) *)
type part = { pname : string; start : int; end_ : int; pvers : int }

(* the unit, sdM0: the card once online, its version, its partitions
 * (slots: a deleted one's reused, SDnpart at a time) *)
let card = ref None
let vers = ref 0
let parts : part option array ref = ref [||]

let add_part name start end_ =
  let c = match !card with Some c -> c | None -> raise (Error "i/o error") in
  let n = Array.length !parts in
  (* the name free (or the same partition again), a slot *)
  let free = ref (-1) in
  (try
    for i = 0 to n - 1 do
      match !parts.(i) with
      | None -> if !free = -1 then free := i; raise Exit
      | Some pp -> if pp.pname = name then begin
          if pp.start = start && pp.end_ = end_ then begin free := -2; raise Exit end;
          raise (Error ebadctl)
        end
    done
  with Exit -> ());
  if !free <> -2 then begin
    if !free = -1 then begin
      free := n;
      parts := Array.append !parts (Array.make 16 None)
    end;
    if start > end_ || end_ > c.Emmc.sectors then raise (Error "i/o error");
    !parts.(!free) <- Some { pname = name; start = start; end_ = end_; pvers = 0 }
  end

(* sdinitpart: the card online, "data" its whole *)
let unit () =
  match !card with
  | Some c -> c
  | None ->
      let c = Emmc.online () in
      card := Some c;
      incr vers;
      add_part "data" 0 c.Emmc.sectors;
      c

let part path = match !parts.(part_of path) with Some pp -> pp | None -> raise (Error enonexist)

(*****************************************************************************)
(* The tree (sdgen) *)
(*****************************************************************************)

let dirqid path = { path = path; vers = 0; typ = Qt_dir }
let fileqid path v = { path = path; vers = v; typ = Qt_file }

let entries (c : chan) =
  match typ c.qid.path with
  | 1 ->
      [ Dev.mkdir c "sdctl" (fileqid (qid 0 0 0 qtopctl) 0) 0 0o644;
        Dev.mkdir c "sdM0" (dirqid (qid idno 0 0 qunitdir)) 0 0o555 ]
  | 3 ->
      let cd = unit () in
      let l = ref [] in
      Array.iteri (fun i o -> match o with
        | Some pp ->
            (* 2^30 bytes' sectors (1 lsl 30 is past the Pi1's ints) *)
            let n = pp.end_ - pp.start and per = ((1 lsl 29) / cd.Emmc.secsize) * 2 in
            let d = Dev.mkdir c pp.pname (fileqid (qid idno 0 i qpart) (!vers + pp.pvers))
                      ((n mod per) * cd.Emmc.secsize) 0o640 in
            l := { d with d_lenhi = n / per } :: !l
        | None -> ()) !parts;
      Dev.mkdir c "ctl" (fileqid (qid idno 0 0 qctl) !vers) 0 0o644
      :: Dev.mkdir c "raw" (fileqid (qid idno 0 0 qraw) !vers) 0 (dmexcl lor 0o600) :: List.rev !l
  | _ -> raise (Error enotdir)

let parent path = if typ path = qtopdir || typ path = qunitdir || typ path = qtopctl then dirqid (qid 0 0 0 qtopdir)
  else dirqid (qid idno 0 0 qunitdir)

(*****************************************************************************)
(* I/O (sdbio) *)
(*****************************************************************************)

let bio (c : chan) write s len off =
  let cd = unit () in
  let pp = part c.qid.path in
  let ss = cd.Emmc.secsize in
  let bno = (off / ss) + pp.start in
  let nb = min (((off + len + ss - 1) / ss) + pp.start - bno) (sdmaxio / ss) in
  let nb = if bno + nb > pp.end_ then pp.end_ - bno else nb in
  if bno >= pp.end_ || nb <= 0 then begin if write then raise (Error "i/o error"); "", 0 end
  else begin
    let offset = off mod ss in
    let len = if offset + len > nb * ss then (nb * ss) - offset else len in
    if write then begin
      let b = if offset <> 0 || len mod ss <> 0 then Emmc.bio cd false "" bno nb else String.make (nb * ss) '\000' in
      String.blit s 0 b offset len;
      ignore (Emmc.bio cd true b bno nb);
      "", len
    end else begin
      let b = Emmc.bio cd false "" bno nb in
      String.sub b offset len, len
    end
  end

(* a control message's words *)
let words s = List.filter (fun w -> w <> "") (String.split_on_char ' ' (String.map (fun c -> if c = '\n' || c = '\t' then ' ' else c) s))

let init () =
  Emmc.init ();
  Emmc.enable ();
  let d = Dev.default 'S' "sd" in
  Dev.register { d with
    Dev.attach = (fun spec ->
      if spec <> "" then raise (Error "bad attach specifier");
      Dev.attach 'S' 0 (dirqid (qid 0 0 0 qtopdir)));
    Dev.walk = (fun c nc name ->
      if c.qid.typ <> Qt_dir then raise (Error enotdir)
      else if name = ".." then parent c.qid.path
      else try (List.find (fun d -> d.d_name = name) (entries c)).d_qid with Not_found -> raise (Error enonexist));
    Dev.stat = (fun c ->
      let t = typ c.qid.path in
      if t = qtopdir then Dev.mkdir c "#S" c.qid 0 0o555
      else begin
        let pc = Chan.clone c in
        pc.qid <- parent c.qid.path;
        try List.find (fun d -> d.d_qid.path = c.qid.path) (entries pc) with Not_found -> raise (Error enonexist)
      end);
    Dev.dirs = entries;
    Dev.open_ = Dev.tab_open;
    Dev.read = (fun c n off ->
      let t = typ c.qid.path in
      if t = qtopctl then ""
      else if t = qctl then begin
        let cd = unit () in
        let b = Buffer.create 256 in
        Buffer.add_string b ("inquiry " ^ Emmc.inquiry () ^ "\n");
        Buffer.add_string b (Emmc.rctl cd);
        Array.iter (fun o -> match o with
          | Some pp -> Buffer.add_string b (Printf.sprintf "part %s %d %d\n" pp.pname pp.start pp.end_)
          | None -> ()) !parts;
        let s = Buffer.contents b in
        if off >= String.length s then "" else String.sub s off (min n (String.length s - off))
      end
      else if t = qpart then fst (bio c false "" n off)
      else raise (Error eperm));
    Dev.write = (fun c s off ->
      let t = typ c.qid.path in
      if t = qctl then begin
        ignore (unit ());
        (match words s with
         | [ "part"; name; start; end_ ] ->
             add_part name (try int_of_string start with Failure _ -> raise (Error ebadctl))
               (try int_of_string end_ with Failure _ -> raise (Error ebadctl))
         | [ "delpart"; name ] ->
             let found = ref false in
             Array.iteri (fun i o -> match o with
               | Some pp when pp.pname = name -> !parts.(i) <- None; found := true
               | _ -> ()) !parts;
             if not !found then raise (Error ebadctl)
         | _ -> raise (Error ebadctl));
        String.length s
      end
      else if t = qpart then snd (bio c true s (String.length s) off)
      else raise (Error eperm));
  }
