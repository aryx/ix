(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Miniuart.mli *)

type t = {
  rx : char Queue.t;
  mutable ier : int;
  output : char -> unit;
  line : bool -> unit;
}

let fifo = 8
let rx_int = 1 and tx_int = 2

let create ~output ~line = { rx = Queue.create (); ier = 0; output; line }

(* the interrupt: received characters when RX is enabled; TX always,
 * the output leaving at once *)
let iir t = (if t.ier land rx_int <> 0 && not (Queue.is_empty t.rx) then rx_int else 0) lor (if t.ier land tx_int <> 0 then tx_int else 0)
let update t = t.line (iir t <> 0)

let room t = Queue.length t.rx < fifo
let input t c = if room t then (Queue.add c t.rx; update t)

let read t off _ =
  let v = match off with
    | 0x00 -> if iir t <> 0 then 1 else 0                  (* AUX_IRQ *)
    | 0x04 -> 1                                             (* AUX_ENABLES: the mini UART always *)
    | 0x40 -> if Queue.is_empty t.rx then 0 else Char.code (Queue.pop t.rx)
    | 0x44 -> 0xc0 lor t.ier
    | 0x48 -> 0xc0 lor (if iir t land rx_int <> 0 then 4 else 2) lor (if iir t = 0 then 1 else 0)
    | 0x54 -> 0x60 lor (if Queue.is_empty t.rx then 0 else 1)
    | 0x60 -> 3
    | 0x64 -> 0x30e lor (if Queue.is_empty t.rx then 0 else 1 lor (Queue.length t.rx lsl 16))
    | _ -> 0 in
  if off = 0x40 then update t;
  v

let write t off _ v =
  (match off with
   | 0x40 -> t.output (Char.chr (v land 0xff))
   | 0x44 -> t.ier <- v land 3
   | 0x48 -> if v land 2 <> 0 then Queue.clear t.rx
   | _ -> ());
  update t

let device t = { Memory.read = read t; write = write t }
