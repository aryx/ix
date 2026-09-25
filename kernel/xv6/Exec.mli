(* mini-xv6's exec (xv6's exec.c): a program file, an ELF32 linked at 0,
 * made the process's memory, xv6 arm-pi1's layout:
 *
 *     0           the program's segments (page-aligned)
 *     sz - 8K     the guard page: mapped, the kernel's (a stack
 *                 overflowing faults; the kernel's checks, against sz,
 *                 still accept it)
 *     sz - 4K     the stack: from its top, the argument strings, each
 *                 word-aligned, then [0xffffffff (a fake return pc);
 *                 argc; argv; argv[0] ... argv[argc-1]; 0], sp at it
 *     sz
 *
 * and main(argc, argv) entered: pc the ELF's entry, r0 argc, r1 argv. *)

(* [exec path argv]: 0, the running process running the program; or
 * -1, the process as it was *)
val exec : string -> string list -> int
