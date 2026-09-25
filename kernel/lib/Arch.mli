(* The machine's part of mini-xv6: what differs between the boards, one
 * implementation each (pi1/Arch.ml: the Pi1's ARMv6, arm32; pi4/Arch.ml:
 * the Pi4's ARMv8, arm64), the rest of the kernel written once against
 * this. The C and assembly under it are the board's too (machine.c,
 * start.s, board.h in pi1/ and pi4/: the boot, the traps, the devices);
 * what they give OCaml has the same names on both (Machine.mli).
 *
 * What is not here, because it does not differ: xv6's semantics (one,
 * xv6-riscv's: plan_kernel.md), the file system's format (the block
 * size is read from the disk: Fs), the trap frame's first registers
 * (r0/x0 the result, r1/x1 exec's argv). *)

(* the board's name: "pi1", "pi4" *)
val name : string

(*****************************************************************************)
(* Memory *)
(*****************************************************************************)

(* a user's word, and pointer: 4 or 8 bytes; a word of the user's
 * memory, little-endian, as an int (Machine.get_le32's rule on the Pi1:
 * one past 1GB is max_int) *)
val word : int
val get_word : string -> int -> int
val word_bytes : int -> string

(* a register's value as C's int (its low 32 bits, signed), and a sum
 * as C's uint (32 bits, wrapping): identities on the Pi1, whose words
 * are OCaml's ints already *)
val c_int : int -> int
val c_uint : int -> int

(* the user's addresses: [0, user_limit) *)
val user_limit : int

(* the physical pages the kernel gives the processes: [lo, hi) *)
val pages : int * int

(* a process's translation table: its levels, the top first, each an
 * index's shift and its number of bits (an entry a word of
 * [entry_bytes]); an entry of an upper level a next table's (its
 * physical address) or none, one of the last level a page or none *)
val levels : (int * int) list
val entry_bytes : int
val get_entry : int -> int
val set_entry : int -> int -> unit
val encode_table : int option -> int
val decode_table : int -> int option
val encode_page : Page.t option -> int
val decode_page : int -> Page.t option

(*****************************************************************************)
(* The trap frame, the calling convention *)
(*****************************************************************************)

(* the trap frame's words (Machine.tf_get): the pc, the user's sp, the
 * system call's number *)
val tf_pc : int
val tf_sp : int
val tf_syscall : int

(* where a system call's arguments are: on the user's stack (the Pi1:
 * xv6 arm-pi1's usys.S pushes r0-r3, argument n at sp + 4n), or in the
 * trap frame's first registers (the Pi4: x0-x5) *)
val args_on_stack : bool

(* the programs' ELF class: 1 (ELF32) or 2 (ELF64) *)
val elf_class : int
