(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Systimer.mli *)

type t = {
  mutable now : int;             (* microseconds, 64 bits *)
  mutable cs : int;              (* the matched compares, bits 0-3 *)
  compare : int array;
  line : int -> bool -> unit;
}

let create ~line = { now = 0; cs = 0; compare = Array.make 4 0; line }

(* the lines, from CS: compare n is interrupt n *)
let lines t = for n = 0 to 3 do t.line n (t.cs land (1 lsl n) <> 0) done

(* time advanced by [us]: a compare between the old low word and the
 * new one (modulo 2^32) matches *)
let advance t us =
  if us > 0 then begin
    let lo0 = t.now land 0xffffffff in
    t.now <- t.now + us;
    for n = 0 to 3 do
      let d = (t.compare.(n) - lo0 - 1) land 0xffffffff in
      if d < us then t.cs <- t.cs lor (1 lsl n)
    done;
    lines t
  end

(* the microseconds to the next compare *)
let until_next t =
  let lo = t.now land 0xffffffff in
  Array.fold_left (fun acc c -> let d = (c - lo) land 0xffffffff in if d = 0 then acc else min acc d) max_int t.compare

let read t off _ =
  match off with
  | 0x0 -> t.cs
  | 0x4 -> t.now land 0xffffffff
  | 0x8 -> (t.now lsr 32) land 0xffffffff
  | 0xc | 0x10 | 0x14 | 0x18 -> t.compare.((off - 0xc) / 4)
  | _ -> 0

let write t off _ v =
  match off with
  | 0x0 -> t.cs <- t.cs land lnot v; lines t          (* 1s clear the matches *)
  | 0xc | 0x10 | 0x14 | 0x18 -> t.compare.((off - 0xc) / 4) <- v land 0xffffffff
  | _ -> ()

let device t = { Memory.read = read t; write = write t }

let now t = t.now
