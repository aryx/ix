(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Mmu.mli *)

open Types

module Phys = Machine.Phys

let pgsize = 4096
let pgroundup a = (a + pgsize - 1) land lnot (pgsize - 1)

(*****************************************************************************)
(* Entries *)
(*****************************************************************************)

(* a coarse table 01 and its address (domain 0); a small page 1x (XN,
 * bit 0, clear), AP in bits 5-4: 01 the kernel's, 10 the user reading,
 * 11 the user writing (APX, bit 9, clear) *)
let encode_l1 = function L1_fault -> 0 | Coarse t -> t lor 1
let decode_l1 e = if e land 3 = 1 then Coarse (e land lnot 0x3ff) else L1_fault

let ap = function Kernel_rw -> 1 | User_ro -> 2 | User_rw -> 3

let encode_l2 = function
  | L2_fault -> 0
  | Page pg -> pg.pa lor (ap pg.perm lsl 4) lor 2

let decode_l2 e =
  if e land 2 = 0 then L2_fault
  else Page { pa = e land lnot 0xfff; perm = (match (e lsr 4) land 3 with 1 -> Kernel_rw | 2 -> User_ro | _ -> User_rw) }

(*****************************************************************************)
(* Physical pages (kalloc.c) *)
(*****************************************************************************)

(* the RAM from 256MB (the OCaml heap's end, libc.c) to 448MB (the end of
 * the kernel's mapping, start.s): 49,152 pages *)
let free_pages = ref []
let () =
  let rec fill pa = if pa >= 0x10000000 then begin free_pages := pa :: !free_pages; fill (pa - pgsize) end in
  fill (0x1c000000 - pgsize)

(* a zeroed page, or None *)
let kalloc () =
  match !free_pages with
  | [] -> None
  | pa :: rest -> free_pages := rest; Phys.zero pa pgsize; Some pa

let kfree pa = free_pages := pa :: !free_pages

let nfree () = List.length !free_pages

(*****************************************************************************)
(* A space *)
(*****************************************************************************)

let l1_entry pgdir va = pgdir + (4 * (va lsr 20))

(* the second-level entry's address for [va]; its table made if
 * [alloc]; None when there is none (or no page for one) *)
let walk pgdir va alloc =
  match decode_l1 (Phys.get32 (l1_entry pgdir va)) with
  | Coarse t -> Some (t + (4 * ((va lsr 12) land 0xff)))
  | L1_fault when alloc ->
      (match kalloc () with
       | Some t -> Phys.set32 (l1_entry pgdir va) (encode_l1 (Coarse t)); Some (t + (4 * ((va lsr 12) land 0xff)))
       | None -> None)
  | L1_fault -> None

let lookup pgdir va =
  match walk pgdir va false with
  | Some e -> decode_l2 (Phys.get32 e)
  | None -> L2_fault

let set pgdir va entry =
  match walk pgdir va true with
  | Some e -> Phys.set32 e (encode_l2 entry); true
  | None -> false

(* a new space: an empty first-level table *)
let create () = kalloc ()

(* [oldsz, newsz) given fresh zeroed pages (allocuvm); the new size, or
 * None (1GB reached, or no page left: what was added freed) *)
let rec dealloc pgdir oldsz newsz =
  if newsz >= oldsz then oldsz
  else begin
    let a = ref (pgroundup newsz) in
    while !a < oldsz do
      (match lookup pgdir !a with
       | Page pg -> kfree pg.pa; ignore (set pgdir !a L2_fault)
       | L2_fault -> ());
      a := !a + pgsize
    done;
    newsz
  end

and alloc pgdir oldsz newsz =
  (* newsz is an OCaml int: below 1GB, or it wrapped (negative) *)
  if newsz < 0 then None
  else if newsz < oldsz then Some oldsz
  else begin
    let rec go a =
      if a >= newsz then Some newsz
      else match kalloc () with
        | Some pa when set pgdir a (Page { pa = pa; perm = User_rw }) -> go (a + pgsize)
        | Some pa -> kfree pa; ignore (dealloc pgdir a oldsz); None
        | None -> Machine.print "allocuvm out of memory\n"; ignore (dealloc pgdir a oldsz); None in
    go (pgroundup oldsz)
  end

(* the page under [va] no longer the user's: exec's guard (clearpteu) *)
let guard pgdir va =
  match lookup pgdir va with
  | Page pg -> ignore (set pgdir va (Page { pa = pg.pa; perm = Kernel_rw }))
  | L2_fault -> ()

(* every page and table of a space, then the table (freevm) *)
let free pgdir =
  for i = 0 to 1023 do
    match decode_l1 (Phys.get32 (pgdir + (4 * i))) with
    | Coarse t ->
        for j = 0 to 255 do
          match decode_l2 (Phys.get32 (t + (4 * j))) with Page pg -> kfree pg.pa | L2_fault -> ()
        done;
        kfree t
    | L1_fault -> ()
  done;
  kfree pgdir

(* a copy of [0, sz) in a new space (fork's copyuvm), or None *)
let copy pgdir sz =
  match create () with
  | None -> None
  | Some d ->
      let rec go a =
        if a >= sz then Some d
        else match lookup pgdir a with
          | L2_fault -> go (a + pgsize)
          | Page pg ->
              (match kalloc () with
               | Some pa when set d a (Page { pa = pa; perm = pg.perm }) -> Phys.copy pa pg.pa pgsize; go (a + pgsize)
               | Some pa -> kfree pa; free d; None
               | None -> free d; None) in
      go 0

(*****************************************************************************)
(* A user's bytes *)
(*****************************************************************************)

(* the physical address of [va]: any page mapped ([user]: the user's
 * only). xv6's kernel reads and writes a process's memory directly, its
 * bounds checked against sz only (its guard page too); exec's copyout
 * alone asks for the user's pages. *)
let pa_of pgdir va user =
  if va < 0 then None
  else match lookup pgdir va with
    | Page pg when (not user) || pg.perm <> Kernel_rw -> Some (pg.pa + (va land (pgsize - 1)))
    | _ -> None

(* [n] bytes at [va], a page at a time *)
let read pgdir va n =
  let b = Buffer.create n in
  let rec go va n =
    if n = 0 then Some (Buffer.contents b)
    else match pa_of pgdir va false with
      | None -> None
      | Some pa ->
          let k = min n (pgsize - (va land (pgsize - 1))) in
          Buffer.add_string b (Phys.read pa k);
          go (va + k) (n - k) in
  go va n

let write_gen user pgdir va s =
  let rec go va i =
    if i = String.length s then true
    else match pa_of pgdir va user with
      | None -> false
      | Some pa ->
          let k = min (String.length s - i) (pgsize - (va land (pgsize - 1))) in
          Phys.write pa (String.sub s i k);
          go (va + k) (i + k) in
  go va 0

let write pgdir va s = write_gen false pgdir va s
let copyout pgdir va s = write_gen true pgdir va s
