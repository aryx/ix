(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Arch.mli: the Pi1's (ARMv6, arm32; xv6 arm-pi1's layout,
 * kernel/step4) *)

open Types

let name = "pi1"

(*****************************************************************************)
(* Memory *)
(*****************************************************************************)

let word = 4
let get_word = Machine.get_le32
let word_bytes = Machine.le32

let c_int v = v
let c_uint v = v

(* the user's addresses are the ints from 0: every one is below 1GB,
 * OCaml's largest here 0x3fffffff (1GB itself, written as a bound,
 * wrapped to min_int: kernel/step4) *)
let user_limit = max_int

(* the RAM from 256MB (the OCaml heap's end, libc.c) to 448MB (the end
 * of the kernel's mapping, start.s): 49,152 pages *)
let pages = 0x10000000, 0x1c000000

(* TTBCR N = 2: a first level of 1024 entries (1MB each, the addresses
 * below 1GB: a 4KB table), coarse tables of 256 small pages (a page
 * each: simple, not frugal) *)
let levels = [ 20, 10; 12, 8 ]
let entry_bytes = 4
let get_entry = Machine.Phys.get32
let set_entry = Machine.Phys.set32

(* ARMv6's short descriptors: a coarse table 01 and its address (domain
 * 0); a small page 1x (XN, bit 0, clear), AP in bits 5-4: 01 the
 * kernel's, 10 the user reading, 11 the user writing (APX, bit 9,
 * clear) *)
let encode_table = function Some t -> t lor 1 | None -> 0
let decode_table e = if e land 3 = 1 then Some (e land lnot 0x3ff) else None

let ap = function Kernel_rw -> 1 | User_ro -> 2 | User_rw -> 3

let encode_page = function
  | Some pg -> pg.pa lor (ap pg.perm lsl 4) lor 2
  | None -> 0

let decode_page e =
  if e land 2 = 0 then None
  else Some { pa = e land lnot 0xfff; perm = (match (e lsr 4) land 3 with 1 -> Kernel_rw | 2 -> User_ro | _ -> User_rw) }

(*****************************************************************************)
(* The trap frame (start.s): r0-r12, sp 13, lr 14, the pc 15, the CPSR 16 *)
(*****************************************************************************)

let tf_pc = 15
let tf_sp = 13
let tf_syscall = 0
let args_on_stack = true
let elf_class = 1
