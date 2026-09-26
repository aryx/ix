(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devcons.mli *)

open Types

(* consdir's qids, in its order *)
let files = [ "cons", 0o660; "consctl", 0o220; "bintime", 0o664; "cputime", 0o444; "null", 0o666;
              "pgrpid", 0o444; "pid", 0o444; "ppid", 0o444; "random", 0o444; "swap", 0o664;
              "time", 0o664; "user", 0o666; "zero", 0o444; "kmesg", 0o440; "kprint", 0o440 ]

let qdir = 0
let numsize = 12
let vlnumsize = 22

let qid_of name =
  let rec go i l = match l with
    | [] -> raise Not_found
    | (n, _) :: r -> if n = name then i else go (i + 1) r in
  go 1 files

let lengths = [ "bintime", 24; "cputime", 6 * numsize; "pgrpid", numsize; "pid", numsize; "ppid", numsize;
                "time", numsize + (3 * vlnumsize) ]

let entries path =
  if path <> qdir then raise (Error enotdir)
  else List.map (fun (name, perm) ->
    { Dev.dname = name; Dev.dqid = { path = qid_of name; vers = 0; typ = Qt_file };
      Dev.dlength = (try List.assoc name lengths with Not_found -> 0); Dev.dperm = perm }) files

let name_of path = fst (List.nth files (path - 1))

(*****************************************************************************)
(* Output *)
(*****************************************************************************)

let kmesg = Buffer.create 1024

let print s =
  for i = 0 to String.length s - 1 do
    if s.[i] = '\n' then Machine.uart_putc 13;
    Machine.putc s.[i]
  done

(*****************************************************************************)
(* Input *)
(*****************************************************************************)

(* raw (consctl's rawon): no echo, no editing *)
let raw = ref false

(* the line being typed; the lines typed, not read yet (an empty one:
 * ^D alone, the end of file) *)
let line = Buffer.create 128
let lines = ref []

let send () =
  lines := !lines @ [ Buffer.contents line ];
  Buffer.clear line;
  Proc.wakeup Console_input

(* a byte of input: echoed as it is (echo()), then kbd's editing *)
let input c =
  let ch = Char.chr c in
  if !raw then begin Buffer.add_char line ch; send () end
  else begin
    print (String.make 1 ch);
    if c = 8 then begin
      let n = Buffer.length line in
      if n > 0 then begin
        let s = Buffer.contents line in
        Buffer.clear line;
        Buffer.add_string line (String.sub s 0 (n - 1))
      end
    end
    else if c = 0x15 then Buffer.clear line
    else if c = 4 then send ()
    else begin Buffer.add_char line ch; if ch = '\n' then send () end
  end

(* a character from the serial line (kbdcr2nl: CR as LF) *)
let intr c = input (if c = 13 then 10 else c)

(* a character from the keyboard (kbdputc: a rune, its UTF-8 bytes) *)
let kbdputc r = let s = Dev.utf8 r in for i = 0 to String.length s - 1 do input (Char.code s.[i]) done

let rec read_cons n =
  match !lines with
  | [] -> Proc.sleep Console_input; read_cons n
  | l :: rest ->
      let k = min n (String.length l) in
      lines := (if k = String.length l then rest else String.sub l k (String.length l - k) :: rest);
      String.sub l 0 k

(*****************************************************************************)
(* The files *)
(*****************************************************************************)

(* readstr: [off, off+n) of a string *)
let readstr off n s = if off >= String.length s then "" else String.sub s off (min n (String.length s - off))

(* readnum: the number right-aligned in [size]-1 columns, a space *)
let pad size s = if String.length s >= size - 1 then s ^ " " else String.make (size - 1 - String.length s) ' ' ^ s ^ " "
let readnum off n v size = readstr off n (pad size (string_of_int v))

let read (c : chan) n off =
  let p = Proc.myproc () in
  match name_of c.qid.path with
  | "cons" -> read_cons n
  | "null" | "kprint" -> ""
  | "zero" -> String.make n '\000'
  | "pid" -> readnum off n p.pid numsize
  | "ppid" -> readnum off n p.parent numsize
  | "pgrpid" -> readnum off n 1 numsize
  | "user" -> readstr off n !Dev.eve
  | "kmesg" -> readstr off n (Buffer.contents kmesg)
  | "time" ->
      let secs = !Proc.ticks / 100 in
      readstr off n (pad numsize (string_of_int secs) ^ pad vlnumsize (string_of_int secs ^ "000000000")
                     ^ pad vlnumsize (string_of_int !Proc.ticks) ^ pad vlnumsize "100")
  | "cputime" ->
      let ms = (!Proc.ticks - p.start) * 10 in
      readstr off n (String.concat "" (List.map (fun v -> pad numsize (string_of_int v)) [ 0; 0; ms; 0; 0 ]))
  | "random" -> let r = String.make n '\000' in for i = 0 to n - 1 do String.set r i (Char.chr (Random.int 256)) done; r
  | "swap" -> readstr off n "117440512 memory\n4096 pagesize\n0 kernel\n0/28672 user\n0/0 swap\n0/0 kernel malloc\n0/0 kernel draw\n"
  | "bintime" -> String.make (min n 24) '\000'
  | _ -> raise (Error egreg)

(* the swap's pager started (its kernel process: a pid) *)
let kpager = ref false

let write (c : chan) s _ =
  (match name_of c.qid.path with
   | "cons" -> print s
   | "consctl" ->
       if s = "rawon" then raw := true
       else if s = "rawoff" then begin raw := false; if Buffer.length line > 0 then send () end
       else if s = "holdon" || s = "holdoff" then ()
       else raise (Error ebadctl)
   | "swap" -> if s = "start" && not !kpager then begin kpager := true; Proc.kproc "kpager" end
   | "null" | "time" | "bintime" -> ()
   | _ -> raise (Error eperm));
  String.length s

let init () =
  let root = { path = qdir; vers = 0; typ = Qt_dir } in
  let d = Dev.default 'c' "cons" in
  Dev.register { d with
    Dev.attach = (fun _ -> Dev.attach 'c' 0 root);
    Dev.walk = Dev.tab_walk entries (fun _ -> root);
    Dev.stat = Dev.tab_stat "#c" entries (fun _ -> root);
    Dev.dirs = Dev.tab_dirs entries;
    Dev.open_ = Dev.tab_open;
    Dev.read = read;
    Dev.write = write;
  }
