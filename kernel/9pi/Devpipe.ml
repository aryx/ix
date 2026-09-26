(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devpipe.mli *)

open Types

let qsize = 32 * 1024

(* a pipe: its queues (q.(0) read by data, written by data1), how many
 * opens each end has, whether each queue is closed *)
type pipe = { q : Buffer.t array; qref : int array; mutable hungup : bool array }

let pipes = ref []
let npipes = ref 0

let get (c : chan) = try List.assoc c.devno !pipes with Not_found -> raise (Error egreg)

let qdir = 0

let entries path =
  if path <> qdir then raise (Error enotdir)
  else [ { Dev.dname = "data"; Dev.dqid = { path = 1; vers = 0; typ = Qt_file }; Dev.dlength = 0; Dev.dperm = 0o600 };
         { Dev.dname = "data1"; Dev.dqid = { path = 2; vers = 0; typ = Qt_file }; Dev.dlength = 0; Dev.dperm = 0o600 } ]

let root = { path = qdir; vers = 0; typ = Qt_dir }

(* the queue an end reads (data: 0, data1: 1); the other it writes *)
let side (c : chan) = c.qid.path - 1

let chan_id (c : chan) i = (2 * c.devno) + i

let rec read c n =
  let p = get c in
  let i = side c in
  let b = p.q.(i) in
  if Buffer.length b > 0 then begin
    let s = Buffer.contents b in
    let k = min n (String.length s) in
    Buffer.clear b;
    Buffer.add_string b (String.sub s k (String.length s - k));
    Proc.wakeup (Pipe_room (chan_id c i));
    String.sub s 0 k
  end
  else if p.hungup.(i) then ""
  else begin Proc.sleep (Pipe_data (chan_id c i)); read c n end

let rec write c s =
  let p = get c in
  let i = 1 - side c in
  let b = p.q.(i) in
  if p.hungup.(i) then raise (Error "write on closed pipe")
  else if Buffer.length b + String.length s > qsize && Buffer.length b > 0 then begin
    Proc.sleep (Pipe_room (chan_id c i)); write c s
  end else begin
    Buffer.add_string b s;
    Proc.wakeup (Pipe_data (chan_id c i));
    String.length s
  end

let init () =
  let d = Dev.default '|' "pipe" in
  Dev.register { d with
    Dev.attach = (fun _ ->
      incr npipes;
      pipes := (!npipes, { q = [| Buffer.create 64; Buffer.create 64 |]; qref = [| 0; 0 |]; hungup = [| false; false |] })
               :: !pipes;
      Dev.attach '|' !npipes root);
    Dev.walk = Dev.tab_walk entries (fun _ -> root);
    Dev.stat = Dev.tab_stat "#|" entries (fun _ -> root);
    Dev.dirs = Dev.tab_dirs entries;
    Dev.open_ = (fun c m ->
      if c.qid.typ <> Qt_dir then begin let p = get c in p.qref.(side c) <- p.qref.(side c) + 1 end;
      Dev.tab_open c m);
    Dev.read = (fun c n _ -> read c n);
    Dev.write = (fun c s _ -> write c s);
    (* an end's last close: the other end's reader sees the end, this
     * end's queue closed to writers (qhangup, qclose) *)
    Dev.close = (fun c ->
      if c.qid.typ <> Qt_dir then begin
        let p = get c in
        let i = side c in
        p.qref.(i) <- p.qref.(i) - 1;
        if p.qref.(i) = 0 then begin
          p.hungup.(1 - i) <- true;
          p.hungup.(i) <- true;
          Proc.wakeup (Pipe_data (chan_id c (1 - i)));
          Proc.wakeup (Pipe_room (chan_id c i));
          if p.qref.(1 - i) = 0 then pipes := List.filter (fun (k, _) -> k <> c.devno) !pipes
        end
      end);
  }
