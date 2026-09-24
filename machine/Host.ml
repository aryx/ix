(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Host.mli *)

type caps = < Cap.fork; Cap.wait; Cap.chdir; Cap.kill; Cap.open_in; Cap.open_out >

let fd (n : int) : Unix.file_descr = Obj.magic n
let int_of_fd (f : Unix.file_descr) : int = Obj.magic f

let errno : Unix.error -> int = function
  | EPERM -> 1 | ENOENT -> 2 | ESRCH -> 3 | EINTR -> 4 | EIO -> 5 | ENXIO -> 6 | E2BIG -> 7 | ENOEXEC -> 8
  | EBADF -> 9 | ECHILD -> 10 | EAGAIN -> 11 | ENOMEM -> 12 | EACCES -> 13 | EFAULT -> 14 | EBUSY -> 16
  | EEXIST -> 17 | EXDEV -> 18 | ENODEV -> 19 | ENOTDIR -> 20 | EISDIR -> 21 | EINVAL -> 22 | ENFILE -> 23
  | EMFILE -> 24 | ENOTTY -> 25 | EFBIG -> 27 | ENOSPC -> 28 | ESPIPE -> 29 | EROFS -> 30 | EMLINK -> 31
  | EPIPE -> 32 | ERANGE -> 34 | EDEADLK -> 35 | ENAMETOOLONG -> 36 | ENOLCK -> 37 | ENOSYS -> 38 | ENOTEMPTY -> 39
  | ELOOP -> 40 | EUNKNOWNERR n -> n
  | _ -> 5

let wrap f = try Ok (f ()) with Unix.Unix_error (e, _, _) -> Error (errno e) | Sys_error _ -> Error 2

(* Linux's signal numbers, OCaml's *)
let signals = [
  1, Sys.sighup; 2, Sys.sigint; 3, Sys.sigquit; 4, Sys.sigill; 6, Sys.sigabrt; 8, Sys.sigfpe; 9, Sys.sigkill;
  10, Sys.sigusr1; 11, Sys.sigsegv; 12, Sys.sigusr2; 13, Sys.sigpipe; 14, Sys.sigalrm; 15, Sys.sigterm;
  17, Sys.sigchld; 18, Sys.sigcont; 19, Sys.sigstop; 20, Sys.sigtstp ]
