(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Machine.mli *)

(* physical memory, by physical address *)
module Phys = struct
  external get8 : int -> int = "phys_get8"
  external set8 : int -> int -> unit = "phys_set8"
  external get16 : int -> int = "phys_get16"
  external set16 : int -> int -> unit = "phys_set16"
  external get32 : int -> int = "phys_get32"
  external set32 : int -> int -> unit = "phys_set32"
  external zero : int -> int -> unit = "phys_zero"
  (* bytes: [n] copied from [src] to [dst], a string written, [n] read *)
  external copy : int -> int -> int -> unit = "phys_copy"
  external write : int -> string -> unit = "phys_write"
  external read : int -> int -> string = "phys_read"
end

(* the running process's trap frame, by word: r0-r12, sp 13, lr 14, the
 * pc 15, the CPSR 16 *)
external tf_get : int -> int = "tf_get"
external tf_set : int -> int -> unit = "tf_set"
external tf_init : int -> unit = "tf_init"
external tf_copy : int -> unit = "tf_copy"

(* the kernel stacks: a slot's made fresh, freed; the switch *)
external proc_context : int -> unit = "proc_context"
external proc_free : int -> unit = "proc_free"
external swtch : int -> unit = "k_swtch"
external current : unit -> int = "k_current"
external user_resume : unit -> unit = "user_resume"

(* the user's table in TTBR0 (0: the empty one) *)
external mmu_switch : int -> unit = "mmu_switch"

(* the devices: the system timer, the PL011 *)
external timer_arm : int -> unit = "timer_arm"
external timer_pending : unit -> bool = "timer_pending"
external wait_interrupt : unit -> unit = "wait_interrupt"
external uart_putc : int -> unit = "uart_putc"
external uart_getc : unit -> int = "uart_getc"
external uart_rx_enable : unit -> unit = "uart_rx_enable"
external halt : unit -> unit = "machine_halt"

(* the file system's image *)
external fs_base : unit -> int = "fs_base"
external fs_size : unit -> int = "fs_size"
external fb_init : int -> int -> int -> int = "fb_init"
external fb_pitch : unit -> int = "fb_pitch"
external font_base : unit -> int = "font_base"

(* claude: a peripheral's register by its offset from the peripherals'
 * base (0x20000000 on the Pi1): [io_get16 off high] one 16-bit half of
 * the 32-bit word, [io_set32 off hi lo] the word written from its
 * halves (a word is past the Pi1's ints) *)
external io_get16 : int -> bool -> int = "io_get16"
external io_set32 : int -> int -> int -> unit = "io_set32"
(* claude: a data port read [n] bytes' worth (32-bit loads), or written
 * a string's words *)
external io_read_fifo : int -> int -> string = "io_read_fifo"
external io_write_fifo : int -> string -> unit = "io_write_fifo"

(* the console's output, as it is (xv6-riscv's: no CR added before a
 * newline, as xv6 arm-pi1's uartputc did) *)
(* the screen's console, once there is one (Screen.init) *)
let screen = ref (fun (_ : char) -> ())

let putc c = uart_putc (Char.code c); !screen c
let print s = for i = 0 to String.length s - 1 do putc s.[i] done

(* the kernel's end: xv6's panic *)
let panic s = print ("panic: " ^ s ^ "\n"); halt (); failwith s

(*****************************************************************************)
(* Bytes as C lays them out *)
(*****************************************************************************)

(* little-endian halves and words, the user's and the disk's *)
let le16 v = let s = String.create 2 in
  String.set s 0 (Char.chr (v land 0xff)); String.set s 1 (Char.chr ((v lsr 8) land 0xff)); s
let le32 v = le16 (v land 0xffff) ^ le16 ((v asr 16) land 0xffff)

let get_le32 s o =
  let low = Char.code s.[o] lor (Char.code s.[o + 1] lsl 8) lor (Char.code s.[o + 2] lsl 16) in
  let b3 = Char.code s.[o + 3] in
  if b3 < 0x40 then low lor (b3 lsl 24)
  else if b3 >= 0xc0 then low lor ((b3 - 0x100) lsl 24)
  else max_int
