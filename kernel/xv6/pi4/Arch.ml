(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Arch.mli: the Pi4's (ARMv8, arm64; xv6 arm64-pi4's layout) *)

open Types

let name = "pi4"

(*****************************************************************************)
(* Memory *)
(*****************************************************************************)

external get64 : int -> int = "phys_get64"
external set64 : int -> int -> unit = "phys_set64"

let word = 8

(* a word as an int: OCaml's has 63 bits here, exact while bits 63 and
 * 62 agree (the user's addresses, the small negatives); the others
 * come back as max_int, which every bound refuses (0x8000000000001000
 * must not alias 0x1000) *)
let get_word s o =
  let top = Char.code s.[o + 7] lsr 6 in
  if top = 1 || top = 2 then max_int
  else begin
    let rec go k acc = if k < 0 then acc else go (k - 1) ((acc lsl 8) lor Char.code s.[o + k]) in
    go 7 0
  end

let word_bytes v =
  let s = String.create 8 in
  for k = 0 to 7 do String.set s k (Char.chr ((v asr (8 * k)) land 0xff)) done;
  s

let c_int v = ((v land 0xffffffff) lxor 0x80000000) - 0x80000000
let c_uint v = v land 0xffffffff

(* TTBR0's addresses: T0SZ 25, 39 bits *)
let user_limit = 1 lsl 39

(* the RAM from 256MB (the OCaml heap's end, board.h) to 384MB: 32,768
 * pages (xv6 arm64-pi4 has about as many: PHYSTOP 128MB) *)
let pages = 0x10000000, 0x18000000

(* 4KB pages, three levels of 512 entries (1GB, 2MB, 4KB) *)
let levels = [ 30, 9; 21, 9; 12, 9 ]
let entry_bytes = 8
let get_entry = get64
let set_entry = set64

(* ARMv8's descriptors: a table 11 and its address; a page 11 and its
 * address, AttrIndx 2 (MAIR's normal write-back memory: start.s), inner
 * shareable (0x300), accessed (AF, 0x400), not global (nG, 0x800: the
 * process's), AP in bits 7-6: 00 the kernel's, 01 the user writing, 11
 * the user reading (xv6 arm64-pi4's PTE_NORMAL | PTE_USER: 0xf4b) *)
let address = 0xfffffffff000

let encode_table = function Some t -> t lor 3 | None -> 0
let decode_table e = if e land 3 = 3 then Some (e land address) else None

let ap = function Kernel_rw -> 0 | User_rw -> 1 | User_ro -> 3

let encode_page = function
  | Some pg -> pg.pa lor (ap pg.perm lsl 6) lor 0xf0b
  | None -> 0

let decode_page e =
  if e land 3 <> 3 then None
  else Some { pa = e land address; perm = (match (e lsr 6) land 3 with 1 -> User_rw | 3 -> User_ro | _ -> Kernel_rw) }

(*****************************************************************************)
(* The trap frame (start.s): x0-x30, sp_el0 31, elr_el1 (the pc) 32,
 * spsr_el1 33 *)
(*****************************************************************************)

let tf_pc = 32
let tf_sp = 31
let tf_syscall = 7
let args_on_stack = false
let elf_class = 2
