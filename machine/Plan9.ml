(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Plan9.mli *)

(*****************************************************************************)
(* The a.out *)
(*****************************************************************************)

type aout = { text : int; data : int; bss : int; entry : int }

(* _MAGIC(0, 20): (4*20+0)*20+7, arm's *)
let magic = 0x647
let hdrsz = 32
let utzero = 0x1000
let page = 4096

let parse s =
  let be32 o = Bits.of_int32 (String.get_int32_be s o) in
  if String.length s >= hdrsz && be32 0 = magic then
    Some { text = be32 4; data = be32 8; bss = be32 12; entry = be32 20 }
  else None

let round n = (n + page - 1) / page * page

(*****************************************************************************)
(* The process *)
(*****************************************************************************)

(* a file the emulator is: the namespace's few synthesized files *)
type virt =
  | Pid                            (* #c/pid, /dev/pid *)
  | Bintime                        (* /dev/bintime: nanoseconds, big-endian *)
  | Env of string                  (* /env/NAME *)
  | Note of int                    (* /proc/PID/note: writing posts a note *)

type file = {
  path : string;                   (* absolute, for fd2path and directory reads *)
  virt : virt option;
  mutable content : string;        (* a virtual file's bytes *)
  mutable offset : int;            (* a virtual file's or a directory's *)
  rclose : bool;                   (* ORCLOSE: removed on close *)
}

(* a note being handled: where its Ureg is, to restore it *)
type handling = { ureg : int; note : string }

type proc = {
  host : Linux.host;
  mem : Memory.t;
  name : string;
  heap_base : int;                           (* the page after the bss *)
  bss_end : int;                             (* libc's end: brk's least *)
  files : (int, file) Hashtbl.t;
  mutable errstr : string;
  mutable handler : int;
  mutable handling : handling list;
  notes : string Queue.t;
  children : (int, int) Hashtbl.t;           (* pid: the read end of its exit string's pipe *)
  dir_pending : (int, Linux.dirent) Hashtbl.t;
}

(* what survives an exec (the same host process, a new program): the
 * environment (Plan 9 keeps it in /env, not in the program's memory),
 * and the pipe the parent reads this process's exit string from *)
let env : (string, string) Hashtbl.t = Hashtbl.create 32
let env_loaded = ref false
let exit_pipe : int option ref = ref None

let stack_top = Bits.mask32 (1 lsl 31)
let stack_size = 1024 * 1024
let tos_size = 64

let load host mem (a : aout) file argv envp =
  if not !env_loaded then begin
    List.iter (fun e -> match String.index_opt e '=' with
      | Some i -> Hashtbl.replace env (String.sub e 0 i) (String.sub e (i + 1) (String.length e - i - 1))
      | None -> ()) envp;
    env_loaded := true
  end;
  (* the text with its header from utzero, the data on the next page,
   * the bss after it; the heap from the page after the bss *)
  let text_end = round (utzero + hdrsz + a.text) in
  Memory.map mem ~base:utzero ~size:(text_end - utzero) "text";
  Memory.write_string mem utzero (String.sub file 0 (hdrsz + a.text));
  let data_end = round (text_end + a.data + a.bss) in
  Memory.map mem ~base:text_end ~size:(data_end - text_end) "data";
  Memory.write_string mem text_end (String.sub file (hdrsz + a.text) a.data);
  Memory.map mem ~base:data_end ~size:0 "heap";
  Memory.map mem ~base:(stack_top - stack_size) ~size:stack_size "stack";
  (* as 5i's initstk: the Tos at the top (r0 points at it; the pid in
   * it), then argc (argv[0] included), argv, nil; the strings above *)
  let tos = stack_top - tos_size in
  Memory.store32 mem (tos + 48) (host.Linux.getpid ());
  let strings = List.fold_left (fun acc s -> acc + String.length s + 1) 0 argv in
  let sp = (tos - strings - (4 * (List.length argv + 2))) land lnot 7 in
  Memory.store32 mem sp (List.length argv);
  let ap = ref (sp + (4 * (List.length argv + 2))) in
  List.iteri (fun i s ->
    Memory.store32 mem (sp + 4 + (4 * i)) !ap;
    Memory.write_string mem !ap (s ^ "\000");
    ap := !ap + String.length s + 1) argv;
  Memory.store32 mem (sp + 4 + (4 * List.length argv)) 0;
  let name = Filename.basename (match argv with a :: _ -> a | [] -> "a.out") in
  let p = { host; mem; name; heap_base = data_end; bss_end = text_end + a.data + a.bss; files = Hashtbl.create 8; errstr = ""; handler = 0; handling = [];
            notes = Queue.create (); children = Hashtbl.create 4; dir_pending = Hashtbl.create 4 } in
  p, a.entry, sp, tos

(*****************************************************************************)
(* Errors *)
(*****************************************************************************)

exception Error of string

(* the host's errno, as Plan 9's kernel words it *)
let error_of = function
  | 2 -> "file does not exist"
  | 13 | 1 -> "permission denied"
  | 17 -> "file already exists"
  | 20 -> "not a directory"
  | 21 -> "is a directory"
  | 39 -> "directory not empty"
  | 9 -> "fd out of range or not open"
  | 10 -> "no living children"
  | 36 -> "file name too long"
  | 28 -> "file system full"
  | 32 -> "write on closed pipe"
  | e -> Printf.sprintf "i/o error (errno %d)" e

let ok = function Ok v -> v | Error e -> raise (Error (error_of e))

(*****************************************************************************)
(* The namespace *)
(*****************************************************************************)

let absolute p path =
  let path = if Filename.is_relative path then Filename.concat (p.host.getcwd ()) path else path in
  (* ".", "..", "//" folded: fd2path's answer *)
  let parts = List.fold_left (fun acc c -> match c with
    | "" | "." -> acc
    | ".." -> (match acc with _ :: r -> r | [] -> [])
    | c -> c :: acc) [] (String.split_on_char '/' path) in
  "/" ^ String.concat "/" (List.rev parts)

let virt_of p path =
  match String.split_on_char '/' path with
  | [ "#c"; "pid" ] | [ ""; "dev"; "pid" ] -> Some Pid
  | [ ""; "dev"; "bintime" ] -> Some Bintime
  | [ ""; "env"; name ] when name <> "" -> Some (Env name)
  | [ ""; "proc"; pid; "note" ] ->
      (match int_of_string_opt pid with Some n when n = p.host.getpid () -> Some (Note n) | _ -> None)
  | _ -> None

let be64 v = String.init 8 (fun i -> Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical v (8 * (7 - i))) 0xffL)))

(* a virtual file's bytes, when opened *)
let content p = function
  | Pid -> Printf.sprintf "%11d " (p.host.getpid ())
  | Bintime -> ""
  | Env name -> Option.value (Hashtbl.find_opt env name) ~default:""
  | Note _ -> ""

(* a host descriptor reserved for a virtual file: its number is then
 * the host's, never clashing *)
let reserve p = ok (p.host.openat None "/dev/null" 0 0)

let add p fd path virt ~rclose =
  let f = { path; virt; content = (match virt with Some v -> content p v | None -> ""); offset = 0; rclose } in
  Hashtbl.replace p.files fd f; fd

(* Plan 9's open modes, as Linux's flags: OREAD 0, OWRITE 1, ORDWR 2,
 * OEXEC 3 (read); OTRUNC 16, OCEXEC 32, ORCLOSE 64, OEXCL 0x1000 *)
let linux_flags mode =
  let acc = match mode land 3 with 1 -> 1 | 2 -> 2 | _ -> 0 in
  acc lor (if mode land 16 <> 0 then 0o1000 else 0) lor (if mode land 32 <> 0 then 0o2000000 else 0)
  lor (if mode land 0x1000 <> 0 then 0o200 else 0)

(* a name: "#c/pid" is a device's, not relative to the directory *)
let resolve p name = if String.length name > 0 && name.[0] = '#' then name, virt_of p name else let path = absolute p name in path, virt_of p path

let sys_open p name mode =
  let path, v = resolve p name in
  match v with
  | Some (Env n) when not (Hashtbl.mem env n) -> raise (Error "file does not exist")
  | Some v -> add p (reserve p) path (Some v) ~rclose:false
  | None ->
      let fd = ok (p.host.openat None path (linux_flags mode) 0) in
      add p fd path None ~rclose:(mode land 64 <> 0)

let dmdir = 1 lsl 31

let sys_create p name mode perm =
  let path = absolute p name in
  match virt_of p path with
  | Some (Env n) -> Hashtbl.replace env n ""; add p (reserve p) path (Some (Env n)) ~rclose:false
  | Some _ -> raise (Error "permission denied")
  | None ->
      if Bits.mask32 perm land dmdir <> 0 then begin
        ok (p.host.mkdir path (perm land 0o777));
        add p (ok (p.host.openat None path 0 0)) path None ~rclose:false
      end
      else
        let fd = ok (p.host.openat None path (linux_flags mode lor 0o100 lor 0o1000) (perm land 0o777)) in
        add p fd path None ~rclose:(mode land 64 <> 0)

let file p fd = match Hashtbl.find_opt p.files fd with Some f -> Some f | None -> None

let remove_path p path =
  match virt_of p path with
  | Some (Env n) -> Hashtbl.remove env n
  | Some _ -> raise (Error "permission denied")
  | None ->
      let st = ok (p.host.stat path) in
      if st.kind = Dir then ok (p.host.rmdir path) else ok (p.host.unlink path)

let sys_close p fd =
  (match file p fd with
   | Some f ->
       Hashtbl.remove p.files fd;
       Hashtbl.remove p.dir_pending fd;
       if f.rclose then (try remove_path p f.path with Error _ -> ())
   | None -> ());
  ok (p.host.close fd)

(*****************************************************************************)
(* Stat records (9P's machine-independent form) *)
(*****************************************************************************)

let user () = Option.value (Hashtbl.find_opt env "user") ~default:(Option.value (Hashtbl.find_opt env "USER") ~default:"none")

(* size[2] type[2] dev[4] qid[13] mode[4] atime[4] mtime[4] length[8]
 * name[s] uid[s] gid[s] muid[s], little-endian *)
let stat_record name (st : Linux.stat) =
  let b = Buffer.create 64 in
  let u8 v = Buffer.add_char b (Char.chr (v land 0xff)) in
  let u16 v = u8 v; u8 (v lsr 8) in
  let u32 v = u16 (v land 0xffff); u16 ((v lsr 16) land 0xffff) in
  (* the high word: none under js_of_ocaml's 32-bit ints *)
  let u64 v = u32 (Bits.mask32 v); u32 (if Bits.native then Bits.mask32 (v asr 32) else 0) in
  let str s = u16 (String.length s); Buffer.add_string b s in
  let dir = st.kind = Dir in
  let user = user () in
  u16 0; u16 (Char.code 'M'); u32 st.dev;
  u8 (if dir then 0x80 else 0); u32 (int_of_float st.mtime); u64 st.ino;
  u32 ((if dir then dmdir else 0) lor st.perm);
  u32 (int_of_float st.atime); u32 (int_of_float st.mtime);
  u64 (if dir then 0 else st.size);
  str name; str user; str user; str user;
  let r = Buffer.to_bytes b in
  Bytes.set_uint16_le r 0 (Bytes.length r - 2);
  Bytes.to_string r

let virt_stat p v =
  let now = p.host.now () in
  let name = match v with Pid -> "pid" | Bintime -> "bintime" | Env n -> n | Note _ -> "note" in
  stat_record name { dev = 0; ino = 0; kind = Reg; perm = 0o644; nlink = 1; uid = 0; gid = 0; rdev = 0;
                     size = String.length (content p v); atime = now; mtime = now; ctime = now }

(* a record in [n] bytes at [buf]: all of it, or, too small, its size
 * alone (the caller retries: libc's dirfstat) *)
let put_record p buf n r =
  if String.length r <= n then (Memory.write_string p.mem buf r; String.length r)
  else if n >= 2 then (Memory.write_string p.mem buf (String.sub r 0 2); 2)
  else raise (Error "stat buffer too small")

(* the fields a wstat changes (~0: unchanged): the mode, the length,
 * the name *)
let wstat p ~path ~fd r =
  let u16 o = Char.code r.[o] lor (Char.code r.[o + 1] lsl 8) in
  let u32 o = u16 o lor (u16 (o + 2) lsl 16) in
  let mode = u32 21 and len_lo = u32 33 and len_hi = u32 37 in
  let name_len = u16 41 in
  let name = String.sub r 43 name_len in
  let with_fd f = match fd with
    | Some fd -> f fd
    | None -> let fd = ok (p.host.openat None path 0 0) in Fun.protect ~finally:(fun () -> ignore (p.host.close fd)) (fun () -> f fd) in
  let ones = Bits.mask32 (-1) in
  if mode <> ones then with_fd (fun fd -> ok (p.host.fchmod fd (mode land 0o777)));
  if not (len_lo = ones && len_hi = ones) then
    with_fd (fun fd -> ok (p.host.ftruncate fd (len_lo lor (len_hi lsl 32))));
  if name <> "" && name <> Filename.basename path then
    ok (p.host.rename path (Filename.concat (Filename.dirname path) name))

(*****************************************************************************)
(* Reading and writing *)
(*****************************************************************************)

(* a directory read: whole stat records, as many as fit *)
let read_dir p fd (f : file) n =
  let b = Buffer.create n in
  let rec fill () =
    let e = match Hashtbl.find_opt p.dir_pending fd with
      | Some e -> Hashtbl.remove p.dir_pending fd; Some e
      | None -> ok (p.host.readdir fd) in
    match e with
    | None -> ()
    | Some { d_name = "." | ".."; _ } -> fill ()
    | Some e ->
        (match p.host.stat (Filename.concat f.path e.d_name) with
         | Error _ -> fill ()
         | Ok st ->
             let r = stat_record e.d_name st in
             if Buffer.length b + String.length r > n then Hashtbl.replace p.dir_pending fd e
             else (Buffer.add_string b r; fill ())) in
  fill ();
  if Buffer.length b = 0 && Hashtbl.mem p.dir_pending fd then raise (Error "buffer too small for a directory entry");
  Buffer.contents b

let is_dir p fd = match p.host.fstat fd with Ok st -> st.kind = Dir | Error _ -> false

(* at [off], or at the file's offset when -1 *)
let sys_pread p fd buf n off =
  let data =
    match file p fd with
    | Some { virt = Some Bintime; _ } -> be64 (Int64.of_float (p.host.now () *. 1e9))
    | Some ({ virt = Some _; _ } as f) ->
        let at = if off = -1 then f.offset else off in
        let s = if at >= String.length f.content then "" else String.sub f.content at (min n (String.length f.content - at)) in
        if off = -1 then f.offset <- f.offset + String.length s;
        s
    | Some f when is_dir p fd -> read_dir p fd f n
    | _ ->
        if off = -1 then ok (p.host.read fd n)
        else begin
          let cur = ok (p.host.lseek fd 0 1) in
          ignore (ok (p.host.lseek fd off 0));
          let s = ok (p.host.read fd n) in
          ignore (ok (p.host.lseek fd cur 0));
          s
        end in
  let data = if String.length data > n then String.sub data 0 n else data in
  Memory.write_string p.mem buf data;
  String.length data

let sys_pwrite p fd s off =
  match file p fd with
  | Some ({ virt = Some (Env name); _ } as f) ->
      let at = if off = -1 then f.offset else off in
      let c = f.content in
      let c = if at > String.length c then c ^ String.make (at - String.length c) '\000' else c in
      let after = if at + String.length s < String.length c then String.sub c (at + String.length s) (String.length c - at - String.length s) else "" in
      f.content <- String.sub c 0 at ^ s ^ after;
      if off = -1 then f.offset <- at + String.length s;
      Hashtbl.replace env name f.content;
      String.length s
  | Some { virt = Some (Note _); _ } -> Queue.add s p.notes; Linux.signal_waiting := true; String.length s
  | Some { virt = Some _; _ } -> raise (Error "permission denied")
  | _ ->
      if off = -1 then ok (p.host.write fd s)
      else begin
        let cur = ok (p.host.lseek fd 0 1) in
        ignore (ok (p.host.lseek fd off 0));
        let n = ok (p.host.write fd s) in
        ignore (ok (p.host.lseek fd cur 0));
        n
      end

let sys_seek p fd off whence =
  match file p fd with
  | Some ({ virt = Some _; _ } as f) ->
      let o = match whence with 0 -> off | 1 -> f.offset + off | _ -> String.length f.content + off in
      if o < 0 then raise (Error "negative offset");
      f.offset <- o; o
  | _ -> ok (p.host.lseek fd off whence)

(*****************************************************************************)
(* Processes *)
(*****************************************************************************)

(* the exit string's host status: 0 for none *)
let exits p msg =
  (match !exit_pipe with
   | Some fd -> ignore (p.host.write fd msg); ignore (p.host.close fd); exit_pipe := None
   | None -> ());
  raise (Linux.Exit (if msg = "" then 0 else 1))

let rfproc = 16 and rfmem = 32

let sys_rfork p flags =
  if flags land rfproc = 0 then 0
  else if flags land rfmem <> 0 then raise (Error "rfork: shared memory not supported")
  else begin
    let r, w = ok (p.host.pipe ()) in
    match ok (p.host.fork ()) with
    | 0 ->
        ignore (p.host.close r);
        (match !exit_pipe with Some fd -> ignore (p.host.close fd) | None -> ());
        Hashtbl.iter (fun _ fd -> ignore (p.host.close fd)) p.children;
        Hashtbl.reset p.children;
        exit_pipe := Some w;
        0
    | pid -> ignore (p.host.close w); Hashtbl.replace p.children pid r; pid
  end

(* Plan 9's quoting (%q): '' for the empty string, quotes doubled *)
let quote s =
  if s <> "" && not (String.exists (fun c -> c = ' ' || c = '\'' || c = '\t' || c = '\n') s) then s
  else "'" ^ String.concat "''" (String.split_on_char '\'' s) ^ "'"

(* "pid utime stime real msg", msg the child's exit string as the kernel
 * words it: "name pid: string" *)
let sys_await p =
  let pid, status = ok (p.host.wait4 (-1) 0) in
  let msg = match Hashtbl.find_opt p.children pid with
    | Some fd ->
        Hashtbl.remove p.children pid;
        let rec all acc = match p.host.read fd 256 with Ok "" | Error _ -> acc | Ok s -> all (acc ^ s) in
        let m = all "" in
        ignore (p.host.close fd); m
    | None -> if status = 0 then "" else "killed" in
  let msg = if msg = "" then "" else Printf.sprintf "%s %d: %s" p.name pid msg in
  Printf.sprintf "%d 0 0 0 %s" pid (quote msg)

(*****************************************************************************)
(* Notes *)
(*****************************************************************************)

let note_of_signal = function 14 -> Some "alarm" | 1 -> Some "hangup" | 2 -> Some "interrupt" | 15 -> Some "kill" | _ -> None

(* arm's Ureg: r0-r12, sp, lr, type, psr, pc *)
let ureg_words = 18
let errmax = 128

let psr (st : Arm32.state) =
  (if st.n then 1 lsl 31 else 0) lor (if st.z then 1 lsl 30 else 0) lor (if st.c then 1 lsl 29 else 0)
  lor (if st.v then 1 lsl 28 else 0) lor 0x10

(* between two instructions: the pending notes (the host's signals among
 * them), the first delivered to the handler notify() named, as
 * principia's kernel does: a Ureg and the note's text on the stack, the
 * handler called with them; a process without one dies of it *)
let deliver p (st : Arm32.state) ~pc =
  Linux.signal_waiting := false;
  List.iter (fun sg -> Option.iter (fun n -> Queue.add n p.notes) (note_of_signal sg)) (Linux.take_signals ());
  if p.handling = [] && not (Queue.is_empty p.notes) then begin
    let note = Queue.pop p.notes in
    if p.handler = 0 then exits p note
    else begin
      let m = p.mem and r = st.r in
      let ureg = Bits.mask32 (r.(13) - (4 * ureg_words)) in
      for i = 0 to 14 do Memory.store32 m (ureg + (4 * i)) r.(i) done;
      Memory.store32 m (ureg + 60) 0;
      Memory.store32 m (ureg + 64) (psr st);
      Memory.store32 m (ureg + 68) pc;
      let msg = ureg - errmax in
      let text = if String.length note >= errmax then String.sub note 0 (errmax - 1) else note in
      Memory.write_string m msg (text ^ "\000");
      let sp = msg - 12 in
      Memory.store32 m sp 0; Memory.store32 m (sp + 4) ureg; Memory.store32 m (sp + 8) msg;
      r.(0) <- ureg; r.(13) <- sp; r.(14) <- 0;
      p.handling <- { ureg; note } :: p.handling;
      st.next <- p.handler
    end
  end;
  if p.handling = [] && not (Queue.is_empty p.notes) then Linux.signal_waiting := true

(* noted(NCONT): the Ureg put back, the handler's changes included;
 * anything else: the default action, death *)
let sys_noted p (st : Arm32.state) v =
  match p.handling with
  | [] -> raise (Error "noted: no note being handled")
  | h :: rest ->
      if v <> 0 then exits p h.note
      else begin
        let m = p.mem and r = st.r in
        for i = 0 to 14 do r.(i) <- Memory.load32 m (h.ureg + (4 * i)) done;
        let f = Memory.load32 m (h.ureg + 64) in
        st.n <- f land (1 lsl 31) <> 0; st.z <- f land (1 lsl 30) <> 0;
        st.c <- f land (1 lsl 29) <> 0; st.v <- f land (1 lsl 28) <> 0;
        st.next <- Memory.load32 m (h.ureg + 68);
        p.handling <- rest;
        if not (Queue.is_empty p.notes) then Linux.signal_waiting := true
      end

(*****************************************************************************)
(* The system calls *)
(*****************************************************************************)

let names = [|
  "nop"; "rfork"; "exec"; "exits"; "await"; "brk"; "open"; "close"; "dup"; "fd2path"; "pread"; "pwrite"; "seek";
  "create"; "remove"; "chdir"; "stat"; "fstat"; "wstat"; "fwstat"; "bind"; "mount"; "unmount"; "sleep"; "alarm";
  "notify"; "noted"; "pipe"; "segattach"; "segdetach"; "segfree"; "segflush"; "segbrk"; "rendezvous";
  "semacquire"; "semrelease"; "tsemacquire"; "fversion"; "fauth"; "errstr" |]

let log_calls = ref false

(* arm: the number in r0, the arguments on the stack from sp+4, the
 * result in r0; an error: -1, its text in the process's errstr *)
let syscall p (st : Arm32.state) =
  let m = p.mem and h = p.host in
  let nr = st.r.(0) in
  let arg k = Memory.load32 m (Bits.mask32 (st.r.(13) + 4 + (4 * k))) in
  let sarg k = Bits.signed32 (arg k) in
  let vlong k = Int64.to_int (Int64.logor (Int64.of_int (arg k)) (Int64.shift_left (Int64.of_int (arg (k + 1))) 32)) in
  let str k = Memory.read_cstring m (arg k) in
  let strings a =
    let rec go a acc = match Memory.load32 m a with 0 -> List.rev acc | q -> go (Bits.mask32 (a + 4)) (Memory.read_cstring m q :: acc) in
    go a [] in
  let noted = ref false in
  let result =
    try
      match nr with
      | 0 -> 0
      | 1 -> sys_rfork p (arg 0)
      | 2 ->
          let env_list = Hashtbl.fold (fun k v acc -> (k ^ "=" ^ v) :: acc) env [] in
          raise (Linux.Exec (str 0, strings (arg 1), env_list))
      | 3 -> exits p (if arg 0 = 0 then "" else str 0)
      | 4 ->
          let s = sys_await p in
          let s = if String.length s > sarg 1 then String.sub s 0 (sarg 1) else s in
          Memory.write_string m (arg 0) s; String.length s
      | 5 ->                                                         (* brk *)
          (* from libc's end, inside the bss's last page: the heap
           * segment begins on the next *)
          let a = arg 0 in
          if Bits.ult32 a p.bss_end then raise (Error "brk below the bss");
          Memory.resize m "heap" ~size:(max 0 (round a - p.heap_base)); 0
      | 6 -> sys_open p (str 0) (arg 1)
      | 7 -> sys_close p (sarg 0); 0
      | 8 -> if sarg 1 < 0 then ok (h.dup (sarg 0)) else ok (h.dup2 (sarg 0) (sarg 1))
      | 9 ->                                                         (* fd2path *)
          let path = match file p (sarg 0) with Some f -> f.path | None -> raise (Error "fd out of range or not open") in
          if String.length path + 1 > sarg 2 then raise (Error "buffer too small");
          Memory.write_string m (arg 1) (path ^ "\000"); 0
      | 10 -> sys_pread p (sarg 0) (arg 1) (sarg 2) (vlong 3)
      | 11 -> sys_pwrite p (sarg 0) (Memory.read_string m (arg 1) (sarg 2)) (vlong 3)
      | 12 ->                                                        (* seek(ret*, fd, off, whence) *)
          let o = sys_seek p (sarg 1) (vlong 2) (sarg 4) in
          Memory.store32 m (arg 0) (Bits.mask32 o); Memory.store32 m (Bits.mask32 (arg 0 + 4)) (Bits.mask32 (o asr 32)); 0
      | 13 -> sys_create p (str 0) (arg 1) (arg 2)
      | 14 -> remove_path p (absolute p (str 0)); 0
      | 15 -> ok (h.chdir (str 0)); 0
      | 16 ->                                                        (* stat(name, buf, n) *)
          let path = absolute p (str 0) in
          let r = match virt_of p path with
            | Some v -> virt_stat p v
            | None -> stat_record (if path = "/" then "/" else Filename.basename path) (ok (h.stat path)) in
          put_record p (arg 1) (sarg 2) r
      | 17 ->                                                        (* fstat(fd, buf, n) *)
          let fd = sarg 0 in
          let r = match file p fd with
            | Some { virt = Some v; _ } -> virt_stat p v
            | Some f -> stat_record (if f.path = "/" then "/" else Filename.basename f.path) (ok (h.fstat fd))
            | None -> stat_record "" (ok (h.fstat fd)) in
          put_record p (arg 1) (sarg 2) r
      | 18 -> wstat p ~path:(absolute p (str 0)) ~fd:None (Memory.read_string m (arg 1) (sarg 2)); 0
      | 19 ->
          let fd = sarg 0 in
          let path = match file p fd with Some f -> f.path | None -> "" in
          wstat p ~path ~fd:(Some fd) (Memory.read_string m (arg 1) (sarg 2)); 0
      | 23 -> h.sleep (Float.of_int (sarg 0) /. 1000.); 0
      | 24 ->                                                        (* alarm(ms): the old one's remaining ms *)
          h.signal 14 Catch;
          let _, old = h.setitimer 0. (Float.of_int (sarg 0) /. 1000.) in
          int_of_float (Float.round (old *. 1000.))
      | 25 -> p.handler <- arg 0; 0
      | 26 -> noted := true; sys_noted p st (sarg 0); 0
      | 27 ->
          let a, b = ok (h.pipe ()) in
          ignore (add p a "#|/data" None ~rclose:false); ignore (add p b "#|/data1" None ~rclose:false);
          Memory.store32 m (arg 0) a; Memory.store32 m (Bits.mask32 (arg 0 + 4)) b; 0
      | 39 ->                                                        (* errstr(buf, n): exchanged *)
          let n = sarg 1 in
          let mine = Memory.read_cstring m (arg 0) in
          let old = if String.length p.errstr >= n then String.sub p.errstr 0 (max 0 (n - 1)) else p.errstr in
          Memory.write_string m (arg 0) (old ^ "\000");
          p.errstr <- mine; 0
      | n ->
          raise (Error (Printf.sprintf "system call %s not implemented" (if n < Array.length names then names.(n) else string_of_int n)))
    with Error e -> p.errstr <- e; -1 in
  if not !noted then st.r.(0) <- Bits.mask32 result;
  if !log_calls then
    prerr_endline (Printf.sprintf "[%d] %s(%s, %s, %s) = %d%s" (h.getpid ()) (if nr < Array.length names then names.(nr) else string_of_int nr)
                     (Bits.to_hex32 (arg 0)) (Bits.to_hex32 (arg 1)) (Bits.to_hex32 (arg 2)) result
                     (if result = -1 then " (" ^ p.errstr ^ ")" else ""))
