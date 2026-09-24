(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Proto.mli *)

type direction = Upload | Receive
type transport = Local | Git | Ssh

type conn = {
  transport : transport;
  rd : Unix.file_descr;
  wr : Unix.file_descr;
  child : int option;
  mutable multiack : bool;
  mutable sideband : bool;
  mutable sideband64k : bool;
  mutable report : bool;
  mutable symref : (string * string) option;
}

exception Error of string

let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

type pkt = Flush | Pkt of string

let make transport rd wr child =
  { transport; rd; wr; child; multiack = false; sideband = false; sideband64k = false; report = false; symref = None }

let read_raw c n =
  let b = Bytes.create n in
  let rec go got =
    if got = n then got
    else match Unix.read c.rd b got (n - got) with
      | 0 -> got
      | k -> go (got + k)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> go got
      | exception Unix.Unix_error (Unix.ECONNRESET, _, _) -> got in
  let got = go 0 in
  Bytes.sub_string b 0 got

let write_raw c s = Procs.write_all c.wr s

let read_pkt c =
  let len = read_raw c 4 in
  if String.length len <> 4 then error "pktline: short read from transport";
  match int_of_string_opt ("0x" ^ len) with
  | Some 0 -> Flush
  | Some n when n > 4 ->
      let s = read_raw c (n - 4) in
      if String.length s <> n - 4 then error "pktline: short read from transport";
      if String.length s > 4 && String.sub s 0 4 = "ERR " then begin
        let msg = String.sub s 4 (String.length s - 4) in
        error "%s" (match String.rindex_opt msg '\n' with Some i -> String.sub msg 0 i | None -> msg)
      end;
      Pkt s
  | _ -> error "pktline: bad length '%s'" len

let write_pkt c s = write_raw c (Printf.sprintf "%04x%s" (String.length s + 4) s)
let flush c = write_raw c "0000"

let parse_caps c caps =
  List.iter (fun p ->
    if p = "report-status" then c.report <- true;
    if p = "multi_ack" then c.multiack <- true
    else if p = "side-band" then c.sideband <- true
    else if p = "side-band-64k" then c.sideband64k <- true
    else if String.starts_with ~prefix:"symref=" p then
      let s = String.sub p 7 (String.length p - 7) in
      match String.index_opt s ':' with
      | Some i -> c.symref <- Some (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))
      | None -> ()) (String.split_on_char ' ' caps)

let find_sub s sub from =
  let n = String.length sub in
  let rec go i = if i + n > String.length s then None else if String.sub s i n = sub then Some i else go (i + 1) in
  go from

let parse_uri uri =
  let proto, s =
    match find_sub uri "://" 0 with
    | None -> "ssh", uri
    | Some p ->
        let start = if String.starts_with ~prefix:"git+" uri then 4 else 0 in
        String.sub uri start (p - start), String.sub uri (p + 3) (String.length uri - p - 3) in
  let default_port =
    if proto = "git" then Some "9418"
    else if String.starts_with ~prefix:"https" proto then Some "443"
    else if String.starts_with ~prefix:"http" proto then Some "80"
    else if String.starts_with ~prefix:"hjgit" proto then Some "17021"
    else if String.starts_with ~prefix:"gits" proto then Some "9419"
    else None in
  (* the path: after the first ':' when there is no port to find, else
   * from the first '/' *)
  let p = match default_port with
    | None -> (match String.index_opt s ':' with Some i -> Some (i + 1) | None -> None)
    | Some _ -> None in
  let p = match p with Some p -> Some p | None -> String.index_opt s '/' in
  match p with
  | None -> None
  | Some p when String.length s - p = 1 -> None
  | Some p ->
      let path = String.sub s p (String.length s - p) in
      let host, port =
        match String.index_opt (String.sub s 0 p) ':' with
        | Some q -> String.sub s 0 q, String.sub s (q + 1) (p - q - 1)
        | None -> String.sub s 0 p, Option.value default_port ~default:"" in
      Some (proto, host, port, path)

let service = function Upload -> "upload" | Receive -> "receive"

(* the request, and a NUL after each part *)
let handshake c host path dir =
  write_pkt c (Printf.sprintf "git-%s-pack %s\000%s" (service dir) path
                 (match host with Some h -> "host=" ^ h ^ "\000" | None -> ""))

(* a child on one end of a socketpair, its standard input and output *)
let spawn prog args transport =
  let mine, theirs = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.set_close_on_exec mine;
  let pid = Unix.create_process prog (Array.of_list (prog :: args)) theirs theirs Unix.stderr in
  Unix.close theirs;
  make transport mine mine (Some pid)

let connect ~print uri dir =
  (* a local repository: its own server *)
  let local = Filename.concat uri ".git" in
  if Sys.file_exists local && Sys.is_directory local then begin
    let path = Unix.realpath uri in
    let c = spawn Sys.executable_name [ "serve"; "-w" ] Local in
    handshake c None path dir;
    c
  end
  else begin
    print (Printf.sprintf "uri: \"%s\"\n" uri);
    match parse_uri uri with
    | None -> error "bad uri %s" uri
    | Some ("git", host, port, path) ->
        let addrs = Unix.getaddrinfo host port [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] in
        let rec dial = function
          | [] -> error "could not dial %s" uri
          | (a : Unix.addr_info) :: rest -> (
              let fd = Unix.socket a.ai_family a.ai_socktype a.ai_protocol in
              try Unix.connect fd a.ai_addr; fd with Unix.Unix_error _ -> Unix.close fd; dial rest) in
        let fd = dial addrs in
        let c = make Git fd fd None in
        handshake c (Some host) path dir;
        c
    | Some ("ssh", host, _, path) ->
        let ssh = match Sys.getenv_opt "GIT_SSH" with Some s when s <> "" -> s | _ -> "ssh" in
        spawn ssh [ host; Printf.sprintf "git-%s-pack" (service dir); path ] Ssh
    | Some (proto, _, _, _) -> error "unknown protocol %s" proto
  end

let stdio () = make Local Unix.stdin Unix.stdout None

let close_write c = try Unix.shutdown c.wr Unix.SHUTDOWN_SEND with Unix.Unix_error _ -> (try Unix.close c.wr with Unix.Unix_error _ -> ())

let close c =
  (try Unix.close c.rd with Unix.Unix_error _ -> ());
  if c.wr <> c.rd then (try Unix.close c.wr with Unix.Unix_error _ -> ());
  Option.iter (fun pid -> ignore (Unix.waitpid [] pid)) c.child

let okref name =
  let n = String.length name in
  if n = 0 || name.[0] = '/' || name.[0] = '.' then false
  else
    let slashed = ref false in
    let rec go i =
      if i >= n then true
      else
        let next = if i + 1 < n then Some name.[i + 1] else None in
        match name.[i] with
        | '.' -> if next = None || next = Some '.' || String.sub name i (n - i) = ".lock" then false else go (i + 1)
        | '/' -> if next = None || next = Some '.' || next = Some '/' then false else (slashed := true; go (i + 1))
        | '@' -> if next = Some '{' then false else go (i + 1)
        | ' ' | '~' | '^' | ':' | '?' | '*' | '[' | '\\' | '\x7f' -> false
        | c when Char.code c < 0x20 -> false
        | _ -> go (i + 1)
    in
    go 0 && !slashed
