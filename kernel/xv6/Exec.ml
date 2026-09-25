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
let word = Machine.get_le32
let half s o = Char.code s.[o] lor (Char.code s.[o + 1] lsl 8)

(* the program's loadable segments in [pgdir]: the size, the entry. The
 * ELF header: its entry at 24, phoff at 28, phnum at 44; a program
 * header, 32 bytes: type at 0 (1: PT_LOAD), off 4, vaddr 8, filesz 16,
 * memsz 20 *)
let load ip pgdir =
  match Fs.readi ip 0 52 with
  | Some elf when String.length elf = 52 && String.sub elf 0 4 = "\127ELF" ->
      let rec segment i sz =
        if i = half elf 44 then Some (sz, word elf 24)
        else match Fs.readi ip (word elf 28 + (32 * i)) 32 with
          | Some ph when String.length ph = 32 ->
              let va = word ph 8 and filesz = word ph 16 and memsz = word ph 20 in
              if word ph 0 <> 1 then segment (i + 1) sz
              else if memsz < filesz then None
              else begin match Mmu.alloc pgdir sz (va + memsz) with
                | None -> None
                | Some sz ->
                    if va mod pgsize <> 0 then Machine.panic "loaduvm: addr must be page aligned";
                    match Fs.readi ip (word ph 4) filesz with
                    | Some s when String.length s = filesz -> ignore (Mmu.write pgdir va s); segment (i + 1) sz
                    | _ -> None
              end
          | _ -> None in
      segment 0 0
  | _ -> None

(* the guard and the stack above [sz], the arguments on it: the new
 * size, sp, argv *)
let stack pgdir sz args =
  let sz = Mmu.pgroundup sz in
  match Mmu.alloc pgdir sz (sz + (2 * pgsize)) with
  | None -> None
  | Some sz ->
      Mmu.guard pgdir (sz - (2 * pgsize));
      let rec strings sp ptrs args =
        match args with
        | [] -> Some (sp, List.rev ptrs)
        | a :: rest ->
            let sp = (sp - (String.length a + 1)) land lnot 3 in
            if Mmu.copyout pgdir sp (a ^ "\000") then strings sp (sp :: ptrs) rest else None in
      match strings sz [] args with
      | None -> None
      | Some (sp, ptrs) ->
          let argc = List.length ptrs in
          let argv = sp - ((argc + 1) * 4) in
          let ustack = List.map Machine.le32 ([ -1; argc; argv ] @ ptrs @ [ 0 ]) in
          let sp = sp - ((3 + argc + 1) * 4) in
          if Mmu.copyout pgdir sp (String.concat "" ustack) then Some (sz, sp, argc, argv) else None

(* 0, the process running the program; or -1, the process as it was *)
let exec path args =
  match Fs.namei path with
  | None -> -1
  | Some ip ->
      match Mmu.create () with
      | None -> Fs.iput ip; -1
      | Some pgdir ->
          let loaded = load ip pgdir in
          Fs.iput ip;
          let ready = match loaded with
            | None -> None
            | Some (sz, entry) ->
                match stack pgdir sz args with
                | Some (sz, sp, argc, argv) -> Some (sz, entry, sp, argc, argv)
                | None -> None in
          match ready with
          | None -> Mmu.free pgdir; -1
          | Some (sz, entry, sp, argc, argv) ->
              let p = Proc.myproc () in
              let old = p.pgdir in
              (* its name, for the messages: argv[0], 15 bytes (xv6's 16, NUL ended) *)
              (match args with a :: _ -> p.name <- String.sub a 0 (min 15 (String.length a)) | [] -> ());
              p.pgdir <- pgdir;
              p.sz <- sz;
              Machine.tf_set 15 entry;
              Machine.tf_set 13 sp;
              Machine.tf_set 0 argc;
              Machine.tf_set 1 argv;
              Machine.mmu_switch pgdir;
              Mmu.free old;
              0