let ocaml_signal n = List.assoc_opt n signals
let linux_signal s = List.find_map (fun (n, s') -> if s' = s then Some n else None) signals

let kind : Unix.file_kind -> Linux.kind = function
  | S_REG -> Reg | S_DIR -> Dir | S_CHR -> Chr | S_BLK -> Blk | S_FIFO -> Fifo | S_LNK -> Lnk | S_SOCK -> Sock

let create (caps : caps) : Linux.host =
  let dirs = Hashtbl.create 4 in
  let dir_of n =
    match Hashtbl.find_opt dirs n with
    | Some d -> d
    | None ->
        let path = Unix.readlink (Printf.sprintf "/proc/self/fd/%d" n) in
        let d = (Unix.opendir path, path) in
        Hashtbl.replace dirs n d; d in
  {
    read = (fun f n -> wrap (fun () -> let b = Bytes.create n in let k = Unix.read (fd f) b 0 n in Bytes.sub_string b 0 k));
    write = (fun f s -> wrap (fun () -> Unix.write_substring (fd f) s 0 (String.length s)));
    openat = (fun dir path flags mode -> wrap (fun () ->
      let path = match dir with
        | Some d when Filename.is_relative path -> Filename.concat (Unix.readlink (Printf.sprintf "/proc/self/fd/%d" d)) path
        | _ -> path in
      let acc : Unix.open_flag list = match flags land 3 with 0 -> [ O_RDONLY ] | 1 -> [ O_WRONLY ] | _ -> [ O_RDWR ] in
      let bits = [ 0o100, Unix.O_CREAT; 0o200, O_EXCL; 0o1000, O_TRUNC; 0o2000, O_APPEND; 0o4000, O_NONBLOCK;
                   0o400, O_NOCTTY; 0o2000000, O_CLOEXEC ] in
      let f = Unix.openfile path (acc @ List.filter_map (fun (b, fl) -> if flags land b <> 0 then Some fl else None) bits) mode in
      (* O_DIRECTORY, 0o40000 on arm *)
      if flags land 0o40000 <> 0 && (Unix.fstat f).st_kind <> S_DIR then (Unix.close f; raise (Unix.Unix_error (ENOTDIR, "open", path)));
      int_of_fd f));
    close = (fun f -> wrap (fun () ->
      (match Hashtbl.find_opt dirs f with Some (d, _) -> Unix.closedir d; Hashtbl.remove dirs f | None -> ());
      Unix.close (fd f)));
    fstat = (fun f -> wrap (fun () ->
      let s = Unix.LargeFile.fstat (fd f) in
      { Linux.dev = s.st_dev; ino = s.st_ino; kind = kind s.st_kind; perm = s.st_perm; nlink = s.st_nlink; uid = s.st_uid;
        gid = s.st_gid; rdev = s.st_rdev; size = Int64.to_int s.st_size; atime = s.st_atime; mtime = s.st_mtime; ctime = s.st_ctime }));
    lseek = (fun f off whence -> wrap (fun () ->
      Unix.lseek (fd f) off (match whence with 0 -> SEEK_SET | 1 -> SEEK_CUR | _ -> SEEK_END)));
    unlink = (fun p -> wrap (fun () -> Unix.unlink p));
    rmdir = (fun p -> wrap (fun () -> Unix.rmdir p));
    chdir = (fun p -> wrap (fun () -> CapUnix.chdir caps p));
    mkdir = (fun p mode -> wrap (fun () -> Unix.mkdir p mode));
    access = (fun p mode -> wrap (fun () ->
      let perms : Unix.access_permission list =
        if mode = 0 then [ F_OK ]
        else List.filter_map (fun (b, perm) -> if mode land b <> 0 then Some perm else None) [ 4, Unix.R_OK; 2, Unix.W_OK; 1, Unix.X_OK ] in
      Unix.access p perms));
    fchmod = (fun f mode -> wrap (fun () -> Unix.fchmod (fd f) mode));
    ftruncate = (fun f len -> wrap (fun () -> Unix.ftruncate (fd f) len));
    rename = (fun a b -> wrap (fun () -> Unix.rename a b));
    dup = (fun f -> wrap (fun () -> int_of_fd (Unix.dup (fd f))));
    dup2 = (fun a b -> wrap (fun () -> Unix.dup2 (fd a) (fd b); b));
    getcwd = Sys.getcwd;
    getpid = Unix.getpid;
    pipe = (fun () -> wrap (fun () -> let a, b = Unix.pipe () in int_of_fd a, int_of_fd b));
    fork = (fun () -> wrap (fun () -> flush_all (); CapUnix.fork caps ()));
    wait4 = (fun pid options -> wrap (fun () ->
      let flags = if options land 1 <> 0 then [ Unix.WNOHANG ] else [] in
      let p, st = CapUnix.waitpid caps flags pid in
      p, (match st with
          | WEXITED c -> (c land 0xff) lsl 8
          | WSIGNALED s -> Option.value (linux_signal s) ~default:9
          | WSTOPPED s -> (Option.value (linux_signal s) ~default:19 lsl 8) lor 0x7f)));
    kill = (fun pid sg -> wrap (fun () ->
      match (if sg = 0 then Some 0 else ocaml_signal sg) with
      | Some s -> CapUnix.kill caps pid s
      | None -> raise (Unix.Unix_error (EINVAL, "kill", ""))));
    readdir = (fun f -> wrap (fun () ->
      let d, path = dir_of f in
      match Unix.readdir d with
      | name ->
          let s = Unix.LargeFile.lstat (Filename.concat path name) in
          Some { Linux.d_ino = s.st_ino; d_name = name; d_kind = kind s.st_kind }
      | exception End_of_file -> None));
    isatty = (fun f -> Unix.isatty (fd f));
    now = Unix.gettimeofday;
    sleep = (fun d -> try Unix.sleepf d with Unix.Unix_error (EINTR, _, _) -> ());
    setitimer = (fun interval value ->
      let old = Unix.setitimer ITIMER_REAL { it_interval = interval; it_value = value } in
      old.it_interval, old.it_value);
    signal = (fun n d ->
      match ocaml_signal n with
      | None -> ()
      | Some s ->
          Sys.set_signal s (match d with
            | Default -> Sys.Signal_default
            | Ignore -> Sys.Signal_ignore
            | Catch -> Sys.Signal_handle (fun _ -> Linux.raise_signal n)));
  }
