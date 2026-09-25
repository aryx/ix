(* mini-xv6's exec (xv6-riscv's exec.c, xv6 arm64-pi4's): a program
 * file, an ELF linked at 0 (ELF32 on the Pi1, ELF64 on the Pi4: the
 * board's class, Arch.elf_class), made the process's memory:
 *
 *     0           the program's segments (page-aligned)
 *     sz - 8K     the guard page: mapped, the kernel's (a stack
 *                 overflowing faults, and the kernel's copies refuse it)
 *     sz - 4K     the stack, one page: from its top, the argument
 *                 strings, each 16-byte aligned, then argv[0] ...
 *                 argv[argc-1], 0 (the board's words), 16-byte aligned,
 *                 sp at it; what does not fit the page fails the exec
 *     sz
 *
 * and main(argc, argv) entered: pc the ELF's entry, the first register
 * argc (exec's result), the second argv; the process named after the
 * path's last element. *)

(* [exec path argv]: argc, the running process running the program; or
 * -1, the process as it was *)
val exec : string -> string list -> int
