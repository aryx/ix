(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Intc.mli *)

type t = {
  mutable level : int;          (* the GPU's 64 lines, as an int (native: 63 bits: two halves below) *)
  mutable level_hi : int;
  mutable enable : int;
  mutable enable_hi : int;
  mutable basic_enable : int;
}

let create () = { level = 0; level_hi = 0; enable = 0; enable_hi = 0; basic_enable = 0 }

let set t n on =
  if n < 32 then t.level <- (if on then t.level lor (1 lsl n) else t.level land lnot (1 lsl n))
  else let b = 1 lsl (n - 32) in t.level_hi <- (if on then t.level_hi lor b else t.level_hi land lnot b)

let pending1 t = t.level land t.enable
let pending2 t = t.level_hi land t.enable_hi

(* the GPU lines shown again in the basic register, bits 10-20 *)
let basic_shortcuts = [ 7; 9; 10; 18; 19; 53; 54; 55; 56; 57; 62 ]

let basic t =
  let p1 = pending1 t and p2 = pending2 t in
  let short = List.fold_left (fun (acc, bit) n ->
    let on = if n < 32 then p1 land (1 lsl n) <> 0 else p2 land (1 lsl (n - 32)) <> 0 in
    (if on then acc lor (1 lsl bit) else acc), bit + 1) (0, 10) basic_shortcuts |> fst in
  (if p1 <> 0 then 1 lsl 8 else 0) lor (if p2 <> 0 then 1 lsl 9 else 0) lor short

let irq t = pending1 t <> 0 || pending2 t <> 0

let read t off _ =
  match off with
  | 0x0 -> basic t
  | 0x4 -> pending1 t
  | 0x8 -> pending2 t
  | 0x10 -> t.enable
  | 0x14 -> t.enable_hi
  | 0x18 -> t.basic_enable
  | 0x1c -> t.enable
  | 0x20 -> t.enable_hi
  | 0x24 -> t.basic_enable
  | _ -> 0

let write t off _ v =
  match off with
  | 0x10 -> t.enable <- t.enable lor v
  | 0x14 -> t.enable_hi <- t.enable_hi lor v
  | 0x18 -> t.basic_enable <- t.basic_enable lor v
  | 0x1c -> t.enable <- t.enable land lnot v
  | 0x20 -> t.enable_hi <- t.enable_hi land lnot v
  | 0x24 -> t.basic_enable <- t.basic_enable land lnot v
  | _ -> ()

let device t = { Memory.read = read t; write = write t }
