(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* '#|', the pipes (principia's devpipe.c): an attach makes a pipe, a
 * directory of two files, data and data1: what is written on one is
 * read on the other, a stream of up to 32KB each way; a reader waits for
 * data, a writer for room; once an end is closed, the other end's
 * reader gets the end of file, its writer an error. *)

(* the device registered *)
val init : unit -> unit
