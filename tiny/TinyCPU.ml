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
 *     tiny-cpu prog.tm [args...]           assembled and interpreted
 *     tiny-cpu -o prog a.tm b.tm...        assembled and linked, an image
 *     tiny-cpu prog [args...]              the image loaded and run
 *     tiny-cpu -l prog                     the listing (or of .tm's)
 *
 * The link is TinyLibCPU's: the .tm files one after the other, their
 * labels one namespace, the first at 0 where the CPU starts. The
 * arguments are where a C program's main finds them (tiny-c -tm's
 * convention, TinyC_runtime/start.tm): their strings at the top of
 * memory, and sp on argc, then argv; argv[0] is the image's name, or
 * the last .tm's without its .tm.
 *
 * Usage: tiny-cpu [-l | -o image] file.tm... | image [args...] *)

type caps = < Cap.stdin; Cap.stdout; Cap.stderr >

exception Exit of int
exception Usage

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

let interpret caps image args =
  let env = TinyLibCPU.plain ~sys:(syscall caps) in
  let m = TinyLibCPU.boot image in
  (* the strings from the top down, then argv's array and nil, argv,
   * and argc at sp *)
  let top, addrs = List.fold_left (fun (top, addrs) a ->
    let top = top - String.length a - 1 in
    Bytes.blit_string (a ^ "\000") 0 m.mem top (String.length a + 1); top, top :: addrs) (TinyLibCPU.memsize, []) args in
  let n = List.length args in
  let sp = (top - (4 * (n + 3))) land lnot 7 in
  let put a v = TinyLibCPU.store m TinyLibCPU.W a v in
  put sp n;
  put (sp + 4) (sp + 8);
  List.iteri (fun k s -> put (sp + 8 + (4 * k)) s) (List.rev addrs);
  put (sp + 8 + (4 * n)) 0;
  m.r.(TinyLibCPU.sp) <- sp;
  try while true do TinyLibCPU.step env m done; 0 with Exit n -> n

let main (caps : < caps; Cap.argv; Cap.open_in; Cap.open_out; .. >) =
  let args = List.tl (Array.to_list (CapSys.argv caps)) in
  (* the .tm files, or the image, then the program's arguments *)
  let split l =
    let rec tms acc = function f :: r when Filename.check_suffix f ".tm" -> tms (f :: acc) r | r -> List.rev acc, r in
    match tms [] l with
    | [], f :: r when f.[0] <> '-' -> [ f ], f, r
    | [], _ -> raise Usage
    | fs, r -> fs, Filename.chop_suffix (List.nth fs (List.length fs - 1)) ".tm", r in
  let image files = TinyLibCPU.image (List.map (fun f -> f, Files.read caps (Fpath.v f)) files) in
  try
    match args with
    | "-l" :: l -> let files, _, _ = split l in Console.print caps (TinyLibCPU.listing (image files)); 0
    | "-o" :: out :: l -> let files, _, _ = split l in Files.write caps (Fpath.v out) (image files); 0
    | l -> let files, name, rest = split l in interpret caps (image files) (name :: rest)
  with
  | Usage -> Console.eprint caps "usage: tiny-cpu [-l | -o image] file.tm... | image [args...]\n"; 2
  | TinyLibCPU.Error e | Sys_error e -> Console.eprint caps ("tiny-cpu: " ^ e ^ "\n"); 1

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
