(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Mmu64.mli *)

type t = {
  mutable sctlr : int64;
  mutable tcr : int64;
  mutable ttbr0 : int64;
  mutable ttbr1 : int64;
  mem : Memory.t;
  (* the TLB, as Mmu32's: per 4KB page of virtual address, its tag (the
   * page number, -1 empty), the physical page, the accesses allowed (a
   * bit per kind: priv read, priv write, user read, user write, priv
   * fetch, user fetch) *)
  tags : int array;
  pages : int array;
  rights : int array;
}

let tlb_bits = 10
let tlb_size = 1 lsl tlb_bits

let create mem =
  { sctlr = 0L; tcr = 0L; ttbr0 = 0L; ttbr1 = 0L; mem;
    tags = Array.make tlb_size (-1); pages = Array.make tlb_size 0; rights = Array.make tlb_size 0 }

let flush t = Array.fill t.tags 0 tlb_size (-1)

let enabled t = Int64.logand t.sctlr 1L <> 0L

(* the fault status codes, plus the level *)
let translation = 0x4 and access_flag = 0x8 and permission = 0xc

exception Walk_fault of int

let bits v lo n = Int64.to_int (Int64.logand (Int64.shift_right_logical v lo) (Int64.pred (Int64.shift_left 1L n)))

(* a descriptor's output address, bits 47-12 *)
let output d = Int64.to_int (Int64.logand d 0xffff_ffff_f000L)

(* the six rights of a block or page descriptor *)
let rights_of d =
  let ap1 = bits d 6 1 = 1 and ap2 = bits d 7 1 = 1 in
  let uxn = bits d 54 1 = 1 and pxn = bits d 53 1 = 1 in
  let pr = true and pw = not ap2 and ur = ap1 and uw = ap1 && not ap2 in
  let px = (not pxn) && not uw and ux = (not uxn) && ur in
  let b f k = if f then 1 lsl k else 0 in
  b pr 0 lor b pw 1 lor b ur 2 lor b uw 3 lor b px 4 lor b ux 5

(* the walk: the physical address of [va]'s 4KB page, and its rights *)
let walk t va =
  (* the region: TTBR0 when the bits above its size are zeros, TTBR1
   * when they are ones, else a fault at level 0 *)
  let t0sz = bits t.tcr 0 6 and t1sz = bits t.tcr 16 6 in
  let size, ttbr, disabled =
    if Int64.shift_right_logical va (64 - t0sz) = 0L then 64 - t0sz, t.ttbr0, bits t.tcr 7 1 = 1
    else if Int64.shift_right va (64 - t1sz) = -1L then 64 - t1sz, t.ttbr1, bits t.tcr 23 1 = 1
    else raise (Walk_fault translation) in
  if disabled then raise (Walk_fault translation);
  (* 9 bits a level above the page's 12: a 39-bit size starts at level 1 *)
  let start = 4 - ((size - 12 + 8) / 9) in
  let rec go level table =
    let shift = 12 + (9 * (3 - level)) in
    let width = if level = start then size - shift else 9 in
    let index = bits va shift width in
    let d = Memory.load64 t.mem (table + (8 * index)) in
    let fault code = raise (Walk_fault (code + level)) in
    if Int64.logand d 1L = 0L then fault translation
    else if level < 3 && Int64.logand d 2L <> 0L then go (level + 1) (output d)
    else if (level = 3 && Int64.logand d 2L = 0L) || level = 0 then fault translation
    else if bits d 10 1 = 0 then fault access_flag
    else
      (* a block keeps the address's bits below its size *)
      let low = Int64.to_int (Int64.logand va (Int64.of_int ((1 lsl shift) - 1))) in
      ((output d) land lnot ((1 lsl shift) - 1)) lor (low land lnot 0xfff), rights_of d, level in
  go start (output ttbr)

let translate t va access =
  let page = Int64.to_int (Int64.shift_right_logical va 12) in
  let i = page land (tlb_size - 1) in
  let user = (access lsr 1) land 1 in
  let need = if access land 4 <> 0 then 1 lsl (4 + user) else 1 lsl (access land 3) in
  let offset = Int64.to_int (Int64.logand va 0xfffL) in
  let write = if access land 5 = 1 then 0x40 else 0 in
  if t.tags.(i) = page && t.rights.(i) land need <> 0 then t.pages.(i) lor offset
  else
    match walk t va with
    | pa, rights, level ->
        if rights land need = 0 then raise (Arm64.Abort (va, permission + level + write));
        t.tags.(i) <- page; t.pages.(i) <- pa; t.rights.(i) <- rights;
        pa lor offset
    | exception Walk_fault fsc -> raise (Arm64.Abort (va, fsc + write))
