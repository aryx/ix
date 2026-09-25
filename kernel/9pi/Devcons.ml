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

let qdir = 0
let qcons = 1
let qnull = 2

let entries path =
  if path <> qdir then raise (Error enotdir)
  else [ { Dev.dname = "cons"; Dev.dqid = { path = qcons; vers = 0; typ = Qt_file }; Dev.dlength = 0; Dev.dperm = 0o660 };
         { Dev.dname = "null"; Dev.dqid = { path = qnull; vers = 0; typ = Qt_file }; Dev.dlength = 0; Dev.dperm = 0o666 } ]

let print s =
  for i = 0 to String.length s - 1 do
    if s.[i] = '\n' then Machine.uart_putc 13;
    Machine.putc s.[i]
  done

(*****************************************************************************)
(* Input *)
(*****************************************************************************)

(* the line being typed; the lines typed, not read yet (an empty one:
 * ^D alone, the end of file) *)
let line = Buffer.create 128
let lines = ref []

let enter () =
  lines := !lines @ [ Buffer.contents line ];
  Buffer.clear line;
  Proc.wakeup Console_input

let intr c =
  let c = if c = 13 then 10 else c in
  if c = 8 || c = 127 then begin
    let n = Buffer.length line in
    if n > 0 then begin
      let s = Buffer.contents line in
      Buffer.clear line;
      Buffer.add_string line (String.sub s 0 (n - 1));
      print "\b \b"
    end
  end
  else if c = 0x15 then begin Buffer.clear line; print "^U\n" end
  else if c = 4 then enter ()
  else begin
    let ch = Char.chr c in
    print (String.make 1 ch);
    Buffer.add_char line ch;
    if ch = '\n' then enter ()
  end

(* at most n bytes of the first line typed, once there is one *)
let rec read_cons n =
  match !lines with
  | [] -> Proc.sleep Console_input; read_cons n
  | l :: rest ->
      let k = min n (String.length l) in
      lines := (if k = String.length l then rest else String.sub l k (String.length l - k) :: rest);
      String.sub l 0 k

let init () =
  Dev.register {
    Dev.dc = 'c';
    Dev.attach = (fun _ -> Dev.attach 'c' { path = qdir; vers = 0; typ = Qt_dir });
    Dev.walk = Dev.walk_tab entries (fun _ -> { path = qdir; vers = 0; typ = Qt_dir });
    Dev.open_ = Dev.open_tab;
    Dev.read = (fun c n _ ->
      if c.qid.path = qcons then read_cons n
      else if c.qid.path = qnull then ""
      else raise (Error egreg));
    Dev.write = (fun c s _ ->
      if c.qid.path = qcons then print s
      else if c.qid.path <> qnull then raise (Error egreg);
      String.length s);
    Dev.close = (fun _ -> ());
  }
