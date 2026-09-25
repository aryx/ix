(* mini-xv6: the machine (machine.c's primitives). Addresses as ints: a
 * user's (below 1GB) and a physical one (below 512MB) fit OCaml's 31
 * bits on the Pi1; the kernel's own never reach OCaml (plan_kernel.md,
 * decision 3; kernel/step4). *)

(* physical memory, by physical address *)
module Phys : sig
  external get8 : int -> int = "phys_get8"
  external set8 : int -> int -> unit = "phys_set8"
  external get16 : int -> int = "phys_get16"
  external set16 : int -> int -> unit = "phys_set16"
  external get32 : int -> int = "phys_get32"
  external set32 : int -> int -> unit = "phys_set32"
  (* [zero pa n]: n a multiple of 4 *)
  external zero : int -> int -> unit = "phys_zero"
  (* [copy dst src n], [write pa s], [read pa n] *)
  external copy : int -> int -> int -> unit = "phys_copy"
  external write : int -> string -> unit = "phys_write"
  external read : int -> int -> string = "phys_read"
end

(* the running process's trap frame, by word: r0-r12, sp 13, lr 14, the
 * pc 15, the CPSR 16 *)
external tf_get : int -> int = "tf_get"
external tf_set : int -> int -> unit = "tf_set"
(* a word whose top bits matter (the CPSR's flags) *)
external tf_get32 : int -> Int32.t = "tf_get32"
(* a slot's trap frame: zeros, user mode, IRQs on *)
external tf_init : int -> unit = "tf_init"
(* the running process's copied to a slot's, r0 0 (fork's child) *)
external tf_copy : int -> unit = "tf_copy"

(* a slot's kernel stack made fresh: its first switch enters
 * "process_start"; a slot freed (the collector no longer scans it) *)
external proc_context : int -> unit = "proc_context"
external proc_free : int -> unit = "proc_free"
(* to a slot (a process's, or nproc: the scheduler's); the running one *)
external swtch : int -> unit = "k_swtch"
external current : unit -> int = "k_current"
(* back to user mode, from the running process's trap frame *)
external user_resume : unit -> unit = "user_resume"

(* the user's table in TTBR0 (0: the empty one), the TLB flushed *)
external mmu_switch : int -> unit = "mmu_switch"

(* the system timer: a tick in [us] microseconds; its interrupt pending;
 * wfi, IRQs masked *)
external timer_arm : int -> unit = "timer_arm"
external timer_pending : unit -> bool = "timer_pending"
external wait_interrupt : unit -> unit = "wait_interrupt"

(* the PL011: a character out; one in, or -1; its receive interrupt on *)
external uart_putc : int -> unit = "uart_putc"
external uart_getc : unit -> int = "uart_getc"
external uart_rx_enable : unit -> unit = "uart_rx_enable"
external halt : unit -> unit = "machine_halt"

(* the file system's image: its physical address, its size *)
external fs_base : unit -> int = "fs_base"
external fs_size : unit -> int = "fs_size"

(* the console's output: a newline goes out as CR LF (xv6 arm-pi1's
 * uartputc) *)
val putc : char -> unit
val print : string -> unit

(* the message, the machine stopped (xv6's panic) *)
val panic : string -> 'a

(* little-endian bytes, as C lays out a short and an int *)
val le16 : int -> string
val le32 : int -> string

(* [get_le32 s off]: a word as C's int. OCaml's int has 31 bits here:
 * the words from -1GB to 1GB are exact; the others (as an address, 1GB
 * and up: none of a user's) come back as max_int, which every bound
 * refuses *)
val get_le32 : string -> int -> int
