(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* tiny-arm: TinyLibArm.ml's CPU run as Linux runs a user program, and
 * the ELF writer that lets the real CPU run it too:
 *
 *     tiny-arm hello.s              assembled and run
 *     tiny-arm -o hello hello.s     the executable, for Linux on ARM
 *     tiny-arm -l hello.s           the listing, as objdump prints it
 *
 * The operating system is three calls: read, write, exit, as Linux
 * numbers them (r7), so that the ELF written runs on Linux as the
 * interpreter runs it. The instruction set, the assembler, the
 * interpreter and their laws are TinyLibArm.ml's; TinyMachinePi.ml (planned,
 * plan_pi.md) runs the same CPU with the Pi1's devices, where an svc
 * is an exception taken.
 *
 * Usage: tiny-arm [-o out | -l | -b out] file.s [args...]
 *   -b: the text alone, assembled at address 0 (for GNU as's object) *)

(*****************************************************************************)
(* Linux: the system calls, running, and the executable *)
(*****************************************************************************)

exception Exit of int

type caps = < Cap.stdin; Cap.stdout; Cap.stderr >

let syscall (caps : < caps; .. >) (m : TinyLibArm.machine) (_ : int) =
  let r = m.r in
  match r.(7) with
  | 1 | 248 -> raise (Exit (r.(0) land 0xff))
  | 3 ->
      let (_ : < Cap.stdin; .. >) = caps in
      let b = Bytes.create r.(2) in
      let n = try input stdin b 0 r.(2) with Sys_error _ -> -1 in
      if n > 0 then (TinyLibArm.check m r.(1) n; Bytes.blit b 0 m.mem r.(1) n);
      r.(0) <- TinyLibArm.m32 n
  | 4 ->
      TinyLibArm.check m r.(1) r.(2);
      let s = Bytes.sub_string m.mem r.(1) r.(2) in
      if r.(0) = 2 then Console.eprint caps s else (Console.print caps s; flush stdout);
      r.(0) <- r.(2)
  | n -> TinyLibArm.error "unimplemented system call %d" n

(* where the program goes: the text right after the ELF headers, so
 * that the executable's one segment starts at 0x10000 *)
let base = 0x10000
let headers = 52 + 32
let origin = base + headers

let entry labels = Option.value (Hashtbl.find_opt labels "_start") ~default:origin

let run caps image labels args =
  let m = TinyLibArm.create () and size = TinyLibArm.size in
  Bytes.blit_string image 0 m.mem origin (String.length image);
  (* the stack as Linux's execve leaves it: argc, argv, nil, envp's nil *)
  let strs = List.fold_left (fun top s -> let top = top - String.length s - 1 in Bytes.blit_string s 0 m.mem top (String.length s); top) size args in
  let ptrs = List.rev (snd (List.fold_left (fun (a, acc) s -> a + String.length s + 1, a :: acc) (strs, []) (List.rev args))) in
  let sp = (strs - (4 * (List.length args + 3))) land lnot 7 in
  TinyLibArm.store32 m sp (List.length args);
  List.iteri (fun i p -> TinyLibArm.store32 m (sp + 4 + (4 * i)) p) ptrs;
  m.r.(13) <- sp;
  m.r.(15) <- entry labels;
  let env = TinyLibArm.plain ~svc:(syscall caps) in
  try while true do TinyLibArm.step env m done; 0 with Exit n -> n

let elf image labels =
  let size = headers + String.length image in
  let b = Buffer.create size in
  let u16 v = Buffer.add_uint16_le b v and u32 v = Buffer.add_int32_le b (Int32.of_int v) in
  Buffer.add_string b "\x7fELF\001\001\001\000"; Buffer.add_string b (String.make 8 '\000');
  u16 2; u16 40; u32 1; u32 (entry labels); u32 52; u32 0; u32 0x05000000; u16 52; u16 32; u16 1; u16 0; u16 0; u16 0;
  (* one segment, the headers and the program, readable, writable,
   * executable, with a stack's worth of zeros after it *)
  u32 1; u32 0; u32 base; u32 base; u32 size; u32 (size + 0x10000); u32 7; u32 0x1000;
  Buffer.add_string b image;
  Buffer.contents b

let main (caps : < caps; Cap.argv; Cap.open_in; Cap.open_out; .. >) =
  let args = List.tl (Array.to_list (CapSys.argv caps)) in
  let read f = Files.read caps (Fpath.v f) |> String.split_on_char '\n' in
  try
    match args with
    | "-l" :: file :: _ ->
        let _, _, code = TinyLibArm.assemble ~origin (read file) in
        Console.print caps (TinyLibArm.listing code); 0
    | "-o" :: out :: file :: _ ->
        let image, labels, _ = TinyLibArm.assemble ~origin (read file) in
        Files.write caps ~perm:0o755 (Fpath.v out) (elf image labels); 0
    | "-b" :: out :: file :: _ -> let image, _, _ = TinyLibArm.assemble ~origin:0 (read file) in Files.write caps (Fpath.v out) image; 0
    | file :: _ when file.[0] <> '-' -> let image, labels, _ = TinyLibArm.assemble ~origin (read file) in run caps image labels args
    | _ -> Console.eprint caps "usage: tiny-arm [-o out | -l | -b out] file.s [args...]\n"; 2
  with TinyLibArm.Error e | Sys_error e -> Console.eprint caps ("tiny-arm: " ^ e ^ "\n"); 1

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
