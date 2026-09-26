(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* exec (principia's sysexec): a Plan 9 a.out, or a "#!" script (its
 * interpreter run with the script's name), into a new address space:
 *
 *   UTZERO 0x1000  text (the 32-byte header, big-endian, included)
 *   t              data, from the file          t = UTROUND(UTZERO+32+text)
 *   d              bss, zero, brk's to grow     d = ROUND(t+data)
 *   b                                           b = ROUND(t+data+bss)
 *   ...
 *   USTKTOP-USTKSIZE  the stack (8MB)
 *   USTKTOP-ssize-4   argc, then argv[], 0, then the strings, then
 *   USTKTOP-72        the Tos (clock, pid, ...: libc's _tos)
 *   USTKTOP 0x20000000
 *
 * as sysexec and arch_execregs lay it out, byte for byte. Only the
 * header is read, and the stack's pages the arguments are on written:
 * the rest comes at its first touch (Fault: text and data from the
 * file, the channel kept for that). *)

open Types

val utzero : int
val ustktop : int
val tos_size : int

(* [exec p path args]: the process's new program, its registers set
 * (pc, sp); the value its R0 gets (the Tos's address); Error when
 * the file is not a program, the old program kept *)
val exec : proc -> string -> string list -> int

(* the Tos's pid, after exec and fork (arch__kexit's) *)
val set_tos_pid : proc -> unit
