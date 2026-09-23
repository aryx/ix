(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Text.mli *)

type line = { text : string; mutable global : bool }

type t = {
  mutable lines : line array;   (* lines.(0) is line 0, not a line *)
  mutable dot : int;
  mutable changed : bool;
  marks : line option array;    (* 'a' .. 'z' *)
  mutable undo : (line * line) option;
}

let zero = { text = ""; global = false }

let create () =
  { lines = [| zero |]; dot = 0; changed = false; marks = Array.make 26 None; undo = None }

let dol t = Array.length t.lines - 1
let dot t = t.dot
let set_dot t n = t.dot <- n
let changed t = t.changed
let set_changed t b = t.changed <- b
let get t n = t.lines.(n)
let text t n = t.lines.(n).text
let undo t = t.undo
let set_undo t u = t.undo <- u

(* lines a..b of the array, as an array *)
let slice t a b = Array.sub t.lines a (b - a + 1)

let append t n texts =
  let added = Array.of_list (List.map (fun text -> { text; global = false }) texts) in
  t.lines <- Array.concat [ slice t 0 n; added; slice t (n + 1) (dol t) ];
  t.dot <- n + Array.length added;
  if added <> [||] then t.changed <- true;
  Array.length added

let delete t a b =
  t.lines <- Array.append (slice t 0 (a - 1)) (slice t (b + 1) (dol t));
  t.dot <- min a (dol t);
  t.changed <- true

let replace t n line = t.lines.(n) <- line

let clear t =
  t.lines <- [| zero |];
  t.dot <- 0;
  Array.fill t.marks 0 26 None;
  t.undo <- None

let move t a b n =
  let moved = slice t a b in
  Array.iter (fun l -> l.global <- false) moved;
  let count = b - a + 1 in
  if n < a then begin
    t.lines <- Array.concat [ slice t 0 n; moved; slice t (n + 1) (a - 1); slice t (b + 1) (dol t) ];
    t.dot <- n + count
  end
  else begin
    t.lines <- Array.concat [ slice t 0 (a - 1); slice t (b + 1) n; moved; slice t (n + 1) (dol t) ];
    t.dot <- n
  end;
  t.changed <- true

(* ed.c's gdelete: dot where the last deleted line was -- but not for
 * the first one, which its loop skips; so one line deleted leaves dot *)
let delete_global t =
  if Array.exists (fun l -> l.global) t.lines then begin
    let kept = ref [] and dot = ref t.dot and w = ref 0 and first = ref true in
    Array.iter (fun l ->
      if l.global && l != zero then (if not !first then dot := !w; first := false)
      else (kept := l :: !kept; incr w)) t.lines;
    t.lines <- Array.of_list (List.rev !kept);
    t.dot <- min !dot (dol t);
    t.changed <- true
  end

let index t line =
  let rec go i = if i > dol t then None else if t.lines.(i) == line then Some i else go (i + 1) in
  go 1

let mark t c n = t.marks.(Char.code c - Char.code 'a') <- Some t.lines.(n)

let find_mark t c =
  match t.marks.(Char.code c - Char.code 'a') with Some l -> index t l | None -> None

let renamed t old line =
  Array.iteri (fun i m -> match m with Some l when l == old -> t.marks.(i) <- Some line | _ -> ()) t.marks
