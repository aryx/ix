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
let maxarg = 32

(*****************************************************************************)
(* ELF, 32 or 64 bits *)
(*****************************************************************************)

let half s o = Char.code s.[o] lor (Char.code s.[o + 1] lsl 8)

(* a word of [n] bytes (4 or 8), as Arch reads the user's *)
let field s o n = if n = 4 then Machine.get_le32 s o else Arch.get_word s o

(* the header: its size, then the entry, phoff, phnum's offsets and the
 * addresses' size; a program header: its size, then type, offset,
 * vaddr, filesz, memsz's offsets, by class (1 ELF32, 2 ELF64) *)
type layout = { ehsize : int; entry : int; phoff : int; phnum : int; addr : int;
                phsize : int; ptype : int; poffset : int; vaddr : int; filesz : int; memsz : int }

let elf32 = { ehsize = 52; entry = 24; phoff = 28; phnum = 44; addr = 4;
              phsize = 32; ptype = 0; poffset = 4; vaddr = 8; filesz = 16; memsz = 20 }
let elf64 = { ehsize = 64; entry = 24; phoff = 32; phnum = 56; addr = 8;
              phsize = 56; ptype = 0; poffset = 8; vaddr = 16; filesz = 32; memsz = 40 }

(* the program's loadable segments in [pgdir]: the size, the entry *)
let load ip pgdir =
  let l = if Arch.elf_class = 2 then elf64 else elf32 in
  match Fs.readi ip 0 l.ehsize with
  | Some elf when String.length elf = l.ehsize && String.sub elf 0 4 = "\127ELF" && Char.code elf.[4] = Arch.elf_class ->
      let rec segment i sz =
        if i = half elf l.phnum then Some (sz, field elf l.entry l.addr)
        else match Fs.readi ip (field elf l.phoff l.addr + (l.phsize * i)) l.phsize with
          | Some ph when String.length ph = l.phsize ->
              let va = field ph l.vaddr l.addr and filesz = field ph l.filesz l.addr and memsz = field ph l.memsz l.addr in
              if Machine.get_le32 ph l.ptype <> 1 then segment (i + 1) sz
              else if memsz < filesz || va + memsz < va then None
              else begin match Mmu.alloc pgdir sz (va + memsz) with
                | None -> None
                | Some sz ->
                    if va mod pgsize <> 0 then None
                    else match Fs.readi ip (field ph l.poffset l.addr) filesz with
                      | Some s when String.length s = filesz -> ignore (Mmu.write pgdir va s); segment (i + 1) sz
                      | _ -> None
              end
          | _ -> None in
      segment 0 0
  | _ -> None

(*****************************************************************************)
(* The stack *)
(*****************************************************************************)

(* the guard and the stack above [sz], the arguments on it: the new
 * size, sp, argv; None when they do not fit its page *)
let stack pgdir sz args =
  let sz = Mmu.pgroundup sz in
  match Mmu.alloc pgdir sz (sz + (2 * pgsize)) with
  | None -> None
  | Some sz ->
      Mmu.guard pgdir (sz - (2 * pgsize));
      let stackbase = sz - pgsize in
      let rec strings sp ptrs args =
        match args with
        | [] -> Some (sp, List.rev ptrs)
        | a :: rest ->
            let sp = (sp - (String.length a + 1)) land lnot 15 in
            if sp < stackbase || not (Mmu.copyout pgdir sp (a ^ "\000")) then None else strings sp (sp :: ptrs) rest in
      match strings sz [] args with
      | None -> None
      | Some (sp, ptrs) ->
          let sp = (sp - ((List.length ptrs + 1) * Arch.word)) land lnot 15 in
          let argv = String.concat "" (List.map Arch.word_bytes (ptrs @ [ 0 ])) in
          if sp < stackbase || not (Mmu.copyout pgdir sp argv) then None else Some (sz, sp)

(*****************************************************************************)
(* Exec *)
(*****************************************************************************)

(* the last element of a path, 15 bytes (xv6's name[16], NUL ended) *)
let basename path =
  let last = try String.rindex path '/' + 1 with Not_found -> 0 in
  let s = String.sub path last (String.length path - last) in
  String.sub s 0 (min 15 (String.length s))

let exec path args =
  if List.length args >= maxarg then -1
  else match Fs.namei path with
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
                | Some (sz, sp) -> Some (sz, entry, sp)
                | None -> None in
          match ready with
          | None -> Mmu.free pgdir; -1
          | Some (sz, entry, sp) ->
              let p = Proc.myproc () in
              let old = p.pgdir in
              p.name <- basename path;
              p.pgdir <- pgdir;
              p.sz <- sz;
              Machine.tf_set Arch.tf_pc entry;
              Machine.tf_set Arch.tf_sp sp;
              Machine.tf_set 1 sp;
              Machine.mmu_switch pgdir;
              Mmu.free old;
              List.length args
