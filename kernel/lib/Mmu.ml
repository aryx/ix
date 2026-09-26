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

open Page

module Phys = Machine.Phys

let pgsize = 4096
let pgroundup a = (a + pgsize - 1) land lnot (pgsize - 1)

(*****************************************************************************)
(* Physical pages (kalloc.c) *)
(*****************************************************************************)

let free_pages = ref []
let () =
  let lo, hi = Arch.pages in
  let rec fill pa = if pa >= lo then begin free_pages := pa :: !free_pages; fill (pa - pgsize) end in
  fill (hi - pgsize)

(* a zeroed page, or None *)
let kalloc () =
  match !free_pages with
  | [] -> None
  | pa :: rest -> free_pages := rest; Phys.zero pa pgsize; Some pa

let kfree pa = free_pages := pa :: !free_pages

let nfree () = List.length !free_pages

(*****************************************************************************)
(* A space: a radix tree of tables (Arch.levels) *)
(*****************************************************************************)

(* the entry of [table] for [va], at a level (its shift, its bits) *)
let entry table (shift, bits) va = table + (Arch.entry_bytes * ((va lsr shift) land ((1 lsl bits) - 1)))

(* the last level's entry for [va]; the tables on the way made if
 * [alloc]; None when there is none (or no page for one) *)
let walk pgdir va alloc =
  let rec go table levels =
    match levels with
    | [] -> None
    | [ last ] -> Some (entry table last va)
    | level :: rest ->
        let e = entry table level va in
        match Arch.decode_table (Arch.get_entry e) with
        | Some t -> go t rest
        | None when alloc ->
            (match kalloc () with
             | Some t -> Arch.set_entry e (Arch.encode_table (Some t)); go t rest
             | None -> None)
        | None -> None in
  if va < 0 || va >= Arch.user_limit then None else go pgdir Arch.levels

let lookup pgdir va =
  match walk pgdir va false with
  | Some e -> Arch.decode_page (Arch.get_entry e)
  | None -> None

