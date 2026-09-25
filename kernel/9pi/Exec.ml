(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Exec.mli *)

open Types

let pgsize = Mmu.pgsize
let round n a = (n + a - 1) land lnot (a - 1)

let utzero = 0x1000
let ustktop = 0x20000000
let ustksize = 8 * 1024 * 1024
let tos_size = 72
let hdr_size = 32
let aout_magic = 0x647

(* the stack's pages given at exec, until faults give them *)
let stack_pages = 64

(* the Pi1's clock, as 9pi's Tos says it (cpu->cpuhz) *)
let cyclefreq = 700000000

let be32 s o =
  (Char.code s.[o] lsl 24) lor (Char.code s.[o + 1] lsl 16) lor (Char.code s.[o + 2] lsl 8) lor Char.code s.[o + 3]

(*****************************************************************************)
(* The file *)
(*****************************************************************************)

(* all of a channel's first [n] bytes *)
let read_all c n =
  let d = Dev.find c.dev in
  let b = Buffer.create n in
  let rec go () =
    if Buffer.length b < n then begin
      let s = d.Dev.read c (n - Buffer.length b) (Buffer.length b) in
      if s <> "" then begin Buffer.add_string b s; go () end
    end in
  go ();
  Buffer.contents b

(* a "#!" line's words (shargs): the interpreter and its arguments *)
let shargs s =
  let s = String.sub s 2 (String.length s - 2) in
  let s = try String.sub s 0 (String.index s '\n') with Not_found -> raise (Error ebadexec) in
  List.filter (fun w -> w <> "") (String.split_on_char ' ' (String.map (fun c -> if c = '\t' then ' ' else c) s))

(* the program: its channel (opened), its header, the arguments (a
 * script's: the "#!" line's words, argv[0] the script's name, then its
 * path, then the caller's arguments but argv[0]) *)
let rec resolve p path args indir =
  let c = Chan.namec p path in
  Chan.open_ c (Chan.mode_of_int 3);
  let hdr = (Dev.find c.dev).Dev.read c hdr_size 0 in
  if String.length hdr < 2 then raise (Error ebadexec)
  else if String.length hdr = hdr_size && be32 hdr 0 = aout_magic then c, hdr, args
  else if indir || hdr.[0] <> '#' || hdr.[1] <> '!' then raise (Error ebadexec)
  else begin
    Chan.close c;
    match shargs hdr with
    | [] -> raise (Error ebadexec)
    | interp :: rest ->
        let args = match args with [] -> [] | _ :: tl -> tl in
        resolve p interp (Chan.basename path :: rest @ (path :: args)) true
  end

(*****************************************************************************)
(* The stack *)
(*****************************************************************************)

(* [ssize] and the bytes of [USTKTOP-ssize-4, USTKTOP): argc, argv, the
 * strings, the Tos *)
let stack_image args pid =
  let nargs = List.length args in
  let nbytes = tos_size + List.fold_left (fun n a -> n + String.length a + 1) 0 args in
  let ssize = (4 * (nargs + 1)) + round nbytes 4 in
  let ssize = if (ssize + 4) land 7 <> 0 then ssize + 4 else ssize in
  let base = ustktop - ssize - 4 in
  let img = String.make (ssize + 4) '\000' in
  let put addr s = String.blit s 0 img (addr - base) (String.length s) in
  put base (Machine.le32 nargs);
  let rec strings i charp args =
    match args with
    | [] -> ()
    | a :: rest ->
        put (ustktop - ssize + (4 * i)) (Machine.le32 charp);
        put charp a;
        strings (i + 1) (charp + String.length a + 1) rest in
  strings 0 (ustktop - nbytes) args;
  (* the Tos: cyclefreq (a uvlong at 24), pid (52) *)
  let tos = ustktop - tos_size in
  put (tos + 24) (Machine.le32 cyclefreq);
  put (tos + 52) (Machine.le32 pid);
  ssize, img

let set_tos_pid p = ignore (Mmu.write p.pgdir (ustktop - tos_size + 52) (Machine.le32 p.pid))

(*****************************************************************************)
(* Exec *)
(*****************************************************************************)

let alloc pgdir lo hi = if hi > lo then match Mmu.alloc pgdir lo hi with Some _ -> () | None -> raise (Error enovmem)

let exec p path args =
  let c, hdr, args = resolve p path args false in
  let text = be32 hdr 4 and data = be32 hdr 8 and bss = be32 hdr 12 and entry = be32 hdr 20 in
  if text >= ustktop - utzero || entry < utzero + hdr_size || entry >= utzero + hdr_size + text then begin
    Chan.close c; raise (Error ebadexec)
  end;
  let t = round (utzero + hdr_size + text) pgsize in
  let d = round (t + data) pgsize and b = round (t + data + bss) pgsize in
  let ssize, stack = stack_image args p.pid in
  if ssize > stack_pages * pgsize then begin Chan.close c; raise (Error enovmem) end;
  let file = read_all c (hdr_size + text + data) in
  Chan.close c;
  if String.length file <> hdr_size + text + data then raise (Error ebadexec);
  let pgdir = match Mmu.create () with Some d -> d | None -> raise (Error enovmem) in
  (try
    alloc pgdir utzero b;
    alloc pgdir (ustktop - (stack_pages * pgsize)) ustktop;
    ignore (Mmu.write pgdir utzero (String.sub file 0 (hdr_size + text)));
    ignore (Mmu.write pgdir t (String.sub file (hdr_size + text) data));
    ignore (Mmu.write pgdir (ustktop - String.length stack) stack)
  with e -> Mmu.free pgdir; raise e);
  (* committed: the old memory freed, the close-on-exec files closed *)
  let old = p.pgdir in
  p.pgdir <- pgdir;
  p.segs <- [ { kind = Text; base = utzero; top = t }; { kind = Data; base = t; top = d };
              { kind = Bss; base = d; top = b }; { kind = Stack; base = ustktop - ustksize; top = ustktop } ];
  p.text <- Chan.basename path;
  Array.iteri (fun fd o -> match o with
    | Some c when (match c.opened with Some m -> m.cexec | None -> false) -> Chan.close c; p.fgrp.fds.(fd) <- None
    | _ -> ()) p.fgrp.fds;
  Machine.mmu_switch pgdir;
  if old <> 0 then Mmu.free old;
  Machine.tf_set Arch.tf_pc entry;
  Machine.tf_set Arch.tf_sp (ustktop - ssize - 4);
  ustktop - tos_size
