(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Process.mli *)

type caps = < Cap.fork; Cap.exec; Cap.wait; Cap.open_in; Cap.open_out >

type fd = int

(* rc's redirections name fds by number: on Unix a Unix.file_descr is
 * one *)
let ufd (n : fd) : Unix.file_descr = Obj.magic n
let num (d : Unix.file_descr) : fd = Obj.magic d

(* claude: as Plan 9's rc, a relative name is looked up in $path even
 * with a / in it (git/add), unless it starts with ./ or ../ *)
let candidates ~path name =
  let starts p = String.length name >= String.length p && String.sub name 0 (String.length p) = p in
  if starts "/" || starts "./" || starts "../" then [ name ]
  else List.map (fun dir -> if dir = "" || dir = "." then name else Filename.concat dir name) path

let search ~path name =
  List.find_opt (fun f -> Sys.file_exists f && not (Sys.is_directory f)) (candidates ~path name)

(* each candidate in turn; the message is the last one's error, as 9base's *)
let exec caps ~path ~env (argv : string list) =
  let name = List.hd argv in
  let why =
    List.fold_left (fun _ f ->
      try CapUnix.execve caps f (Array.of_list argv) env; ""
      with Unix.Unix_error (e, _, _) -> Unix.error_message e)
      "No such file or directory" (candidates ~path name)
  in
  prerr_endline (name ^ ": " ^ why);
  Unix._exit 1

let fork caps (f : unit -> int) : int =
  flush stdout;
  flush stderr;
  match CapUnix.fork caps () with
  | 0 ->
      Sys.set_signal Sys.sigint Sys.Signal_default;
      Sys.set_signal Sys.sigquit Sys.Signal_default;
      let code = try f () with _ -> 1 in
      flush stdout;
      flush stderr;
      Unix._exit code
  | pid -> pid

(* plan9port's names for the Unix signals *)
let note (s : int) : string =
  List.assoc_opt s
    [ Sys.sighup, "hangup"; Sys.sigint, "interrupt"; Sys.sigquit, "quit";
      Sys.sigkill, "sys: kill"; Sys.sigterm, "kill"; Sys.sigpipe, "sys: write on closed pipe";
      Sys.sigalrm, "alarm"; Sys.sigsegv, "sys: segmentation violation";
      Sys.sigbus, "sys: bus error"; Sys.sigfpe, "sys: fp"; Sys.sigabrt, "sys: abort";
      Sys.sigill, "sys: illegal instruction" ]
  |> Option.value ~default:(Printf.sprintf "sys: signal %d" s)

let status_of pid (st : Unix.process_status) : string =
  match st with
  | Unix.WEXITED 0 -> ""
  | Unix.WEXITED n -> string_of_int n
  | Unix.WSIGNALED s | Unix.WSTOPPED s ->
      let msg = "signal: " ^ note s in
      if s <> Sys.sigint then prerr_endline (Printf.sprintf "%d: %s" pid msg);
      msg

let rec wait caps pid =
  match CapUnix.waitpid caps [] pid with
  | _, st -> status_of pid st
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait caps pid

let rec wait_any caps =
  match CapUnix.wait caps () with
  | pid, st -> Some (pid, status_of pid st)
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_any caps
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> None

(* a true status, like "" or "0|0", is 0 *)
let code (s : string) : int =
  if String.for_all (fun c -> c = '0' || c = '|') s then 0
  else
    (* claude: as rc's atoi: the leading number, 1 if none or 0 ("3|4" is 3, "0|4" 1) *)
    let n = ref 0 and i = ref 0 in
    while !i < String.length s && s.[!i] >= '0' && s.[!i] <= '9' do
      n := (!n * 10) + Char.code s.[!i] - 48; incr i done;
    if !n = 0 then 1 else !n

let pipe () = let r, w = Unix.pipe () in num r, num w
let dup2 a b = Unix.dup2 (ufd a) (ufd b)
let close a = try Unix.close (ufd a) with Unix.Unix_error _ -> ()

let with_fds (fds : fd list) (f : unit -> 'a) : 'a =
  let saved =
    List.map (fun n ->
      n, (match Unix.dup ~cloexec:true (ufd n) with d -> Some d | exception Unix.Unix_error _ -> None))
      (List.sort_uniq compare fds)
  in
  flush stdout;
  flush stderr;
  Fun.protect f ~finally:(fun () ->
    flush stdout;
    flush stderr;
    saved |> List.iter (fun (n, d) ->
      match d with
      | Some d -> Unix.dup2 d (ufd n); Unix.close d
      | None -> close n))

let open_file (_ : < Cap.open_in; Cap.open_out; .. >) (k : Ast.rkind) (file : string) : fd =
  let flags =
    match k with
    | Ast.Write -> [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
    | Ast.Append -> [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ]
    | Ast.Read -> [ Unix.O_RDONLY ]
    | Ast.RdWr -> [ Unix.O_RDWR; Unix.O_CREAT ]
  in
  num (Unix.openfile file (Unix.O_CLOEXEC :: flags) 0o666)

let write fd s =
  let n = String.length s in
  let rec go off =
    if off < n then
      match Unix.write_substring (ufd fd) s off (n - off) with
      | k -> go (off + k)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> go off
  in
  try go 0 with Unix.Unix_error (Unix.EPIPE, _, _) -> ()

let read_all fd =
  let b = Buffer.create 1024 and chunk = Bytes.create 4096 in
  let rec go () =
    match Unix.read (ufd fd) chunk 0 4096 with
    | 0 -> ()
    | k -> Buffer.add_subbytes b chunk 0 k; go ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
  in
  go ();
  Buffer.contents b
