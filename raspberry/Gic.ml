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

(* the state of an interrupt, by core and ID: the private ones (0-31)
 * banked, a copy per core; the shared ones in core 0's copy *)
type t = {
  cores : int;
  enabled : bool array array;
  latched : bool array array;          (* set pending by software *)
  level : bool array array;            (* the devices' lines *)
  active : bool array array;
  priority : int array array;
  target : int array;                  (* the shared ones' cores, a bit each *)
  config : int array;                  (* ICFGR, a word per 16 *)
  mutable dctlr : int;
  (* the CPU interfaces, one per core *)
  cctlr : int array;
  pmr : int array;
  bpr : int array;
  running : int list array;            (* the active interrupts, the latest first *)
  asserted : bool array;
  mutable current : int;               (* the core whose accesses these are *)
}

let create ~cores =
  let per f = Array.init cores (fun _ -> f ()) in
  { cores; enabled = per (fun () -> Array.make count false); latched = per (fun () -> Array.make count false);
    level = per (fun () -> Array.make count false); active = per (fun () -> Array.make count false);
    priority = per (fun () -> Array.make count 0); target = Array.make count 0;
    config = Array.init (count / 16) (fun i -> if i = 0 then Bits.mask32 0xaaaaaaaa else 0);
    dctlr = 0; cctlr = Array.make cores 0; pmr = Array.make cores 0; bpr = Array.make cores 0;
    running = Array.make cores []; asserted = Array.make cores false; current = 0 }

(* the copy an interrupt's state is in, for a core *)
let bank id c = if id < 32 then c else 0

let pending t c id = let b = bank id c in t.latched.(b).(id) || t.level.(b).(id)

let running_priority t c = match t.running.(c) with id :: _ -> t.priority.(bank id c).(id) | [] -> idle

(* the highest-priority interrupt pending, enabled, not active, for
 * core [c] (its private ones; a shared one targeting it), under its
 * mask; the lowest ID first among equals *)
let highest t c =
  let best = ref spurious and best_priority = ref idle in
  for id = 0 to count - 1 do
    let b = bank id c in
    if t.enabled.(b).(id) && pending t c id && (not t.active.(b).(id)) && (id < 32 || t.target.(id) land (1 lsl c) <> 0)
       && t.priority.(b).(id) < t.pmr.(c) && t.priority.(b).(id) < !best_priority then begin
      best := id; best_priority := t.priority.(b).(id)
    end
  done;
  !best

let update t =
  for c = 0 to t.cores - 1 do
    let h = highest t c in
    t.asserted.(c) <- t.dctlr land 1 <> 0 && t.cctlr.(c) land 1 <> 0 && h <> spurious
                      && t.priority.(bank h c).(h) < running_priority t c
  done

let set t id on = if t.level.(0).(id) <> on then (t.level.(0).(id) <- on; update t)
let set_private t c id on = if t.level.(c).(id) <> on then (t.level.(c).(id) <- on; update t)

let irq t c = t.asserted.(c)
let set_current t c = t.current <- c

(* a register of a bit per interrupt, from [base]: the word of [off] *)
let bits_of f off base =
  let first = (off - base) * 8 in
  let rec go k acc = if k = 32 then acc else go (k + 1) (if first + k < count && f (first + k) then acc lor (1 lsl k) else acc) in
  go 0 0

let each_bit v off base f =
  let first = (off - base) * 8 in
  for k = 0 to 31 do if v land (1 lsl k) <> 0 && first + k < count then f (first + k) done

(* a register of a byte per interrupt, read and written by the access's
 * size; [a id] the array holding interrupt [id]'s byte *)
let bytes_of a off base size =
  let first = off - base in
  let rec go k acc = if k = size then acc else go (k + 1) (if first + k < count then acc lor ((a (first + k)).(first + k) lsl (8 * k)) else acc) in
  go 0 0

let set_bytes a off base size v =
  let first = off - base in
  for k = 0 to size - 1 do if first + k < count then (a (first + k)).(first + k) <- (v lsr (8 * k)) land 0xff done

let dread t off size =
  let c = t.current in
  let of_ a id = a.(bank id c) in
  match off with
  | 0x000 -> t.dctlr
  | 0x004 -> ((count / 32) - 1) lor (3 lsl 5)              (* ITLinesNumber; QEMU's 4 cores *)
  | 0x008 -> 0x0200043b                                    (* GIC-400 *)
  | _ when off >= 0x100 && off < 0x200 -> bits_of (fun id -> (of_ t.enabled id).(id)) (off land 0x7f) 0
  | _ when off >= 0x200 && off < 0x300 -> bits_of (pending t c) (off land 0x7f) 0
  | _ when off >= 0x300 && off < 0x400 -> bits_of (fun id -> (of_ t.active id).(id)) (off land 0x7f) 0
  | _ when off >= 0x400 && off < 0x800 -> bytes_of (of_ t.priority) off 0x400 size
  | _ when off >= 0x800 && off < 0x820 ->                  (* the private ones: this core *)
      let b = 1 lsl c in Bits.mask32 ((b lor (b lsl 8) lor (b lsl 16) lor (b lsl 24)) land ((1 lsl (8 * size)) - 1))
  | _ when off >= 0x800 && off < 0xc00 -> bytes_of (fun _ -> t.target) off 0x800 size
  | _ when off >= 0xc00 && off < 0xd00 && (off - 0xc00) / 4 < Array.length t.config -> t.config.((off - 0xc00) / 4)
  | _ -> 0

let dwrite t off size v =
  let c = t.current in
  let of_ a id = a.(bank id c) in
  (match off with
   | 0x000 -> t.dctlr <- v land 1
   | _ when off >= 0x100 && off < 0x180 -> each_bit v off 0x100 (fun id -> (of_ t.enabled id).(id) <- true)
   | _ when off >= 0x180 && off < 0x200 -> each_bit v off 0x180 (fun id -> (of_ t.enabled id).(id) <- false)
   | _ when off >= 0x200 && off < 0x280 -> each_bit v off 0x200 (fun id -> (of_ t.latched id).(id) <- true)
   | _ when off >= 0x280 && off < 0x300 -> each_bit v off 0x280 (fun id -> (of_ t.latched id).(id) <- false)
   | _ when off >= 0x300 && off < 0x380 -> each_bit v off 0x300 (fun id -> (of_ t.active id).(id) <- true)
   | _ when off >= 0x380 && off < 0x400 -> each_bit v off 0x380 (fun id -> (of_ t.active id).(id) <- false)
   | _ when off >= 0x400 && off < 0x800 -> set_bytes (of_ t.priority) off 0x400 size v
   | _ when off >= 0x820 && off < 0xc00 -> set_bytes (fun _ -> t.target) off 0x800 size v
   | _ when off >= 0xc04 && off < 0xd00 && (off - 0xc00) / 4 < Array.length t.config -> t.config.((off - 0xc00) / 4) <- v
   | _ -> ());
  update t

(* IAR: the highest pending, now active; EOIR: its end *)
let acknowledge t c =
  let id = highest t c in
  if id = spurious || t.priority.(bank id c).(id) >= running_priority t c then spurious
  else begin
    let b = bank id c in
    t.active.(b).(id) <- true; t.latched.(b).(id) <- false; t.running.(c) <- id :: t.running.(c);
    update t; id
  end

let end_of_interrupt t c id =
  if id < count && t.active.(bank id c).(id) then begin
    t.active.(bank id c).(id) <- false;
    t.running.(c) <- List.filter (( <> ) id) t.running.(c);
    update t
  end

let cread t off _ =
  let c = t.current in
  match off with
  | 0x00 -> t.cctlr.(c)
  | 0x04 -> t.pmr.(c)
  | 0x08 -> t.bpr.(c)
  | 0x0c -> acknowledge t c
  | 0x14 -> running_priority t c land 0xff
  | 0x18 -> highest t c
  | 0xfc -> 0x0202043b
  | _ -> 0

let cwrite t off _ v =
  let c = t.current in
  match off with
  | 0x00 -> t.cctlr.(c) <- v land 1; update t
  | 0x04 -> t.pmr.(c) <- v land 0xff; update t
  | 0x08 -> t.bpr.(c) <- v land 7
  | 0x10 -> end_of_interrupt t c (v land 0x3ff)
  | _ -> ()

let distributor t = { Memory.read = dread t; write = dwrite t }
let cpu_interface t = { Memory.read = cread t; write = cwrite t }
