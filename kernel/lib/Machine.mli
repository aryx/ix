(* mini-xv6: the machine, as the board's machine.c and runtime.c give it
 * (the same names on the Pi1 and the Pi4). Addresses are ints: a
 * user's and a physical one fit OCaml's (31 bits on the Pi1: below
 * 1GB; 63 on the Pi4); the kernel's own never reach OCaml (plan_kernel.md,
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

(* the running process's trap frame, by word (Arch: its layout, the
 * board's) *)
external tf_get : int -> int = "tf_get"
external tf_set : int -> int -> unit = "tf_set"
(* a slot's trap frame: zeros, user mode, IRQs on *)
external tf_init : int -> unit = "tf_init"
(* the running process's copied to a slot's, the first register 0
 * (fork's child) *)
external tf_copy : int -> unit = "tf_copy"
(* claude: the running process's trap frame as bytes, whole (a word a
 * register, the board's layout; their 32 bits: mini-9pi's notes) *)
external tf_bytes : unit -> string = "tf_bytes"
external tf_set_bytes : string -> unit = "tf_set_bytes"

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

(* the framebuffer: [fb_init w h depth], its physical address (0: none);
 * its pitch (bytes a row); the console's font (start.s) *)
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

(* the console's output, as it is (no CR before a newline: xv6-riscv's) *)
val putc : char -> unit

(* the output's other way: the framebuffer's console (Screen), once
 * there is one *)
val screen : (char -> unit) ref
val print : string -> unit

(* the message, the machine stopped (xv6's panic) *)
val panic : string -> 'a

(* little-endian bytes, as C lays out a short and an int *)
val le16 : int -> string
val le32 : int -> string

(* [get_le32 s off]: a 32-bit word as C's int. On the Pi1 OCaml's int
 * has 31 bits: the words from -1GB to 1GB are exact; the others (as an
 * address, 1GB and up: none of a user's) come back as max_int, which
 * every bound refuses *)
val get_le32 : string -> int -> int
