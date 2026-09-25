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

(* the echo: a backspace erases; the rest as typed (^D too) *)
let backspace () = Machine.print "\b \b"
let echo c = Machine.putc (Char.chr c)

(* a character from the UART (consoleintr). A terminal sends CR for
 * Enter, which becomes the newline. (^P, xv6's process listing, is not
 * done.) *)
let intr c =
  if c = ctrl 'U' then
    while !e <> !w && Bytes.get input ((!e - 1) mod input_buf) <> '\n' do decr e; backspace () done
  else if c = ctrl 'H' || c = 0x7f then begin
    if !e <> !w then begin decr e; backspace () end
  end
  else if c <> 0 && c <> ctrl 'P' && !e - !r < input_buf then begin
    let c = if c = 0xd then 0xa else c in
    Bytes.set input (!e mod input_buf) (Char.chr c);
    incr e;
    echo c;
    if c = 0xa || c = ctrl 'D' || !e = !r + input_buf then begin
      w := !e;
      Proc.wakeup Console_input
    end
  end

(* Where a read's bytes go, where a write's come from: the user's memory
 * (Syscall's copyout and copyin), at an offset in the user's buffer:
 * [dst off s] false, [src off n] None, when out of reach; a read or a
 * write stops there, as xv6's either_copyout, either_copyin make it *)
type dst = int -> string -> bool
type src = int -> int -> string option

(* up to [n] bytes, a line at most; ^D ends it (and alone, reads 0); -1
 * killed while waiting. A byte that cannot be copied is consumed *)
let console_read n (dst : dst) =
  let left = ref n in
  let rec go () =
    if !left > 0 then begin
      if !r = !w then begin
        if (Proc.myproc ()).killed then false else begin Proc.sleep Console_input; go () end
      end
      else begin
        let c = Bytes.get input (!r mod input_buf) in
        incr r;
        if Char.code c = ctrl 'D' then begin
          (* kept for the next read, which returns 0 *)
          if !left < n then decr r;
          true
        end
        else if not (dst (n - !left) (String.make 1 c)) then true
        else begin
          decr left;
          if c = '\n' then true else go ()
        end
      end
    end
    else true in
  if go () then n - !left else -1

let console_write n (src : src) =
  let rec go i = if i >= n then i else match src i 1 with Some c -> Machine.print c; go (i + 1) | None -> i in
  go 0

(*****************************************************************************)
(* Pipes (pipe.c) *)
(*****************************************************************************)

(* -1 when the reader is gone, or killed, even after some bytes *)
let pipe_write p n (src : src) =
  let rec go i =
    if i >= n then i
    else if not p.readopen || (Proc.myproc ()).killed then -1
    else if p.nwrite = p.nread + pipesize then begin
      Proc.wakeup (Pipe_readable p);
      Proc.sleep (Pipe_writable p);
      go i
    end
    else match src i 1 with
      | None -> i
      | Some c ->
          Bytes.set p.pdata (p.nwrite mod pipesize) c.[0];
          p.nwrite <- p.nwrite + 1;
          go (i + 1) in
  let r = go 0 in
  Proc.wakeup (Pipe_readable p);
  r

(* -1 only when killed while it is empty; a byte that cannot be copied
 * is consumed *)
let pipe_read p n (dst : dst) =
  let rec wait () =
    if p.nread = p.nwrite && p.writeopen then begin
      if (Proc.myproc ()).killed then false else begin Proc.sleep (Pipe_readable p); wait () end
    end
    else true in
  if not (wait ()) then -1
  else begin
    let rec go i =
      if i >= n || p.nread = p.nwrite then i
      else begin
        let c = Bytes.get p.pdata (p.nread mod pipesize) in
        p.nread <- p.nread + 1;
        if dst i (String.make 1 c) then go (i + 1) else i
      end in
    let r = go 0 in
    Proc.wakeup (Pipe_writable p);
    r
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

(* the bytes read (copied by [dst]), or -1 *)
let read f n (dst : dst) =
  if not f.readable then -1
  else match f.kind with
    | Pipe_end p -> pipe_read p n dst
    | Device (_, major) -> if major = console then console_read n dst else -1
    | Inode_file ip ->
        let r = Fs.readi_to ip f.off n dst in
        if r > 0 then f.off <- f.off + r;
        r

(* the bytes written (from [src]), or -1. A file is written a few
 * blocks at a time (3: xv6's log transactions' size), and a short one
 * stops it: -1, what came before written *)
let write f n (src : src) =
  if not f.writable then -1
  else match f.kind with
    | Pipe_end p -> pipe_write p n src
    | Device (_, major) -> if major = console then console_write n src else -1
    | Inode_file ip ->
        let chunk = 3 * Fs.bsize in
        let rec go i =
          if i >= n then i
          else begin
            let n1 = min (n - i) chunk in
            let r = Fs.writei_from ip f.off n1 (fun o k -> src (i + o) k) in
            if r > 0 then f.off <- f.off + r;
            if r <> n1 then i else go (i + r)
          end in
        if n < 0 then -1 else if go 0 = n then n else -1

let inode f = match f.kind with Inode_file ip -> Some ip | Device (ip, _) -> Some ip | Pipe_end _ -> None
