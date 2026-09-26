(* The machines as the front end sees them, whatever the back end: the
 * types' sizes and alignments, what is returned through a pointer or
 * passed in a register (the calling convention, which libc's assembly
 * and the kernel share), and which operators the machine computes
 * itself rather than by com64.c's calls. arm is 5c's (pointers are
 * longs, vlongs structures), arm64 7c's (pointers are vlongs). *)

val arm : Tree.machine
val arm64 : Tree.machine
