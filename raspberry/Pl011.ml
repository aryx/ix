(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Pl011.mli *)

type t = {
  rx : char Queue.t;
  mutable imsc : int;
  mutable ris : int;
  mutable cr : int;
  mutable lcrh : int;
  mutable ibrd : int;
  mutable fbrd : int;
  mutable ifls : int;
  output : char -> unit;
  line : bool -> unit;
}

let rxim = 1 lsl 4 and txim = 1 lsl 5 and rtim = 1 lsl 6

let create ~output ~line =
  { rx = Queue.create (); imsc = 0; ris = txim; cr = 0x300; lcrh = 0; ibrd = 0; fbrd = 0; ifls = 0x12; output; line }

let update t = t.line (t.ris land t.imsc <> 0)

let empty t = Queue.is_empty t.rx

(* a character received: the receive and its timeout interrupts *)
let input t c = Queue.add c t.rx; t.ris <- t.ris lor rxim lor rtim; update t

let read t off _ =
  match off with
  | 0x00 ->
      let c = if Queue.is_empty t.rx then 0 else Char.code (Queue.pop t.rx) in
      if Queue.is_empty t.rx then (t.ris <- t.ris land lnot (rxim lor rtim); update t);
      c
  | 0x18 -> (if Queue.is_empty t.rx then 0x10 else 0) lor 0x80          (* RXFE; TXFE: sent at once *)
  | 0x24 -> t.ibrd | 0x28 -> t.fbrd | 0x2c -> t.lcrh | 0x30 -> t.cr | 0x34 -> t.ifls
  | 0x38 -> t.imsc | 0x3c -> t.ris | 0x40 -> t.ris land t.imsc
  (* the PrimeCell identification *)
  | 0xfe0 -> 0x11 | 0xfe4 -> 0x10 | 0xfe8 -> 0x14 | 0xfec -> 0x00
  | 0xff0 -> 0x0d | 0xff4 -> 0xf0 | 0xff8 -> 0x05 | 0xffc -> 0xb1
  | _ -> 0

let write t off _ v =
  match off with
  | 0x00 -> t.output (Char.chr (v land 0xff)); t.ris <- t.ris lor txim; update t
  | 0x24 -> t.ibrd <- v | 0x28 -> t.fbrd <- v | 0x2c -> t.lcrh <- v | 0x30 -> t.cr <- v | 0x34 -> t.ifls <- v
  | 0x38 -> t.imsc <- v land 0x7ff; update t
  | 0x44 -> t.ris <- t.ris land lnot v; update t
  | _ -> ()

let device t = { Memory.read = read t; write = write t }
