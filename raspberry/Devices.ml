(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devices.mli *)

(* a bank of registers that read back what was written, some fixed *)
let regs ?(fixed = []) () =
  let t = Hashtbl.create 16 in
  { Memory.read = (fun off _ -> match List.assoc_opt off fixed with Some v -> v | None -> Option.value (Hashtbl.find_opt t off) ~default:0);
    write = (fun off _ v -> Hashtbl.replace t off v) }

(* the mini UART and SPI's AUX block: LSR says the transmitter is empty
 * and idle (0x60) and no data came; what is written is dropped, as
 * QEMU's raspi1ap has no backend for it *)
let aux () = regs ~fixed:[ 0x54, 0x60; 0x64, 0x30c ] ()

let unassigned ~log =
  let seen = Hashtbl.create 16 in
  let note what off = if not (Hashtbl.mem seen (what, off)) then (Hashtbl.add seen (what, off) (); log what off) in
  { Memory.read = (fun off _ -> note "read" off; 0); write = (fun off _ _ -> note "write" off) }

(*****************************************************************************)
(* The mailbox *)
(*****************************************************************************)

type mailbox = {
  answers : int Queue.t;
  on_framebuffer : Framebuffer.geometry -> unit;
  mem : Memory.t;
  ram_size : int;
  vc_base : int;
  (* the framebuffer's configuration, QEMU's defaults: 640x480, 16 bits *)
  mutable xres : int; mutable yres : int; mutable vxres : int; mutable vyres : int; mutable bpp : int; mutable pixo : int;
}

let fb_base m = m.vc_base + 0x100000
let pitch m = m.vxres * ((m.bpp + 7) / 8)
let configure m = m.on_framebuffer { width = m.xres; height = m.yres; depth = m.bpp; pitch = pitch m; base = fb_base m }

(* QEMU's clock rates, by clock id *)
let clock_rate = function 1 -> 50000000 | 2 -> 3000000 | 4 -> 350000000 | _ -> 700000000

let property m buf =
  let get o = Memory.load32 m.mem (buf + o) and put o v = Memory.store32 m.mem (buf + o) v in
  let size = get 0 in
  let rec tags o =
    if o + 12 <= size then begin
      let tag = get o and len = get (o + 4) in
      if tag <> 0 then begin
        let answer words =
          List.iteri (fun i w -> if 4 * i < len then put (o + 12 + (4 * i)) w) words;
          put (o + 8) (0x80000000 lor (4 * List.length words)) in
        (* a length said, nothing written (QEMU's not-yet-implemented) *)
        let length n = put (o + 8) (0x80000000 lor n) in
        let arg i = get (o + 12 + (4 * i)) in
        (match tag with
         | 0x00000001 -> answer [ 346337 ]                      (* firmware revision, QEMU's *)
         | 0x00010001 -> answer [ 0 ]                            (* board model *)
         | 0x00010002 -> answer [ 0x900021 ]                     (* board revision: a Pi 1 A+ *)
         | 0x00010003 -> answer [ 0x33221100; 0x5544 ]           (* MAC address *)
         | 0x00010004 -> answer [ 0x12345678; 0 ]                (* serial *)
         | 0x00010005 -> answer [ 0; m.vc_base ]                 (* ARM memory *)
         | 0x00010006 -> answer [ m.vc_base; m.ram_size - m.vc_base ]  (* VideoCore memory *)
         | 0x00020002 | 0x00028001 -> answer [ arg 0; 1 ]         (* power: on, exists *)
         | 0x00030002 | 0x00030004 | 0x00030007 -> answer [ arg 0; clock_rate (arg 0) ]
         | 0x00038002 | 0x00038004 | 0x00038007 -> length 8
         | 0x00030006 -> answer [ arg 0; 25000 ]                 (* temperature, millidegrees *)
         | 0x0003000a -> answer [ arg 0; 99000 ]
         | 0x00040001 -> configure m; answer [ fb_base m; pitch m * m.vyres ]
         | 0x00040002 -> length 4                                (* blank *)
         | 0x00048003 -> m.xres <- arg 0; m.yres <- arg 1; configure m; answer [ m.xres; m.yres ]
         | 0x00040003 -> answer [ m.xres; m.yres ]
         | 0x00048004 -> m.vxres <- arg 0; m.vyres <- arg 1; configure m; answer [ m.vxres; m.vyres ]
         | 0x00040004 -> answer [ m.vxres; m.vyres ]
         | 0x00048005 -> m.bpp <- arg 0; configure m; answer [ m.bpp ]
         | 0x00040005 -> answer [ m.bpp ]
         | 0x00048006 -> m.pixo <- arg 0; answer [ m.pixo ]
         | 0x00040006 -> answer [ m.pixo ]
         | 0x00040008 -> answer [ pitch m ]
         | _ -> ());
        tags (o + 12 + ((len + 3) land lnot 3))
      end
    end in
  tags 8;
  put 4 0x80000000

(* the legacy framebuffer request (channel 1): its configuration taken,
 * answered as QEMU answers it *)
let framebuffer m buf =
  let get o = Memory.load32 m.mem (buf + o) and put o v = Memory.store32 m.mem (buf + o) v in
  m.xres <- get 0; m.yres <- get 4; m.vxres <- get 8; m.vyres <- get 12; m.bpp <- get 20;
  if m.vxres = 0 then m.vxres <- m.xres;
  if m.vyres = 0 then m.vyres <- m.yres;
  put 16 (pitch m);
  put 32 (fb_base m);
  put 36 (pitch m * m.vyres);
  configure m

let mailbox ~mem ~ram_size ~vc_base ~on_framebuffer =
  let m = { answers = Queue.create (); on_framebuffer; mem; ram_size; vc_base;
            xres = 640; yres = 480; vxres = 640; vyres = 480; bpp = 16; pixo = 1 } in
  let read off _ =
    match off with
    | 0x00 -> if Queue.is_empty m.answers then 0 else Queue.pop m.answers
    | 0x18 -> if Queue.is_empty m.answers then 1 lsl 30 else 0      (* EMPTY; never FULL *)
    | _ -> 0 in
  let write off _ v =
    if off = 0x20 then begin
      let chan = v land 0xf and buf = v land 0x3ffffff0 in
      (match chan with
       | 8 -> property m buf; Queue.add (v land lnot 0xf lor 8) m.answers
       | 1 -> framebuffer m buf; Queue.add 1 m.answers
       | _ -> ())                                               (* channel 0 (power): never answered, as QEMU *)
    end in
  { Memory.read; write }
