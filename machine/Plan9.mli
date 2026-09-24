(* The Plan 9 process a program starts as, and its system calls: 5i's
 * personality (plan_arm.md, phase 8), for the a.out goken's and ix's
 * linkers write with -H2, run by the arm32 core.
 *
 * The a.out: a 32-byte big-endian header (magic 0x647, arm's; the text,
 * data and bss sizes, the entry), the text loaded with its header at
 * 0x1000, the data on the next page, the bss after it. The stack below
 * 0x80000000, as 5i's initstk lays it out: the Tos at its top (r0
 * points at it), then argc (argv[0] counted), argv, nil.
 *
 * A system call: `svc 0`, its number in r0 (principia's sys.h), the
 * arguments on the stack from sp+4 (where 5c's calling convention has
 * put them already), the result in r0; an error returns -1 and leaves
 * its text in the process's error string (errstr exchanges it).
 *
 * Plan 9 reaches much of the system through files, not calls: the few
 * the libc opens are the emulator's own (#c/pid, /dev/bintime,
 * /env/NAME, /proc/PID/note), the rest the host's. Directories read as
 * 9P stat records; notes (a posted one, or the host's SIGALRM as
 * "alarm") are delivered as principia's kernel delivers them, a Ureg
 * and the note's text on the stack and the notify() handler called,
 * noted(NCONT) putting the Ureg back. A child's exit string reaches
 * its parent's await through a pipe the fork made. *)

type aout = { text : int; data : int; bss : int; entry : int }

(* the header, when the file is an arm Plan 9 a.out *)
val parse : string -> aout option

type proc

(* the process, the entry, the initial sp, the Tos (r0) *)
val load : Linux.host -> Memory.t -> aout -> string -> string list -> string list -> proc * int * int * int

(* each call logged to standard error by name (-y) *)
val log_calls : bool ref

val syscall : proc -> Arm32.state -> unit

(* the pending notes delivered at [pc], the next instruction *)
val deliver : proc -> Arm32.state -> pc:int -> unit
