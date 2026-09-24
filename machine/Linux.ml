(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Linux.mli *)

type errno = int
type 'a r = ('a, errno) result
type kind = Reg | Dir | Chr | Blk | Fifo | Lnk | Sock
type stat = {
  dev : int; ino : int; kind : kind; perm : int; nlink : int; uid : int; gid : int; rdev : int;
  size : int; atime : float; mtime : float; ctime : float;
}
type dirent = { d_ino : int; d_name : string; d_kind : kind }
type disposition = Default | Ignore | Catch

type host = {
  read : int -> int -> string r;
  write : int -> string -> int r;
  openat : int option -> string -> int -> int -> int r;
  close : int -> unit r;
  fstat : int -> stat r;
  stat : string -> stat r;
  lseek : int -> int -> int -> int r;
  unlink : string -> unit r;
  rmdir : string -> unit r;
  chdir : string -> unit r;
  mkdir : string -> int -> unit r;
  access : string -> int -> unit r;
  fchmod : int -> int -> unit r;
  ftruncate : int -> int -> unit r;
  rename : string -> string -> unit r;
  dup : int -> int r;
  dup2 : int -> int -> int r;
  getcwd : unit -> string;
  getpid : unit -> int;
  pipe : unit -> (int * int) r;
  fork : unit -> int r;
  wait4 : int -> int -> (int * int) r;
  kill : int -> int -> unit r;
  readdir : int -> dirent option r;
  isatty : int -> bool;
  now : unit -> float;
  sleep : float -> unit;
  setitimer : float -> float -> float * float;
  signal : int -> disposition -> unit;
}

exception Exit of int
exception Exec of string * string list * string list

