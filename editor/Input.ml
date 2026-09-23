(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Input.mli *)

exception Error of string

let eof = -1
let nl = Char.code '\n'

type source = Fd of Unix.file_descr | Str of string * int ref

type t = {
  src : source;
  mutable peekc : int option;
  mutable lastc : int;
  mutable globp : (string * int ref) option;
}

let of_fd fd = { src = Fd fd; peekc = None; lastc = 0; globp = None }
let of_string s = { src = Str (s, ref 0); peekc = None; lastc = 0; globp = None }

(* a rune of a string, from !i *)
let from_string s i =
  if !i >= String.length s then eof
  else begin
    let d = String.get_utf_8_uchar s !i in
    i := !i + Uchar.utf_decode_length d;
    Uchar.to_int (Uchar.utf_decode_uchar d)
  end

let byte = Bytes.create 1

let rec read_byte fd =
  match Unix.read fd byte 0 1 with
  | 1 -> Some (Bytes.get byte 0)
  | _ -> None
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_byte fd

(* a rune from the fd: its first byte says how many follow *)
let from_fd fd =
  match read_byte fd with
  | None -> eof
  | Some c ->
      let n = match Char.code c with b when b < 0xc0 -> 0 | b when b < 0xe0 -> 1 | b when b < 0xf0 -> 2 | _ -> 3 in
      let b = Buffer.create 4 in
      Buffer.add_char b c;
      for _ = 1 to n do match read_byte fd with Some c -> Buffer.add_char b c | None -> () done;
      from_string (Buffer.contents b) (ref 0)

let getc t =
  let c =
    match t.peekc, t.globp with
    | Some c, _ -> t.peekc <- None; c
    | None, Some (s, i) -> let c = from_string s i in if c = eof then t.globp <- None; c
    | None, None -> (match t.src with Fd fd -> from_fd fd | Str (s, i) -> from_string s i)
  in
  t.lastc <- c;
  c

let unget t c = t.peekc <- Some c
let lastc t = t.lastc
let set_lastc t c = t.lastc <- c

let add b c = Buffer.add_utf_8_uchar b (Uchar.of_int c)

(* ed.c's gety *)
let line t =
  let in_list = t.globp <> None in
  let b = Buffer.create 80 in
  let rec go () =
    match getc t with
    | c when c = nl -> Some (Buffer.contents b)
    | c when c = eof -> if in_list then unget t eof; None
    | 0 -> go ()
    | c -> add b c; go ()
  in
  go ()

let digits t =
  let rec go n =
    match getc t with
    | c when c >= Char.code '0' && c <= Char.code '9' -> go ((n * 10) + c - Char.code '0')
    | c -> unget t c; n
  in
  go 0

let set_global t list = t.globp <- Option.map (fun s -> (s, ref 0)) list
let in_global t = t.globp <> None
let global_has_more t = match t.globp with Some (s, i) -> !i < String.length s | None -> false

let recover t =
  (match t.src with
   | Fd fd -> (try ignore (Unix.lseek fd 0 Unix.SEEK_END) with Unix.Unix_error _ -> ())
   | Str _ -> ());
  if t.globp <> None then t.lastc <- nl;
  t.globp <- None;
  t.peekc <- (if t.lastc = 0 then None else Some t.lastc);
  if t.lastc <> 0 then begin
    let rec skip () = let c = getc t in if c <> nl && c <> eof then skip () in
    skip ()
  end
