(* The Linux process a program starts as, and its system calls (the
 * user-mode personality, plan_arm.md, decision 6).
 *
 * The stack, from sp up, as Linux's execve leaves it:
 *
 *   sp ->  argc
 *          argv[0] .. argv[argc-1], 0
 *          envp[0] .. , 0
 *          auxv: (AT_PAGESZ, 4096), (AT_ENTRY, entry), (AT_RANDOM, p),
 *                (AT_NULL, 0)
 *          ... the strings, 16 random bytes
 *
 * A system call on arm32: `svc 0`, its number in r7 (EABI), arguments
 * in r0-r5 (a 64-bit one in an even pair), the result in r0, an error
 * as -errno. The guest's structures are laid out as the arm32 ABI has
 * them (struct stat64 104 bytes, its size at 48, times at 72, the
 * 64-bit inode at 96: as goken's os/linux/stat_arm.c reads them).
 *
 * The calls reach the host through [host], a record of functions: this
 * module uses no Unix, so that the machine runs where OCaml runs, a
 * browser included (plan_pi.md, decision 9); Host implements it on
 * Unix. File descriptors are the host's own, as qemu-user has them.
 *
 * Signals: the host notes a signal (raise_signal); between two
 * instructions [deliver] saves the registers on the guest's stack and
 * enters the handler with lr at a trampoline page ("mov r7, #119; svc
 * 0": a sigreturn, as the kernel's sigpage does for handlers without a
 * restorer, goken's case), whose sigreturn puts the registers back. *)

type errno = int
type 'a r = ('a, errno) result

type kind = Reg | Dir | Chr | Blk | Fifo | Lnk | Sock

type stat = {
  dev : int; ino : int; kind : kind; perm : int; nlink : int; uid : int; gid : int; rdev : int;
  size : int; atime : float; mtime : float; ctime : float;
}

type dirent = { d_ino : int; d_name : string; d_kind : kind }

type disposition = Default | Ignore | Catch

type host = {
  read : int -> int -> string r;
  write : int -> string -> int r;
  openat : int option -> string -> int -> int -> int r;  (* a directory fd (not AT_FDCWD), path, Linux's flags, mode *)
  close : int -> unit r;
  fstat : int -> stat r;
  lseek : int -> int -> int -> int r;
  unlink : string -> unit r;
  rmdir : string -> unit r;
  chdir : string -> unit r;
  mkdir : string -> int -> unit r;
  access : string -> int -> unit r;
  fchmod : int -> int -> unit r;
  ftruncate : int -> int -> unit r;
  rename : string -> string -> unit r;
  dup : int -> int r;
  dup2 : int -> int -> int r;
  getcwd : unit -> string;
  getpid : unit -> int;
  pipe : unit -> (int * int) r;
  fork : unit -> int r;
  wait4 : int -> int -> (int * int) r;         (* pid, options: pid, Linux's status *)
  kill : int -> int -> unit r;
  readdir : int -> dirent option r;             (* a directory fd's next entry *)
  isatty : int -> bool;
  now : unit -> float;
  sleep : float -> unit;
  setitimer : float -> float -> float * float;  (* interval, value: the old ones *)
  signal : int -> disposition -> unit;
}

exception Exit of int

(* execve of a program: the path, argv, envp; the caller loads it *)
exception Exec of string * string list * string list

type proc

(* the ELF's segments mapped, the heap, the stack, the trampoline; the
 * process, the entry and the initial sp *)
val load : host -> Memory.t -> Elf.t -> string -> string list -> string list -> proc * int * int

(* each call logged to standard error, "[pid] nr(a0, a1, a2) = result" (-y) *)
val log_calls : bool ref

(* arm32's svc: the call in r7 *)
val syscall32 : proc -> Arm32.state -> unit

(* arm64's svc: the call in x8, asm-generic's numbers and structures
 * (struct stat 128 bytes, 64-bit timespecs, 8-byte vectors) *)
val syscall64 : proc -> Arm64.state -> unit

(* a signal the host received *)
val raise_signal : int -> unit
val signal_waiting : bool ref

(* the pending signals delivered at [pc], the next instruction *)
val deliver : proc -> Arm32.state -> pc:int -> unit

val deliver64 : proc -> Arm64.state -> pc:int -> unit
