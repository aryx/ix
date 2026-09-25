(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Dwc2.mli *)

type t = {
  regs : (int, int) Hashtbl.t;
  mem : Memory.t;
  root : Usb.device option;
}

(* QEMU's reset values (hw/usb/hcd-dwc2.c's reset, its 8 channels) *)
let reset_values = [
  0x00, 0xd0000;          (* GOTGCTL: B and A sessions valid, connector B *)
  0x0c, 5 lsl 10;         (* GUSBCFG: turnaround time 5 *)
  0x14, 0x14000021;       (* GINTSTS: host mode, FIFOs empty *)
  0x24, 1024;             (* GRXFSIZ *)
  0x28, 1024 lsl 16;      (* GNPTXFSIZ *)
  0x2c, (4 lsl 16) lor 1024;
  0x30, 0x11000000;       (* GI2CCTL *)
  0x58, 0x10;             (* GPWRDN *)
  0x100, 500 lsl 16;      (* HPTXFSIZ *)
  0x400, 2 lsl 8;         (* HCFG *)
  0x404, 60000;           (* HFIR *)
  0x408, 0x3fff;          (* HFNUM *)
  0x410, (16 lsl 16) lor 32768 ]

(* HPRT's bits *)
let connsts = 1 and conndet = 2 and ena = 4 and enachg = 8 and ovrcurrchg = 0x20 and rst = 0x100 and pwr = 0x1000

let get t off = Option.value (Hashtbl.find_opt t.regs off) ~default:0
let set t off v = Hashtbl.replace t.regs off (v land 0xffffffff)

let create ~mem ~root =
  let t = { regs = Hashtbl.create 64; mem; root } in
  List.iter (fun (o, v) -> set t o v) reset_values;
  (* the root port: powered; a device attached at full speed, connected *)
  set t 0x440 (pwr lor (match root with Some _ -> (1 lsl 17) lor conndet lor connsts | None -> 0));
  Option.iter Usb.reset root;
  t

(* HPRT written, as QEMU's: read-only and self-set bits kept, the change
 * bits and enable written with 1 to clear; the end of a reset enables
 * the port and resets its device *)
let write_hprt t v =
  let old = get t 0x440 in
  let v = v lor (old land ((3 lsl 17) lor (3 lsl 10) lor 0x10 lor connsts)) lor (old land (0x80 lor 0x40)) in
  let v = if old land ena = 0 && v land ena <> 0 then v land lnot ena else v in
  let w1c = ovrcurrchg lor enachg lor ena lor conndet in
  let v = (v land lnot w1c) lor (old land w1c land lnot (v land w1c)) in
  let v =
    if v land rst = 0 && old land rst <> 0 then
      match t.root with
      | Some d -> Usb.reset d; (v lor ena lor enachg) land lnot conndet
      | None -> v
    else v in
  set t 0x440 v

(* a channel's transfer: its device by address, the whole transfer at
 * once (DMA from and to RAM, bus addresses less their top bits);
 * HCTSIZ's size and packet count as QEMU leaves them, HCINT's transfer
 * complete and halted (no ACK: QEMU's model has none), or STALL *)
let transfer t ch =
  let base = 0x500 + (0x20 * ch) in
  let hcchar = get t base and hctsiz = get t (base + 0x10) and dma = get t (base + 0x14) land 0x3fffffff in
  let addr = (hcchar lsr 22) land 0x7f and epdir = (hcchar lsr 15) land 1 and eptype = (hcchar lsr 18) land 3 in
  let mps = hcchar land 0x7ff and pid = (hctsiz lsr 29) land 3 in
  let pcnt = (hctsiz lsr 19) land 0x3ff and len = hctsiz land 0x7ffff in
  let dev = if get t 0x440 land ena = 0 then None else Option.bind t.root (fun r -> Usb.find r addr) in
  match dev with
  | None -> ()                                                     (* no device: the channel waits, as QEMU's *)
  | Some d ->
      let setup = eptype = 0 && pid = 3 in
      let result =
        if setup then Usb.setup d (Memory.read_string t.mem dma 8)
        else if epdir = 1 then Usb.data_in d len
        else Usb.data_out d (if len = 0 then "" else Memory.read_string t.mem dma len) in
      let intr =
        match result with
        | Usb.Data s ->
            let actual = if setup then 8 else if epdir = 1 then String.length s else len in
            if epdir = 1 && not setup && s <> "" then Memory.write_string t.mem dma s;
            let tpcnt = (actual / mps) + (if actual mod mps <> 0 then 1 else 0) in
            let pcnt = pcnt - min tpcnt pcnt and len = len - min actual len in
            set t (base + 0x10) ((hctsiz land lnot ((0x3ff lsl 19) lor 0x7ffff)) lor (pcnt lsl 19) lor len);
            set t (base + 0x14) (get t (base + 0x14) + actual);
            3                                                        (* XFERCOMPL, CHHLTD *)
        | Usb.Stall -> 0x8 lor 2
        | Usb.Nak -> 0x10 lor 2 in
      set t base (hcchar land lnot (1 lsl 31));
      set t (base + 8) (get t (base + 8) lor intr)

let read t off _ =
  match off with
  | 0x10 -> 0x80000000 lor get t off                         (* GRSTCTL: AHB idle; resets done *)
  | 0x3c -> 0                                                (* GUID *)
  | 0x40 -> 0x4f54294a                                       (* GSNPSID: 2.94a, QEMU's *)
  | 0x44 -> 0                                                (* GHWCFG1-4 *)
  | 0x48 -> 0x250dc016                                       (* internal DMA, 8 channels, host only *)
  | 0x4c -> 0x10000044
  | 0x50 -> 0
  | _ -> get t off

let write t off _ v =
  let v = v land 0xffffffff in
  match off with
  | 0x10 -> set t off (v land lnot 0x3f)                     (* the reset and flush bits clear at once *)
  | 0x440 -> write_hprt t v
  | _ when off >= 0x500 && off < 0x600 ->
      let base = off land lnot 0x1f and ch = (off - 0x500) / 0x20 in
      (match off land 0x1f with
       | 0x00 ->
           let old = get t base in
           if v land (1 lsl 30) <> 0 && old land (1 lsl 30) = 0 then begin
             (* a disable: halted *)
             set t base (v land lnot ((1 lsl 31) lor (1 lsl 30)));
             set t (base + 8) (get t (base + 8) lor 2)
           end
           else begin
             let enable = v land (1 lsl 31) <> 0 && old land (1 lsl 31) = 0 in
             set t base (v land lnot (1 lsl 30) lor (old land (1 lsl 30)));
             if enable then transfer t ch
           end
       | 0x08 -> set t off (get t off land lnot v)             (* HCINT: write 1 to clear *)
       | _ -> set t off v)
  | _ -> set t off v

let device t = { Memory.read = read t; write = write t }
