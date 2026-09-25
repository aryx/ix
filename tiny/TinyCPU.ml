(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* tiny-cpu: TinyLibCPU.ml's CPU run alone, as a user program runs:
 * its memory is memory, and a system call is the host's, three of
 * them (r1-r3 the arguments, r1 the answer):
 *
 *     sys 0    exit, the status in r1
 *     sys 1    write r3 bytes at r2 to r1 (1 stdout, 2 stderr)
 *     sys 2    read up to r3 bytes from stdin to r2
 *
 * The instruction set, the assembler, the interpreter and their laws
 * are TinyLibCPU.ml's; TinyMachine.ml runs the same CPU with devices
 * and a kernel, where a system call is a trap.
 *
 *     tiny-cpu prog.tm            assembled and interpreted
 *     tiny-cpu -l prog.tm         the listing
 *
 * Usage: tiny-cpu [-l] file.tm [args...] *)

type caps = < Cap.stdin; Cap.stdout; Cap.stderr >

exception Exit of int

let syscall (caps : < caps; .. >) (m : TinyLibCPU.machine) n =
  let r = m.r and addr = TinyLibCPU.addr in
  match n with
  | 0 -> raise (Exit (r.(1) land 0xff))
  | 1 ->
      let s = String.init r.(3) (fun i -> Bytes.get m.mem (addr (r.(2) + i))) in
      if r.(1) = 2 then Console.eprint caps s else (Console.print caps s; flush stdout);
      r.(1) <- r.(3)
  | 2 ->
      let (_ : < Cap.stdin; .. >) = caps in
      let b = Bytes.create r.(3) in
      let k = try input stdin b 0 r.(3) with Sys_error _ -> 0 in
      Bytes.iteri (fun i c -> if i < k then Bytes.set m.mem (addr (r.(2) + i)) c) b;
      r.(1) <- k
  | n -> TinyLibCPU.error "unknown system call %d" n

let interpret caps image =
  let env = TinyLibCPU.plain ~sys:(syscall caps) in
  let m = TinyLibCPU.boot image in
  try while true do TinyLibCPU.step env m done; 0 with Exit n -> n

let main (caps : < caps; Cap.argv; Cap.open_in; .. >) =
  let args = List.tl (Array.to_list (CapSys.argv caps)) in
  let read f = Files.read caps (Fpath.v f) |> String.split_on_char '\n' in
  try
    match args with
    | "-l" :: file :: _ -> Console.print caps (TinyLibCPU.listing (TinyLibCPU.assemble (read file))); 0
    | file :: _ when file.[0] <> '-' -> interpret caps (TinyLibCPU.assemble (read file))
    | _ -> Console.eprint caps "usage: tiny-cpu [-l] file.tm [args...]\n"; 2
  with TinyLibCPU.Error e | Sys_error e -> Console.eprint caps ("tiny-cpu: " ^ e ^ "\n"); 1

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
