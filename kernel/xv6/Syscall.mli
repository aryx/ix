(* mini-xv6's system calls (xv6's syscall.c, sysproc.c, sysfile.c, and
 * proc.c's fork, exit, wait), xv6 arm-pi1's ABI: the number in r0, swi,
 * the arguments on the user's stack (usys.S pushes r0-r3: argument n at
 * sp + 4n), the result in r0.
 *
 * The arguments are checked as xv6's are, against sz only: a pointer
 * into the guard page is accepted, and the kernel reads and writes the
 * page (xv6's kernel reaches all of a process's memory). *)

(* NOFILE *)
val nofile : int

(* the running process's call, from its trap frame, its result there *)
val syscall : Types.proc -> unit

(* the running process's end: its files closed, its children given to
 * init, its parent woken; a zombie, until its parent's wait frees its
 * memory and its kernel stack. Returns only in the type *)
val exit : Types.proc -> unit
