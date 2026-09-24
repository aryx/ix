(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Mmu32.mli *)

type t = {
  mutable sctlr : int;
  mutable ttbr0 : int;
  mutable ttbr1 : int;
  mutable ttbcr : int;
  mutable dacr : int;
  mem : Memory.t;
  (* the TLB: per 4KB page of virtual address, its tag (the page number,
   * -1 empty), the physical page, and the accesses allowed (bit per
   * kind: priv read, priv write, user read, user write) *)
  tags : int array;
  pages : int array;
  rights : int array;
}

(* the mask clearing the low n bits (computed: js_of_ocaml truncates the
 * literals with bit 31 set, with a warning) *)
let hi n = Bits.mask32 (lnot ((1 lsl n) - 1))
let m24 = hi 24 and m20 = hi 20 and m16 = hi 16 and m12 = hi 12 and m10 = hi 10

let tlb_bits = 10
let tlb_size = 1 lsl tlb_bits

let create mem =
  { sctlr = 0; ttbr0 = 0; ttbr1 = 0; ttbcr = 0; dacr = 0; mem;
    tags = Array.make tlb_size (-1); pages = Array.make tlb_size 0; rights = Array.make tlb_size 0 }

let flush t = Array.fill t.tags 0 tlb_size (-1)

let enabled t = t.sctlr land 1 <> 0
let xp t = t.sctlr land (1 lsl 23) <> 0

(* the FSR's codes *)
let section_translation = 0x5 and page_translation = 0x7 and section_domain = 0x9 and page_domain = 0xb
and section_permission = 0xd and page_permission = 0xf

(* bit 0 write, bit 1 as user: the index of the right *)
let right_of access = access land 3

(* the four rights of AP (and APX): bit 0 priv read, 1 priv write, 2
 * user read, 3 user write; AP 0 without APX takes SCTLR's S and R bits
 * (the legacy read-only encodings) *)
let rights_of t ~apx ~ap =
  let s = t.sctlr land (1 lsl 8) <> 0 and r = t.sctlr land (1 lsl 9) <> 0 in
  match apx, ap with
  | false, 0 -> (if s then 1 else 0) lor (if r then 1 lor 4 else 0)
  | false, 1 -> 3
  | false, 2 -> 3 lor 4
  | false, _ -> 15
  | true, 1 -> 1
  | true, (2 | 3) -> 1 lor 4
  | true, _ -> 0

(* the walk: the physical page of [va], its rights, whether a section,
 * its domain, and whether the TLB may keep it (not when its quarters
 * have their own rights); or a fault (its FSR, the domain in bits 7-4) *)
exception Walk_fault of int

let walk t va =
  let load a = Memory.load32 t.mem a in
  (* TTBCR.N: addresses whose top N bits are all zero use TTBR0, the
   * rest TTBR1 *)
  let n = t.ttbcr land 7 in
  let use1 = n > 0 && va lsr (32 - n) <> 0 in
  let table = if use1 then t.ttbr1 land lnot 0x3fff else t.ttbr0 land (Bits.mask32 (lnot ((1 lsl (14 - n)) - 1))) in
  let l1 = load (Bits.mask32 (table lor ((va lsr 20) lsl 2))) in
  let domain = (l1 lsr 5) land 15 in
  let fault code = raise (Walk_fault ((domain lsl 4) lor code)) in
  let check_domain ~section =
    match (t.dacr lsr (2 * domain)) land 3 with
    | 0 | 2 -> fault (if section then section_domain else page_domain)
    | 3 -> `Manager
    | _ -> `Client in
  let result ?(keep = true) ~section ~page ~apx ~ap () =
    let rights = match check_domain ~section with `Manager -> 15 | `Client -> rights_of t ~apx ~ap in
    page, rights, section, domain, keep in
  match l1 land 3 with
  (* no entry; or a fine table (legacy, obsolete in ARMv6, no Pi kernel
   * uses one), reserved in the ARMv6 format *)
  | 0 | 3 -> fault section_translation
  | 2 ->
      (* a section, or with bit 18 in the ARMv6 format, a supersection *)
      let apx = xp t && l1 land (1 lsl 15) <> 0 and ap = (l1 lsr 10) land 3 in
      let base =
        if xp t && l1 land (1 lsl 18) <> 0 then (l1 land m24) lor (va land 0x00fff000)
        else (l1 land m20) lor (va land 0x000ff000) in
      result ~section:true ~page:base ~apx ~ap ()
  | _ ->
      (* a coarse table *)
      let l2_addr = (l1 land m10) lor (((va lsr 12) land 0xff) lsl 2) in
      let l2 = load (Bits.mask32 l2_addr) in
      (* legacy large and small pages: one AP per quarter (subpage); the
       * TLB keeps the page when the four agree *)
      let sub ~shift = (l2 lsr (4 + (2 * ((va lsr shift) land 3)))) land 3 in
      let uniform = let a = (l2 lsr 4) land 0xff in a = (a land 3) * 0x55 in
      (match l2 land 3, xp t with
       | 0, _ -> fault page_translation
       | 1, false -> result ~keep:uniform ~section:false ~page:((l2 land m16) lor (va land 0xf000)) ~apx:false ~ap:(sub ~shift:14) ()
       | 2, false -> result ~keep:uniform ~section:false ~page:(l2 land m12) ~apx:false ~ap:(sub ~shift:10) ()
       | 3, false -> result ~section:false ~page:(l2 land m12) ~apx:false ~ap:((l2 lsr 4) land 3) ()
       | 1, true ->
           result ~section:false ~page:((l2 land m16) lor (va land 0xf000)) ~apx:(l2 land (1 lsl 9) <> 0) ~ap:((l2 lsr 4) land 3) ()
       | _, true -> result ~section:false ~page:(l2 land m12) ~apx:(l2 land (1 lsl 9) <> 0) ~ap:((l2 lsr 4) land 3) ()
       | _ -> assert false)

(* [va] for an access (bit 0 a write, bit 1 as user), or Arm32.Abort
 * with the address and the FSR (bit 11: a write) *)
let translate t ~user va access =
  let access = if user then access lor 2 else access in
  let page = va lsr 12 in
  let i = page land (tlb_size - 1) in
  let need = 1 lsl right_of access in
  if t.tags.(i) = page && t.rights.(i) land need <> 0 then t.pages.(i) lor (va land 0xfff)
  else
    match walk t va with
    | pa_page, rights, section, domain, keep ->
        if rights land need = 0 then
          raise (Arm32.Abort (va, (domain lsl 4) lor (if section then section_permission else page_permission)
                                  lor (if access land 1 <> 0 then 1 lsl 11 else 0)));
        if keep then (t.tags.(i) <- page; t.pages.(i) <- pa_page land lnot 0xfff; t.rights.(i) <- rights);
        (pa_page land lnot 0xfff) lor (va land 0xfff)
    | exception Walk_fault fsr -> raise (Arm32.Abort (va, fsr lor (if access land 1 <> 0 then 1 lsl 11 else 0)))
