(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Dma.mli *)

type channel = { mutable cs : int; mutable conblk : int; regs : int array (* ti source dest len stride next debug *) }

type t = { mem : Memory.t; chans : channel array; mutable enable : int; line : int -> bool -> unit }

let create ~mem ~line = { mem; chans = Array.init 15 (fun _ -> { cs = 0; conblk = 0; regs = Array.make 7 0 }); enable = 0x7fff; line }

(* a bus address, as the ARM sees it: the peripherals at 0x7E... *)
let phys a = if a land 0xff000000 = 0x7e000000 then 0x20000000 lor (a land 0xffffff) else a land 0x3fffffff

let active = 1 and fin = 2 and int = 4

(* the control blocks, one after another, each moved whole *)
let run t n =
  let c = t.chans.(n) in
  while c.cs land active <> 0 && c.conblk <> 0 do
    let cb = phys c.conblk in
    let word i = Memory.load32 t.mem (cb + (4 * i)) in
    let ti = word 0 and src = word 1 and dst = word 2 and len = word 3 land 0x3fffffff and next = word 5 in
    c.regs.(0) <- ti; c.regs.(1) <- src; c.regs.(2) <- dst; c.regs.(3) <- len; c.regs.(4) <- word 4; c.regs.(5) <- next;
    let src_inc = ti land (1 lsl 8) <> 0 and dst_inc = ti land (1 lsl 4) <> 0 in
    let s = ref (phys src) and d = ref (phys dst) in
    for _ = 1 to len / 4 do
      Memory.store32 t.mem !d (Memory.load32 t.mem !s);
      if src_inc then s := !s + 4;
      if dst_inc then d := !d + 4
    done;
    for _ = 1 to len mod 4 do
      Memory.store8 t.mem !d (Memory.load8 t.mem !s);
      if src_inc then incr s;
      if dst_inc then incr d
    done;
    c.conblk <- next;
    if ti land 1 <> 0 then c.cs <- c.cs lor int
  done;
  c.cs <- (c.cs land lnot active) lor fin;
  t.line (16 + n) (c.cs land int <> 0)

let read t off _ =
  if off = 0xfe0 then Array.fold_left (fun (acc, i) c -> (if c.cs land int <> 0 then acc lor (1 lsl i) else acc), i + 1) (0, 0) t.chans |> fst
  else if off = 0xff0 then t.enable
  else
    let n = off / 0x100 and r = off land 0xff in
    if n >= 15 then 0
    else
      let c = t.chans.(n) in
      match r with 0x00 -> c.cs | 0x04 -> c.conblk | _ when r >= 0x08 && r <= 0x20 -> c.regs.((r - 0x08) / 4) | _ -> 0

let write t off _ v =
  if off = 0xff0 then t.enable <- v
  else if off = 0xfe0 then ()
  else
    let n = off / 0x100 and r = off land 0xff in
    if n < 15 then begin
      let c = t.chans.(n) in
      match r with
      | 0x00 ->
          if v land (1 lsl 31) <> 0 then (c.cs <- 0; c.conblk <- 0)
          else begin
            (* END and INT written 1 to clear; ACTIVE starts the chain *)
            c.cs <- (c.cs land lnot (v land (fin lor int))) land lnot active lor (v land active) lor (v land 0x0ff70000);
            if v land active <> 0 then run t n
          end;
          t.line (16 + n) (c.cs land int <> 0)
      | 0x04 -> c.conblk <- v
      | 0x20 -> ()
      | _ -> ()
    end

let device t = { Memory.read = read t; write = write t }
