(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Gic.mli *)

let count = 192                        (* QEMU's BCM2711: 32 private, 160 shared *)
let spurious = 1023
let idle = 0x100                       (* the running priority with none active *)

type t = {
  enabled : bool array;
  latched : bool array;                (* set pending by software *)
  level : bool array;                  (* the devices' lines *)
  active : bool array;
  priority : int array;
  target : int array;
  config : int array;                  (* ICFGR, a word per 16 *)
  mutable dctlr : int;
  mutable cctlr : int;
  mutable pmr : int;
  mutable bpr : int;
  mutable running : int list;          (* the active interrupts, the latest first *)
  mutable asserted : bool;
}

let create () =
  { enabled = Array.make count false; latched = Array.make count false; level = Array.make count false;
    active = Array.make count false; priority = Array.make count 0; target = Array.make count 0;
    config = Array.init (count / 16) (fun i -> if i = 0 then Bits.mask32 0xaaaaaaaa else 0);
    dctlr = 0; cctlr = 0; pmr = 0; bpr = 0; running = []; asserted = false }

let pending t id = t.latched.(id) || t.level.(id)

let running_priority t = match t.running with id :: _ -> t.priority.(id) | [] -> idle

(* the highest-priority interrupt pending, enabled, not active, for the
 * core (the private ones always; a shared one targeting it), under the
 * mask; the lowest ID first among equals *)
let highest t =
  let best = ref spurious in
  for id = 0 to count - 1 do
    if t.enabled.(id) && pending t id && (not t.active.(id)) && (id < 32 || t.target.(id) land 1 <> 0)
       && t.priority.(id) < t.pmr && (!best = spurious || t.priority.(id) < t.priority.(!best)) then best := id
  done;
  !best

let update t =
  let h = highest t in
  t.asserted <- t.dctlr land 1 <> 0 && t.cctlr land 1 <> 0 && h <> spurious && t.priority.(h) < running_priority t

let set t id on = if t.level.(id) <> on then (t.level.(id) <- on; update t)

let irq t = t.asserted

(* a register of a bit per interrupt, from [base]: the word of [off] *)
let bits_of f off base =
  let first = (off - base) * 8 in
  let rec go k acc = if k = 32 then acc else go (k + 1) (if first + k < count && f (first + k) then acc lor (1 lsl k) else acc) in
  go 0 0

let each_bit v off base f =
  let first = (off - base) * 8 in
  for k = 0 to 31 do if v land (1 lsl k) <> 0 && first + k < count then f (first + k) done

(* a register of a byte per interrupt, read and written by the access's
 * size *)
let bytes_of a off base size =
  let first = off - base in
  let rec go k acc = if k = size then acc else go (k + 1) (if first + k < count then acc lor (a.(first + k) lsl (8 * k)) else acc) in
  go 0 0

let set_bytes a off base size v = let first = off - base in for k = 0 to size - 1 do if first + k < count then a.(first + k) <- (v lsr (8 * k)) land 0xff done

let dread t off size =
  match off with
  | 0x000 -> t.dctlr
  | 0x004 -> ((count / 32) - 1) lor (3 lsl 5)              (* ITLinesNumber; 4 cores *)
  | 0x008 -> 0x0200043b                                    (* GIC-400 *)
  | _ when off >= 0x100 && off < 0x200 -> bits_of (fun id -> t.enabled.(id)) (off land 0x7f) 0
  | _ when off >= 0x200 && off < 0x300 -> bits_of (pending t) (off land 0x7f) 0
  | _ when off >= 0x300 && off < 0x400 -> bits_of (fun id -> t.active.(id)) (off land 0x7f) 0
  | _ when off >= 0x400 && off < 0x800 -> bytes_of t.priority off 0x400 size
  | _ when off >= 0x800 && off < 0x820 -> Bits.mask32 (0x01010101 land ((1 lsl (8 * size)) - 1))   (* the private ones: this core *)
  | _ when off >= 0x800 && off < 0xc00 -> bytes_of t.target off 0x800 size
  | _ when off >= 0xc00 && off < 0xd00 && (off - 0xc00) / 4 < Array.length t.config -> t.config.((off - 0xc00) / 4)
  | _ -> 0

let dwrite t off size v =
  (match off with
   | 0x000 -> t.dctlr <- v land 1
   | _ when off >= 0x100 && off < 0x180 -> each_bit v off 0x100 (fun id -> t.enabled.(id) <- true)
   | _ when off >= 0x180 && off < 0x200 -> each_bit v off 0x180 (fun id -> t.enabled.(id) <- false)
   | _ when off >= 0x200 && off < 0x280 -> each_bit v off 0x200 (fun id -> t.latched.(id) <- true)
   | _ when off >= 0x280 && off < 0x300 -> each_bit v off 0x280 (fun id -> t.latched.(id) <- false)
   | _ when off >= 0x300 && off < 0x380 -> each_bit v off 0x300 (fun id -> t.active.(id) <- true)
   | _ when off >= 0x380 && off < 0x400 -> each_bit v off 0x380 (fun id -> t.active.(id) <- false)
   | _ when off >= 0x400 && off < 0x800 -> set_bytes t.priority off 0x400 size v
   | _ when off >= 0x820 && off < 0xc00 -> set_bytes t.target off 0x800 size v
   | _ when off >= 0xc04 && off < 0xd00 && (off - 0xc00) / 4 < Array.length t.config -> t.config.((off - 0xc00) / 4) <- v
   | _ -> ());
  update t

(* IAR: the highest pending, now active; EOIR: its end *)
let acknowledge t =
  let id = highest t in
  if id = spurious || t.priority.(id) >= running_priority t then spurious
  else begin
    t.active.(id) <- true; t.latched.(id) <- false; t.running <- id :: t.running;
    update t; id
  end

let end_of_interrupt t id =
  if id < count && t.active.(id) then begin
    t.active.(id) <- false;
    t.running <- List.filter (( <> ) id) t.running;
    update t
  end

let cread t off _ =
  match off with
  | 0x00 -> t.cctlr
  | 0x04 -> t.pmr
  | 0x08 -> t.bpr
  | 0x0c -> acknowledge t
  | 0x14 -> running_priority t land 0xff
  | 0x18 -> highest t
  | 0xfc -> 0x0202043b
  | _ -> 0

let cwrite t off _ v =
  match off with
  | 0x00 -> t.cctlr <- v land 1; update t
  | 0x04 -> t.pmr <- v land 0xff; update t
  | 0x08 -> t.bpr <- v land 7
  | 0x10 -> end_of_interrupt t (v land 0x3ff)
  | _ -> ()

let distributor t = { Memory.read = dread t; write = dwrite t }
let cpu_interface t = { Memory.read = cread t; write = cwrite t }
