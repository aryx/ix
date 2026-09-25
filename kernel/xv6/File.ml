(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See File.mli *)

open Types

let nfile = 100
let pipesize = 512

(*****************************************************************************)
(* The console (console.c) *)
(*****************************************************************************)

(* the input line: typed characters, edited until a newline (or ^D, or a
 * full buffer) hands them to the readers; r read, w written (handed),
 * e edited, counting forever *)
let input_buf = 128
let input = Bytes.create input_buf
let r = ref 0
let w = ref 0
let e = ref 0

let ctrl c = Char.code c - Char.code '@'

(* the echo: a backspace erases, ^D shows *)
let backspace () = Machine.print "\b \b"
let echo c = if c = ctrl 'D' then Machine.print "^D" else Machine.putc (Char.chr c)

(* a character from the UART (consoleintr). Its line discipline is xv6
 * arm-pi1's: a terminal sends CR for Enter, which becomes the newline;
 * a raw LF is dropped. (^P, xv6's process listing, is not done.) *)
let intr c =
  if c = ctrl 'U' then
    while !e <> !w && Bytes.get input ((!e - 1) mod input_buf) <> '\n' do decr e; backspace () done
  else if c = ctrl 'H' || c = 0x7f then begin
    if !e <> !w then begin decr e; backspace () end
  end
  else if c <> 0 && c <> 0xa && c <> ctrl 'P' && !e - !r < input_buf then begin
    let c = if c = 0xd then 0xa else c in
    Bytes.set input (!e mod input_buf) (Char.chr c);
    incr e;
    echo c;
    if c = 0xa || c = ctrl 'D' || !e = !r + input_buf then begin
      w := !e;
      Proc.wakeup Console_input
    end
  end

(* up to [n] bytes, a line at most; ^D ends it (and alone, reads 0) *)
let console_read n =
  let b = Buffer.create n in
  let rec go () =
    if Buffer.length b >= n then Some (Buffer.contents b)
    else if !r = !w then begin
      if (Proc.myproc ()).killed then None
      else begin Proc.sleep Console_input; go () end
    end
    else begin
      let c = Bytes.get input (!r mod input_buf) in
      incr r;
      if Char.code c = ctrl 'D' then begin
        (* kept for the next read, which returns 0 *)
        if Buffer.length b > 0 then decr r;
        Some (Buffer.contents b)
      end
      else begin
        Buffer.add_char b c;
        if c = '\n' then Some (Buffer.contents b) else go ()
      end
    end in
  go ()

let console_write s = Machine.print s; String.length s

(*****************************************************************************)
(* Pipes (pipe.c) *)
(*****************************************************************************)

let pipe_write p s =
  let n = String.length s in
  let rec go i =
    if i = n then begin Proc.wakeup (Pipe_readable p); n end
    else if p.nwrite = p.nread + pipesize then begin
      if not p.readopen || (Proc.myproc ()).killed then -1
      else begin
        Proc.wakeup (Pipe_readable p);
        Proc.sleep (Pipe_writable p);
        go i
      end
    end
    else begin
      Bytes.set p.pdata (p.nwrite mod pipesize) s.[i];
      p.nwrite <- p.nwrite + 1;
      go (i + 1)
    end in
  go 0

let pipe_read p n =
  let rec wait () =
    if p.nread = p.nwrite && p.writeopen then begin
      if (Proc.myproc ()).killed then false else begin Proc.sleep (Pipe_readable p); wait () end
    end
    else true in
  if not (wait ()) then None
  else begin
    let b = Buffer.create n in
    while Buffer.length b < n && p.nread <> p.nwrite do
      Buffer.add_char b (Bytes.get p.pdata (p.nread mod pipesize));
      p.nread <- p.nread + 1
    done;
    Proc.wakeup (Pipe_writable p);
    Some (Buffer.contents b)
  end

let pipe_close p writable =
  if writable then begin p.writeopen <- false; Proc.wakeup (Pipe_readable p) end
  else begin p.readopen <- false; Proc.wakeup (Pipe_writable p) end

(*****************************************************************************)
(* The file table (file.c) *)
(*****************************************************************************)

(* the open files: NFILE at most *)
let nopen = ref 0

let alloc kind readable writable =
  if !nopen >= nfile then None
  else begin
    incr nopen;
    Some { kind = kind; fref = 1; readable = readable; writable = writable; off = 0 }
  end

let dup f = f.fref <- f.fref + 1; f

let close f =
  f.fref <- f.fref - 1;
  if f.fref = 0 then begin
    decr nopen;
    match f.kind with
    | Pipe_end p -> pipe_close p f.writable
    | Inode_file ip -> Fs.iput ip
    | Device (ip, _) -> Fs.iput ip
  end

(* a pipe's two ends, reading and writing *)
let pipe () =
  match alloc (Pipe_end { pdata = Bytes.create pipesize; nread = 0; nwrite = 0; readopen = true; writeopen = true })
          true false with
  | None -> None
  | Some rf ->
      let p = match rf.kind with Pipe_end p -> p | _ -> assert false in
      match alloc (Pipe_end p) false true with
      | Some wf -> Some (rf, wf)
      | None -> close rf; None

(* the devices: the console, major 1 *)
let console = 1

let read f n =
  if not f.readable then None
  else match f.kind with
    | Pipe_end p -> pipe_read p n
    | Device (_, major) -> if major = console then console_read n else None
    | Inode_file ip ->
        match Fs.readi ip f.off n with
        | Some s -> f.off <- f.off + String.length s; Some s
        | None -> None

(* xv6 writes a file a few blocks at a time, each a transaction of its
 * log; without a log, at once *)
let write f s =
  if not f.writable then -1
  else match f.kind with
    | Pipe_end p -> pipe_write p s
    | Device (_, major) -> if major = console then console_write s else -1
    | Inode_file ip ->
        let r = Fs.writei ip f.off s in
        if r > 0 then f.off <- f.off + r;
        r

let inode f = match f.kind with Inode_file ip -> Some ip | Device (ip, _) -> Some ip | Pipe_end _ -> None
