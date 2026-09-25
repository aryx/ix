(* mini-xv6's system calls (xv6's syscall.c, sysproc.c, sysfile.c, and
 * proc.c's fork, exit, wait), xv6-riscv's semantics (plan_kernel.md:
 * xv6-multiarch's forks converging): exit's status, wait's, the user's
 * memory reached through its page table only (copyin, copyout,
 * copyinstr: the guard page refused), MAXPATH. The board's ABI (Arch):
 * the number (r0, x7), the arguments (the Pi1's user stack, the Pi4's
 * x0-x5), the result in the first register. *)

(* NOFILE *)
val nofile : int

(* the running process's call, from its trap frame, its result there *)
val syscall : Types.proc -> unit

(* the running process's end, with a status: its files closed, its
 * children given to init, its parent woken; a zombie, until its
 * parent's wait frees its memory and its kernel stack. Returns only in
 * the type *)
val exit : Types.proc -> int -> unit