type proc = {
  host : host;
  mem : Memory.t;
  heap_base : int;
  handlers : (int, int) Hashtbl.t;           (* signal: the guest's handler *)
  dir_pending : (int, dirent) Hashtbl.t;     (* an entry getdents had no room for *)
  dir_offset : (int, int) Hashtbl.t;
  mutable in_handler : int list;             (* signals being handled: masked *)
}

(* 0xbf000000 and the trampoline's page, computed: a literal with bit
 * 31 set is truncated by js_of_ocaml (the same bits, with a warning) *)
let stack_top = Bits.mask32 (0xbf lsl 24)
let trampoline = Bits.mask32 (0xffff lsl 16)
let stack_size = 8 * 1024 * 1024
let page = 4096

let load host mem (elf : Elf.t) file argv envp =
  (* whole pages, as the kernel maps them: a program may use the rest of
   * its last page past its bss (goken's mem.exe does, its brk having
   * failed); segments sharing a page are one region *)
  let ranges = List.map (fun (s : Elf.segment) -> s.vaddr / page * page, (s.vaddr + s.memsz + page - 1) / page * page) elf.segments in
  let merged = List.fold_left (fun acc (lo, hi) ->
    match acc with
    | (plo, phi) :: rest when lo <= phi -> (plo, max hi phi) :: rest
    | _ -> (lo, hi) :: acc) [] (List.sort compare ranges) in
  List.iteri (fun i (lo, hi) -> Memory.map mem ~base:lo ~size:(hi - lo) (Printf.sprintf "seg%d" i)) merged;
  List.iter (fun (s : Elf.segment) -> Memory.write_string mem s.vaddr (String.sub file s.offset s.filesz)) elf.segments;
  (* the heap: from the page after the last segment, empty, grown by brk *)
  let heap = List.fold_left (fun acc (_, hi) -> max acc hi) 0 merged in
  Memory.map mem ~base:heap ~size:0 "heap";
  Memory.map mem ~base:(Bits.mask32 (stack_top - stack_size)) ~size:stack_size "stack";
  (* the signal trampoline: arm32's mov r7, #119 (sigreturn); svc 0;
   * arm64's mov x8, #139 (rt_sigreturn); svc #0 *)
  let wide = elf.machine = Elf.Aarch64 in
  Memory.map mem ~base:trampoline ~size:8 "trampoline";
  if wide then begin
    Memory.store32 mem trampoline (Bits.mask32 ((0xd280 lsl 16) lor 0x1168));
    Memory.store32 mem (trampoline + 4) (Bits.mask32 ((0xd400 lsl 16) lor 1))
  end else begin
    Memory.store32 mem trampoline (Bits.mask32 ((0xe3a0 lsl 16) lor 0x7077));
    Memory.store32 mem (trampoline + 4) (Bits.mask32 (0xef lsl 24))
  end;
  (* the strings at the top, then the vectors below them *)
  let sp = ref stack_top in
  let push_string s = sp := Bits.mask32 (!sp - (String.length s + 1)); Memory.write_string mem !sp (s ^ "\000"); !sp in
  let argp = List.map push_string argv and envpp = List.map push_string envp in
  sp := Bits.mask32 (!sp - 16);
  let random = !sp in
  Memory.write_string mem random "0123456789abcdef";
  let words = [ List.length argv ] @ argp @ [ 0 ] @ envpp @ [ 0 ] @ [ 6; page; 9; elf.entry; 25; random; 0; 0 ] in
  (* arm64's are 8 bytes, the addresses below 4GB *)
  let size = if wide then 8 else 4 in
  sp := Bits.mask32 ((!sp - (size * List.length words)) land lnot 15);
  List.iteri (fun i w ->
    let a = Bits.mask32 (!sp + (size * i)) in
    if wide then Memory.store64 mem a (Int64.logand (Int64.of_int w) 0xffffffffL) else Memory.store32 mem a w) words;
  let proc = { host; mem; heap_base = heap; handlers = Hashtbl.create 8; dir_pending = Hashtbl.create 4;
               dir_offset = Hashtbl.create 4; in_handler = [] } in
  proc, elf.entry, !sp

(*****************************************************************************)
(* The guest's structures *)
(*****************************************************************************)

let enosys = 38 and enotty = 25

let put32 mem a v = Memory.store32 mem (Bits.mask32 a) (Bits.mask32 v)
let put64 mem a v = put32 mem a v; put32 mem (a + 4) (if v < 0 then -1 else 0)
let put16 mem a v = Memory.store16 mem (Bits.mask32 a) v
let put8 mem a v = Memory.store8 mem (Bits.mask32 a) v

let kind_bits = function
  | Reg -> 0o100000 | Dir -> 0o040000 | Chr -> 0o020000 | Blk -> 0o060000 | Fifo -> 0o010000 | Lnk -> 0o120000 | Sock -> 0o140000

let dtype = function Reg -> 8 | Dir -> 4 | Chr -> 2 | Blk -> 6 | Fifo -> 1 | Lnk -> 10 | Sock -> 12

let secs t = int_of_float (Float.round (Float.of_int (int_of_float t)))
let nsecs t = int_of_float ((t -. Float.of_int (int_of_float t)) *. 1e9)

(* struct stat64, arm32 *)
let write_stat64 mem a st =
  for i = 0 to 25 do put32 mem (a + (4 * i)) 0 done;
  put64 mem a st.dev;
  put32 mem (a + 12) st.ino;
  put32 mem (a + 16) (kind_bits st.kind lor st.perm);
  put32 mem (a + 20) st.nlink;
  put32 mem (a + 24) st.uid;
  put32 mem (a + 28) st.gid;
  put64 mem (a + 32) st.rdev;
  put64 mem (a + 48) st.size;
  put32 mem (a + 56) 4096;
  put64 mem (a + 64) ((st.size + 511) / 512);
  put32 mem (a + 72) (secs st.atime); put32 mem (a + 76) (nsecs st.atime);
  put32 mem (a + 80) (secs st.mtime); put32 mem (a + 84) (nsecs st.mtime);
  put32 mem (a + 88) (secs st.ctime); put32 mem (a + 92) (nsecs st.ctime);
  put64 mem (a + 96) st.ino

(*****************************************************************************)
(* The system calls, arm32 *)
(*****************************************************************************)

let pending : int list ref = ref []
let signal_waiting = ref false
let raise_signal n = pending := !pending @ [ n ]; signal_waiting := true
let take_signals () = let l = !pending in pending := []; l

let string_list mem a =
  let rec go a acc = match Memory.load32 mem a with 0 -> List.rev acc | p -> go (Bits.mask32 (a + 4)) (Memory.read_cstring mem p :: acc) in
  if a = 0 then [] else go a []

let at_fdcwd = Bits.mask32 (-100)

let log_calls = ref false

(* the directory entries of [fd] that fit in [size] bytes at [buf], as
 * struct linux_dirent64 (the same on both); one that does not fit is
 * kept for the next call *)
let getdents p fd buf size =
  let m = p.mem and h = p.host in
  let used = ref 0 and err = ref 0 in
  let rec fill () =
    let e = match Hashtbl.find_opt p.dir_pending fd with
      | Some e -> Hashtbl.remove p.dir_pending fd; Ok (Some e)
      | None -> h.readdir fd in
    match e with
    | Error e -> if !used = 0 then err := e
    | Ok None -> ()
    | Ok (Some e) ->
        let reclen = (19 + String.length e.d_name + 1 + 7) land lnot 7 in
        if !used + reclen > size then Hashtbl.replace p.dir_pending fd e
        else begin
          let a = buf + !used in
          let off = 1 + Option.value (Hashtbl.find_opt p.dir_offset fd) ~default:0 in
          Hashtbl.replace p.dir_offset fd off;
          for i = 0 to (reclen / 4) - 1 do put32 m (a + (4 * i)) 0 done;
          put64 m a e.d_ino;
          put64 m (a + 8) off;
          put16 m (a + 16) reclen;
          put8 m (a + 18) (dtype e.d_kind);
          Memory.write_string m (Bits.mask32 (a + 19)) (e.d_name ^ "\000");
          used := !used + reclen;
          fill ()
        end in
  fill ();
  if !err <> 0 then - !err else !used

(* brk: the heap's end, grown or shrunk to [a] *)
let brk p a =
  let cur = Memory.segment_end p.mem "heap" in
  if a = 0 || Bits.ult32 a p.heap_base then cur
  else (Memory.resize p.mem "heap" ~size:(a - p.heap_base); a)


let syscall32 p (st : Arm32.state) =
  let r = st.r and m = p.mem and h = p.host in
  let args = (r.(7), r.(0), r.(1), r.(2)) in
  let unit = function Ok () -> 0 | Error e -> - e in
  let int = function Ok n -> n | Error e -> - e in
  let str a = Memory.read_cstring m a in
  let result =
    match r.(7) with
    | 1 | 248 ->                                                       (* exit, exit_group *)
        if !log_calls then prerr_endline (Printf.sprintf "[%d] %d(%s, 0x0, 0x0) = 0" (h.getpid ()) r.(7) (Bits.to_hex32 r.(0)));
        raise (Exit (r.(0) land 0xff))
    | 2 -> int (h.fork ())
    | 3 -> (match h.read r.(0) r.(2) with Ok s -> Memory.write_string m r.(1) s; String.length s | Error e -> - e)
    | 4 -> int (h.write r.(0) (Memory.read_string m r.(1) r.(2)))
    | 5 -> int (h.openat None (str r.(0)) r.(1) r.(2))                  (* open *)
    | 322 -> int (h.openat (if r.(0) = at_fdcwd then None else Some r.(0)) (str r.(1)) r.(2) r.(3))  (* openat *)
    | 6 -> Hashtbl.remove p.dir_pending r.(0); Hashtbl.remove p.dir_offset r.(0); unit (h.close r.(0))
    | 10 -> unit (h.unlink (str r.(0)))
    | 11 -> raise (Exec (str r.(0), string_list m r.(1), string_list m r.(2)))
    | 12 -> unit (h.chdir (str r.(0)))
    | 19 -> int (h.lseek r.(0) (Bits.signed32 r.(1)) r.(2))
    | 20 -> h.getpid ()
    | 33 -> unit (h.access (str r.(0)) r.(1))
    | 37 -> unit (h.kill (Bits.signed32 r.(0)) r.(1))
    | 39 -> unit (h.mkdir (str r.(0)) r.(1))
    | 40 -> unit (h.rmdir (str r.(0)))
    | 41 -> int (h.dup r.(0))
    | 42 -> (match h.pipe () with Ok (a, b) -> put32 m r.(0) a; put32 m (r.(0) + 4) b; 0 | Error e -> - e)
    | 45 -> brk p r.(0)
    | 54 -> if h.isatty r.(0) then 0 else - enotty                       (* ioctl: isatty's TCGETS *)
    | 63 -> int (h.dup2 r.(0) r.(1))
    | 94 -> unit (h.fchmod r.(0) r.(1))
    | 104 ->                                                           (* setitimer *)
        let tv a = Float.of_int (Memory.load32 m a) +. (Float.of_int (Memory.load32 m (a + 4)) /. 1e6) in
        let oi, ov = h.setitimer (tv r.(1)) (tv (r.(1) + 8)) in
        if r.(2) <> 0 then begin
          let put a t = put32 m a (int_of_float t); put32 m (a + 4) (int_of_float ((t -. Float.of_int (int_of_float t)) *. 1e6)) in
          put r.(2) oi; put (r.(2) + 8) ov
        end;
        0
    | 114 ->                                                           (* wait4 *)
        (match h.wait4 (Bits.signed32 r.(0)) r.(2) with
         | Ok (pid, status) -> if r.(1) <> 0 then put32 m r.(1) status; pid
         | Error e -> - e)
    | 119 | 173 ->                                                     (* sigreturn, rt_sigreturn *)
        let frame = r.(13) in
        for i = 0 to 15 do r.(i) <- Memory.load32 m (Bits.mask32 (frame + (4 * i))) done;
        let f = Memory.load32 m (Bits.mask32 (frame + 64)) in
        st.n <- f land 8 <> 0; st.z <- f land 4 <> 0; st.c <- f land 2 <> 0; st.v <- f land 1 <> 0;
        (match p.in_handler with _ :: rest -> p.in_handler <- rest | [] -> ());
        if !pending <> [] then signal_waiting := true;
        st.next <- r.(15);
        r.(0)
    | 174 ->                                                           (* rt_sigaction *)
        let sg = r.(0) in
        if r.(2) <> 0 then begin
          put32 m r.(2) (Option.value (Hashtbl.find_opt p.handlers sg) ~default:0);
          for i = 1 to 4 do put32 m (r.(2) + (4 * i)) 0 done
        end;
        if r.(1) <> 0 then begin
          let handler = Memory.load32 m r.(1) in
          (match handler with
           | 0 -> Hashtbl.remove p.handlers sg; h.signal sg Default
           | 1 -> Hashtbl.remove p.handlers sg; h.signal sg Ignore
           | a -> Hashtbl.replace p.handlers sg a; h.signal sg Catch)
        end;
        0
    | 183 ->                                                           (* getcwd *)
        let d = h.getcwd () in
        if String.length d + 1 > r.(1) then - 34 else (Memory.write_string m r.(0) (d ^ "\000"); String.length d + 1)
    | 194 -> unit (h.ftruncate r.(0) r.(2))                             (* ftruncate64: the length in r2:r3 *)
    | 197 -> (match h.fstat r.(0) with Ok s -> write_stat64 m r.(1) s; 0 | Error e -> - e)
    | 217 -> getdents p r.(0) r.(1) r.(2)                                 (* getdents64 *)
    | 382 -> unit (h.rename (str r.(1)) (str r.(3)))                     (* renameat2 *)
    | 403 ->                                                           (* clock_gettime64 *)
        let t = h.now () in
        put64 m r.(1) (int_of_float t);
        put64 m (r.(1) + 8) (nsecs t);
        0
    | 407 ->                                                           (* clock_nanosleep_time64 *)
        let t = Float.of_int (Memory.load32 m r.(2)) +. (Float.of_int (Memory.load32 m (r.(2) + 8)) /. 1e9) in
        let d = if r.(1) land 1 <> 0 then t -. h.now () else t in
        if d > 0. then h.sleep d;
        0
    | n -> prerr_endline (Printf.sprintf "tinyarm: unimplemented system call %d" n); - enosys in
  if r.(7) <> 119 && r.(7) <> 173 then r.(0) <- Bits.mask32 result;
  if !log_calls then
    let nr, a, b, c = args in
    prerr_endline (Printf.sprintf "[%d] %d(%s, %s, %s) = %d" (h.getpid ()) nr (Bits.to_hex32 a) (Bits.to_hex32 b) (Bits.to_hex32 c) (Bits.signed32 r.(0)))

(*****************************************************************************)
(* The system calls, arm64 *)
(*****************************************************************************)

(* arm64's are asm-generic's: the *at calls only, clone for fork, the
 * structures with 64-bit longs *)

let put64w m a v = Memory.store64 m (Bits.mask32 a) (Int64.of_int v)

(* struct stat, asm-generic (128 bytes) *)
let write_stat_generic mem a st =
  for i = 0 to 15 do put64w mem (a + (8 * i)) 0 done;
  put64w mem a st.dev;
  put64w mem (a + 8) st.ino;
  put32 mem (a + 16) (kind_bits st.kind lor st.perm);
  put32 mem (a + 20) st.nlink;
  put32 mem (a + 24) st.uid;
  put32 mem (a + 28) st.gid;
  put64w mem (a + 32) st.rdev;
  put64w mem (a + 48) st.size;
  put32 mem (a + 56) 4096;
  put64w mem (a + 64) ((st.size + 511) / 512);
  put64w mem (a + 72) (secs st.atime); put64w mem (a + 80) (nsecs st.atime);
  put64w mem (a + 88) (secs st.mtime); put64w mem (a + 96) (nsecs st.mtime);
  put64w mem (a + 104) (secs st.ctime); put64w mem (a + 112) (nsecs st.ctime)

let at_removedir = 0x200

let syscall64 p (st : Arm64.state) =
  let m = p.mem and h = p.host in
  let arg k = Arm64.get st k in
  (* a pointer, below 4GB; a C int; a long *)
  let ptr k = Bits.mask32 (Int64.to_int (arg k)) in
  let int k = Bits.signed32 (Bits.mask32 (Int64.to_int (arg k))) in
  let long k = Int64.to_int (arg k) in
  let nr = long 8 in
  let args = (arg 0, arg 1, arg 2) in
  let unit = function Ok () -> 0 | Error e -> - e in
  let res = function Ok n -> n | Error e -> - e in
  let str k = Memory.read_cstring m (ptr k) in
  let dirfd k = if int k = -100 then None else Some (int k) in
  let strings a =
    let rec go a acc = match Memory.load64 m a with 0L -> List.rev acc | q -> go (Bits.mask32 (a + 8)) (Memory.read_cstring m (Arm64.address q) :: acc) in
    if a = 0 then [] else go a [] in
  let timeval a = Float.of_int (Int64.to_int (Memory.load64 m a)) +. (Float.of_int (Int64.to_int (Memory.load64 m (a + 8))) /. 1e6) in
  let result =
    match nr with
    | 93 | 94 ->                                                       (* exit, exit_group *)
        if !log_calls then prerr_endline (Printf.sprintf "[%d] %d(0x%Lx, 0x0, 0x0) = 0" (h.getpid ()) nr (arg 0));
        raise (Exit (int 0 land 0xff))
    | 220 -> res (h.fork ())                                            (* clone, as fork *)
    | 63 -> (match h.read (int 0) (long 2) with Ok s -> Memory.write_string m (ptr 1) s; String.length s | Error e -> - e)
    | 64 -> res (h.write (int 0) (Memory.read_string m (ptr 1) (long 2)))
    | 56 -> res (h.openat (dirfd 0) (str 1) (int 2) (int 3))
    | 57 -> Hashtbl.remove p.dir_pending (int 0); Hashtbl.remove p.dir_offset (int 0); unit (h.close (int 0))
    | 35 -> if int 2 land at_removedir <> 0 then unit (h.rmdir (str 1)) else unit (h.unlink (str 1))  (* unlinkat *)
    | 221 -> raise (Exec (str 0, strings (ptr 1), strings (ptr 2)))
    | 49 -> unit (h.chdir (str 0))
    | 62 -> res (h.lseek (int 0) (long 1) (int 2))
    | 172 -> h.getpid ()
    | 48 -> unit (h.access (str 1) (int 2))                             (* faccessat *)
    | 129 -> unit (h.kill (int 0) (int 1))
    | 34 -> unit (h.mkdir (str 1) (int 2))                              (* mkdirat *)
    | 23 -> res (h.dup (int 0))
    | 24 -> res (h.dup2 (int 0) (int 1))                                (* dup3 *)
    | 59 -> (match h.pipe () with Ok (a, b) -> put32 m (ptr 0) a; put32 m (ptr 0 + 4) b; 0 | Error e -> - e)  (* pipe2 *)
    | 214 -> brk p (ptr 0)
    | 29 -> if h.isatty (int 0) then 0 else - enotty                   (* ioctl *)
    | 52 -> unit (h.fchmod (int 0) (int 1))
    | 103 ->                                                           (* setitimer *)
        let oi, ov = h.setitimer (timeval (ptr 1)) (timeval (ptr 1 + 16)) in
        if ptr 2 <> 0 then begin
          let put a t = put64w m a (int_of_float t); put64w m (a + 8) (int_of_float ((t -. Float.of_int (int_of_float t)) *. 1e6)) in
          put (ptr 2) oi; put (ptr 2 + 16) ov
        end;
        0
    | 260 ->                                                           (* wait4 *)
        (match h.wait4 (int 0) (int 2) with
         | Ok (pid, status) -> if ptr 1 <> 0 then put32 m (ptr 1) status; pid
         | Error e -> - e)
    | 139 ->                                                           (* rt_sigreturn *)
        let frame = Arm64.address (Arm64.get_sp st 31) in
        for i = 0 to 30 do Arm64.set st Arm64.X i (Memory.load64 m (frame + (8 * i))) done;
        let pc = Arm64.address (Memory.load64 m (frame + (8 * 32))) in
        let f = Int64.to_int (Memory.load64 m (frame + (8 * 33))) in
        st.n <- f land 8 <> 0; st.z <- f land 4 <> 0; st.c <- f land 2 <> 0; st.v <- f land 1 <> 0;
        Arm64.set_sp st Arm64.X 31 (Memory.load64 m (frame + (8 * 31)));
        (match p.in_handler with _ :: rest -> p.in_handler <- rest | [] -> ());
        if !pending <> [] then signal_waiting := true;
        st.next <- pc;
        long 0
    | 134 ->                                                           (* rt_sigaction *)
        let sg = int 0 in
        if ptr 2 <> 0 then begin
          put64w m (ptr 2) (Option.value (Hashtbl.find_opt p.handlers sg) ~default:0);
          for i = 1 to 3 do put64w m (ptr 2 + (8 * i)) 0 done
        end;
        if ptr 1 <> 0 then begin
          (match Arm64.address (Memory.load64 m (ptr 1)) with
           | 0 -> Hashtbl.remove p.handlers sg; h.signal sg Default
           | 1 -> Hashtbl.remove p.handlers sg; h.signal sg Ignore
           | a -> Hashtbl.replace p.handlers sg a; h.signal sg Catch)
        end;
        0
    | 17 ->                                                            (* getcwd *)
        let d = h.getcwd () in
        if String.length d + 1 > long 1 then - 34 else (Memory.write_string m (ptr 0) (d ^ "\000"); String.length d + 1)
    | 46 -> unit (h.ftruncate (int 0) (long 1))
    | 80 -> (match h.fstat (int 0) with Ok s -> write_stat_generic m (ptr 1) s; 0 | Error e -> - e)
    | 61 -> getdents p (int 0) (ptr 1) (long 2)
    | 38 | 276 -> unit (h.rename (str 1) (str 3))                        (* renameat, renameat2 *)
    | 113 ->                                                           (* clock_gettime *)
        let t = h.now () in
        put64w m (ptr 1) (int_of_float t);
        put64w m (ptr 1 + 8) (nsecs t);
        0
    | 115 ->                                                           (* clock_nanosleep *)
        let a = ptr 2 in
        let t = Float.of_int (Int64.to_int (Memory.load64 m a)) +. (Float.of_int (Int64.to_int (Memory.load64 m (a + 8))) /. 1e9) in
        let d = if int 1 land 1 <> 0 then t -. h.now () else t in
        if d > 0. then h.sleep d;
        0
    | n -> prerr_endline (Printf.sprintf "tinyarm: unimplemented system call %d" n); - enosys in
  if nr <> 139 then Arm64.set st Arm64.X 0 (Int64.of_int result);
  if !log_calls then
    let a, b, c = args in
    prerr_endline (Printf.sprintf "[%d] %d(0x%Lx, 0x%Lx, 0x%Lx) = %Ld" (h.getpid ()) nr a b c (Arm64.get st 0))

(*****************************************************************************)
(* Signals *)
(*****************************************************************************)

let deliver p (st : Arm32.state) ~pc =
  signal_waiting := false;
  match List.find_opt (fun s -> not (List.mem s p.in_handler)) !pending with
  | None -> ()
  | Some sg ->
      pending := List.filter (( <> ) sg) !pending;
      if !pending <> [] then signal_waiting := true;
      (match Hashtbl.find_opt p.handlers sg with
       | None -> ()
       | Some handler ->
           let r = st.r and m = p.mem in
           let frame = Bits.mask32 ((r.(13) - 72) land lnot 7) in
           r.(15) <- pc;
           for i = 0 to 15 do put32 m (frame + (4 * i)) r.(i) done;
           put32 m (frame + 64) ((if st.n then 8 else 0) lor (if st.z then 4 else 0) lor (if st.c then 2 else 0) lor (if st.v then 1 else 0));
           r.(13) <- frame;
           r.(0) <- sg; r.(1) <- 0; r.(2) <- 0;
           r.(14) <- trampoline;
           p.in_handler <- sg :: p.in_handler;
           st.next <- handler)

(* arm64's frame: x0-x30, sp, pc, the flags, 8 bytes each *)
let deliver64 p (st : Arm64.state) ~pc =
  signal_waiting := false;
  match List.find_opt (fun s -> not (List.mem s p.in_handler)) !pending with
  | None -> ()
  | Some sg ->
      pending := List.filter (( <> ) sg) !pending;
      if !pending <> [] then signal_waiting := true;
      (match Hashtbl.find_opt p.handlers sg with
       | None -> ()
       | Some handler ->
           let m = p.mem in
           let frame = Bits.mask32 ((Arm64.address (Arm64.get_sp st 31) - (34 * 8)) land lnot 15) in
           for i = 0 to 30 do Memory.store64 m (frame + (8 * i)) (Arm64.get st i) done;
           Memory.store64 m (frame + (8 * 31)) (Arm64.get_sp st 31);
           Memory.store64 m (frame + (8 * 32)) (Arm64.of_address pc);
           Memory.store64 m (frame + (8 * 33))
             (Int64.of_int ((if st.n then 8 else 0) lor (if st.z then 4 else 0) lor (if st.c then 2 else 0) lor (if st.v then 1 else 0)));
           Arm64.set_sp st Arm64.X 31 (Arm64.of_address frame);
           Arm64.set st Arm64.X 0 (Int64.of_int sg);
           Arm64.set st Arm64.X 1 0L;
           Arm64.set st Arm64.X 2 0L;
           Arm64.set st Arm64.X 30 (Arm64.of_address trampoline);
           p.in_handler <- sg :: p.in_handler;
           st.next <- handler)
