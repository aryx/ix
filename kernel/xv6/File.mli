(* mini-xv6's open files (xv6's file.c, pipe.c, console.c): what a file
 * descriptor names, a pipe's end, an inode, or the console (the one
 * device, major 1), each read and written its own way.
 *
 * Bytes cross here as OCaml strings: a read returns what it read (the
 * system call copies it to the user), a write gets what the user gave. *)

(* the console's input: a character from the UART (consoleintr) *)
val intr : int -> unit

(* a new open file (NFILE at most): its kind, readable, writable *)
val alloc : Types.file_kind -> bool -> bool -> Types.file option
val dup : Types.file -> Types.file
(* the last reference gone: the pipe's end closed, the inode let go *)
val close : Types.file -> unit

(* a new pipe's two ends, reading and writing *)
val pipe : unit -> (Types.file * Types.file) option

(* at most [n] bytes (a pipe's reader waits for one, the console's for
 * a line), or None: -1; the bytes written, or -1. A file's offset
 * moves *)
val read : Types.file -> int -> string option
val write : Types.file -> string -> int

(* an inode's, a device's inode *)
val inode : Types.file -> Types.inode option