(* claude: a page mapped at va (mini-9pi's faults) *)
let mapped pgdir va = lookup pgdir va <> None

let set pgdir va page =
  match walk pgdir va true with
  | Some e -> Arch.set_entry e (Arch.encode_page page); true
  | None -> false

(* a new space: an empty top table *)
let create () = kalloc ()

(* [oldsz, newsz) given fresh zeroed pages (uvmalloc); the new size, or
 * None (past the user's addresses, or no page left: what was added
 * freed) *)
let rec dealloc pgdir oldsz newsz =
  if newsz >= oldsz then oldsz
  else begin
    let a = ref (pgroundup newsz) in
    while !a < oldsz do
      (match lookup pgdir !a with
       | Some pg -> kfree pg.pa; ignore (set pgdir !a None)
       | None -> ());
      a := !a + pgsize
    done;
    newsz
  end

and alloc pgdir oldsz newsz =
  (* newsz an int: past the user's addresses, or wrapped (negative) *)
  if newsz < 0 || newsz > Arch.user_limit then None
  else if newsz < oldsz then Some oldsz
  else begin
    let rec go a =
      if a >= newsz then Some newsz
      else match kalloc () with
        | Some pa when set pgdir a (Some { pa = pa; perm = User_rw }) -> go (a + pgsize)
        | Some pa -> kfree pa; ignore (dealloc pgdir a oldsz); None
        | None -> ignore (dealloc pgdir a oldsz); None in
    go (pgroundup oldsz)
  end

(* the page under [va] no longer the user's: exec's guard (uvmclear) *)
let guard pgdir va =
  match lookup pgdir va with
  | Some pg -> ignore (set pgdir va (Some { pa = pg.pa; perm = Kernel_rw }))
  | None -> ()

(* every page and table of a space, then its top (freewalk, freevm) *)
let free pgdir =
  let rec table t levels =
    (match levels with
     | [] -> ()
     | [ (_, bits) ] ->
         for i = 0 to (1 lsl bits) - 1 do
           match Arch.decode_page (Arch.get_entry (t + (Arch.entry_bytes * i))) with Some pg -> kfree pg.pa | None -> ()
         done
     | (_, bits) :: rest ->
         for i = 0 to (1 lsl bits) - 1 do
           match Arch.decode_table (Arch.get_entry (t + (Arch.entry_bytes * i))) with Some next -> table next rest | None -> ()
         done);
    kfree t in
  table pgdir Arch.levels

(* a copy of [0, sz) in a new space (fork's uvmcopy), or None *)
(* claude: [lo, hi)'s pages copied into [dst] (mini-9pi's fork copies
 * its segments: a Plan 9 stack is at 512MB, not after the rest) *)
let copy_range pgdir dst lo hi =
  let rec go a =
    if a >= hi then true
    else match lookup pgdir a with
      | None -> go (a + pgsize)
      | Some pg ->
          (match kalloc () with
           | Some pa when set dst a (Some { pa = pa; perm = pg.perm }) -> Phys.copy pa pg.pa pgsize; go (a + pgsize)
           | Some pa -> kfree pa; false
           | None -> false) in
  go (lo land lnot (pgsize - 1))

let copy pgdir sz =
  match create () with
  | None -> None
  | Some d -> if copy_range pgdir d 0 sz then Some d else begin free d; None end

(*****************************************************************************)
(* A user's bytes *)
(*****************************************************************************)

(* the physical address of [va] (walkaddr): a user's page, one the user
 * may write ([write]), or any page mapped ([kernel]: exec loading a
 * program, into the process's own pages) *)
type reach = Kernel | User | User_write

let pa_of pgdir va reach =
  match lookup pgdir va with
  | Some pg when (match reach, pg.perm with Kernel, _ -> true | User, (User_ro | User_rw) -> true | User_write, User_rw -> true | _ -> false) ->
      Some (pg.pa + (va land (pgsize - 1)))
  | _ -> None

(* the bytes at [va] before the first page out of reach, [n] at most, a
 * page at a time *)
let prefix pgdir va n reach =
  let b = Buffer.create 64 in
  let rec go va n =
    if n > 0 then match pa_of pgdir va reach with
      | None -> ()
      | Some pa ->
          let k = min n (pgsize - (va land (pgsize - 1))) in
          Buffer.add_string b (Phys.read pa k);
          go (va + k) (n - k) in
  go va n;
  Buffer.contents b

let read_prefix pgdir va n = prefix pgdir va n User

(* copyin: all [n] bytes, or None *)
let read pgdir va n = let s = read_prefix pgdir va n in if String.length s = n then Some s else None

(* how many of [n] bytes at [va] the user can write *)
let room pgdir va n =
  let rec go va n acc =
    if n <= 0 then acc
    else match pa_of pgdir va User_write with
      | None -> acc
      | Some _ -> let k = min n (pgsize - (va land (pgsize - 1))) in go (va + k) (n - k) (acc + k) in
  go va n 0

(* [s] at [va]: all of it (true), or up to the first page out of reach *)
let write_gen reach pgdir va s =
  let rec go va i =
    if i = String.length s then true
    else match pa_of pgdir va reach with
      | None -> false
      | Some pa ->
          let k = min (String.length s - i) (pgsize - (va land (pgsize - 1))) in
          Phys.write pa (String.sub s i k);
          go (va + k) (i + k) in
  go va 0

let write pgdir va s = write_gen Kernel pgdir va s
let copyout pgdir va s = write_gen User_write pgdir va s

(* copyinstr: the string at [va], its NUL within [max] bytes *)
let read_string pgdir va max =
  let b = Buffer.create 64 in
  let rec go va left =
    if left <= 0 then None
    else match pa_of pgdir va User with
      | None -> None
      | Some pa ->
          let k = min left (pgsize - (va land (pgsize - 1))) in
          let s = Phys.read pa k in
          (try Buffer.add_string b (String.sub s 0 (String.index s '\000')); Some (Buffer.contents b)
           with Not_found -> Buffer.add_string b s; go (va + k) (left - k)) in
  go va max
