(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devmnt.mli *)

open Types

let version9p = "9P2000"
let maxrpc = 8192 + P9.io_header_size

(* a connection: its number (its files' devno), its channel, the
 * message size, the replies read not yet taken, whether a process is
 * reading, the next tag *)
type mnt = {
  mid : int;
  conn : chan;
  mutable msize : int;
  mutable replies : (int * P9.Response.t) list;
  mutable reading : bool;
  mutable next_tag : int;
}

let mnts = ref []
let next_mid = ref 1
let next_fid = ref 1

let rpcerr = "mount rpc error"

let find devno = try List.find (fun m -> m.mid = devno) !mnts with Not_found -> raise (Error rpcerr)

let newfid () = let f = !next_fid in incr next_fid; f

(*****************************************************************************)
(* The RPCs (mountrpc, mountio, mountmux) *)
(*****************************************************************************)

let conn_dev m = Dev.find m.conn.dev

(* all of [n] bytes from the connection *)
let rec read_n m n acc =
  if n = 0 then String.concat "" (List.rev acc)
  else begin
    let s = (conn_dev m).Dev.read m.conn n 0 in
    if s = "" then raise (Error ehungup);
    read_n m (n - String.length s) (s :: acc)
  end

(* one message from the server *)
let read_msg m =
  let size = read_n m 4 [] in
  let n = Machine.get_le32 size 0 in
  if n < 7 || n > m.msize then raise (Error rpcerr);
  P9.decode (size ^ read_n m (n - 4) [])

let alloc_tag m =
  let t = m.next_tag in
  m.next_tag <- (if t >= 0xfffe then 1 else t + 1);
  t

(* a request sent, its reply waited for: read by this process if no one
 * else is reading, or handed over by the one who is (a server's Rerror:
 * Error) *)
let rpc m req =
  let tag = match req with P9.Request.Version (_, _) -> P9.notag | _ -> alloc_tag m in
  let s = P9.encode { P9.tag = tag; P9.mtyp = P9.T req } in
  ignore ((conn_dev m).Dev.write m.conn s 0);
  let rec wait () =
    try
      let r = List.assoc tag m.replies in
      m.replies <- List.filter (fun (t, _) -> t <> tag) m.replies;
      r
    with Not_found ->
      if m.reading then begin Proc.sleep (Mnt_reply m.mid); wait () end
      else begin
        m.reading <- true;
        (try
          let msg = read_msg m in
          (match msg.P9.mtyp with
           | P9.R r -> m.replies <- (msg.P9.tag, r) :: m.replies
           | P9.T _ -> ());
          m.reading <- false
        with e -> m.reading <- false; Proc.wakeup (Mnt_reply m.mid); raise e);
        Proc.wakeup (Mnt_reply m.mid);
        wait ()
      end in
  match wait () with
  | P9.Response.Error e -> raise (Error e)
  | r -> r

let bad () = raise (Error rpcerr)

(*****************************************************************************)
(* Sessions *)
(*****************************************************************************)

(* the connection's session (the same channel: an existing one), or a
 * new one after Tversion (mntversion) *)
let session c msize =
  try List.find (fun m -> m.conn == c) !mnts
  with Not_found ->
    let m = { mid = !next_mid; conn = c; msize = maxrpc; replies = []; reading = false; next_tag = 1 } in
    incr next_mid;
    (match rpc m (P9.Request.Version ((if msize > 0 then msize else maxrpc), version9p)) with
     | P9.Response.Version (ms, v) ->
         if v <> version9p then raise (Error ("bad 9P version returned from server"));
         m.msize <- ms
     | _ -> bad ());
    Chan.incref c;
    mnts := m :: !mnts;
    m

let version c msize _ = (session c msize).msize

let mchan m qid fid =
  let c = Dev.attach 'M' m.mid qid in
  c.fid <- fid;
  c

let attach c aname =
  let m = session c 0 in
  let fid = newfid () in
  match rpc m (P9.Request.Attach (fid, None, !Dev.eve, aname)) with
  | P9.Response.Attach q -> mchan m q fid
  | _ -> bad ()

let auth c aname =
  let m = session c 0 in
  let fid = newfid () in
  match rpc m (P9.Request.Auth (fid, !Dev.eve, aname)) with
  | P9.Response.Auth q -> let ac = mchan m q fid in ac.opened <- Some (Chan.mode_of_int 2); ac
  | _ -> bad ()

(*****************************************************************************)
(* The files *)
(*****************************************************************************)

(* an entry as the server says it, its device the mount's (mntdirfix) *)
let fix (c : chan) d = { d with d_type = 'M'; d_dev = c.devno }

let mode_bits m =
  (match m.access with Oread -> 0 | Owrite -> 1 | Ordwr -> 2 | Oexec -> 3)
  lor (if m.trunc then 16 else 0) lor (if m.rclose then 64 else 0)

(* [n] bytes at [off] by Treads of at most the message's room *)
let read (c : chan) n off =
  let m = find c.devno in
  let room = m.msize - P9.io_header_size in
  let rec go off n acc =
    if n <= 0 then acc
    else match rpc m (P9.Request.Read (c.fid, off, min n room)) with
      | P9.Response.Read s ->
          let acc = acc ^ s in
          if String.length s < min n room || String.length s = 0 then acc else go (off + String.length s) (n - String.length s) acc
      | _ -> bad () in
  go off n ""

let write (c : chan) s off =
  let m = find c.devno in
  let room = m.msize - P9.io_header_size in
  let rec go pos =
    if pos >= String.length s then pos
    else
      let k = min room (String.length s - pos) in
      match rpc m (P9.Request.Write (c.fid, off + pos, String.sub s pos k)) with
      | P9.Response.Write w -> if w < k then pos + w else go (pos + w)
      | _ -> bad () in
  go 0

let clunk (c : chan) = try ignore (rpc (find c.devno) (P9.Request.Clunk c.fid)) with Error _ -> ()

(* a directory's entries: its reads (a fid of its own, opened, when the
 * channel's is not) *)
let dirs (c : chan) =
  let m = find c.devno in
  let fid, own =
    if c.opened <> None then c.fid, false
    else begin
      let f = newfid () in
      (match rpc m (P9.Request.Walk (c.fid, f, [])) with P9.Response.Walk _ -> () | _ -> bad ());
      (match rpc m (P9.Request.Open (f, 0)) with P9.Response.Open (_, _) -> () | _ -> clunk { c with fid = f }; bad ());
      f, true
    end in
  let rec entries off acc =
    match rpc m (P9.Request.Read (fid, off, m.msize - P9.io_header_size)) with
    | P9.Response.Read "" -> acc
    | P9.Response.Read s ->
        let rec split o acc =
          if o + 2 > String.length s then acc
          else
            let n = (Char.code s.[o] lor (Char.code s.[o + 1] lsl 8)) + 2 in
            if o + n > String.length s then raise (Error "invalid directory entry received from server");
            split (o + n) (fix c (Dev.decode (String.sub s o n)) :: acc) in
        entries (off + String.length s) (split 0 acc)
    | _ -> bad () in
  let l = try List.rev (entries 0 []) with e -> (if own then clunk { c with fid = fid }); raise e in
  if own then clunk { c with fid = fid };
  l

let init () =
  let d = Dev.default 'M' "mnt" in
  Dev.register { d with
    Dev.attach = (fun _ -> raise (Error "mount/attach disallowed"));
    Dev.walk = (fun c nc name ->
      let m = find c.devno in
      let f = newfid () in
      match rpc m (P9.Request.Walk (c.fid, f, [ name ])) with
      | P9.Response.Walk [ q ] -> nc.fid <- f; q
      | P9.Response.Walk _ -> raise (Error enonexist)
      | _ -> bad ());
    Dev.clone = (fun c nc ->
      let f = newfid () in
      match rpc (find c.devno) (P9.Request.Walk (c.fid, f, [])) with
      | P9.Response.Walk _ -> nc.fid <- f
      | _ -> bad ());
    Dev.clunk = clunk;
    Dev.stat = (fun c ->
      match rpc (find c.devno) (P9.Request.Stat c.fid) with
      | P9.Response.Stat d -> fix c d
      | _ -> bad ());
    Dev.dirs = dirs;
    Dev.open_ = (fun c md ->
      match rpc (find c.devno) (P9.Request.Open (c.fid, mode_bits md)) with
      | P9.Response.Open (q, _) -> c.qid <- q; c
      | _ -> bad ());
    Dev.create = (fun c name md perm ->
      match rpc (find c.devno) (P9.Request.Create (c.fid, name, perm, mode_bits md)) with
      | P9.Response.Create (q, _) -> c.qid <- q
      | _ -> bad ());
    Dev.read = read;
    Dev.write = write;
    Dev.remove = (fun c ->
      match rpc (find c.devno) (P9.Request.Remove c.fid) with
      | P9.Response.Remove -> ()
      | _ -> bad ());
    Dev.wstat = (fun c dd ->
      match rpc (find c.devno) (P9.Request.Wstat (c.fid, dd)) with
      | P9.Response.Wstat -> ()
      | _ -> bad ());
    Dev.close = clunk;
  }
