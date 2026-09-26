(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devroot.mli *)

open Types

(* the qids' paths: the root 0, /boot 0x1000; the root's directories
 * i + 1 and the boot files 0x1000 + i + 1, i their index in the C's
 * lists (whose first entries are "#/" and "boot" themselves) *)
let qdir = 0
let qboot = 0x1000

let dirqid path = { path = path; vers = 0; typ = Qt_dir }

let rootdirs = [ "bin"; "dev"; "env"; "fd"; "mnt"; "net"; "proc"; "root"; "srv"; "sys" ]

let root_entries =
  { Dev.dname = "boot"; Dev.dqid = dirqid qboot; Dev.dlength = 0; Dev.dperm = 0o555 }
  :: List.map2 (fun name i -> { Dev.dname = name; Dev.dqid = dirqid (i + 1); Dev.dlength = 0; Dev.dperm = 0o555 })
       rootdirs [ 2; 3; 4; 5; 6; 7; 8; 9; 10; 11 ]

(* the boot files: their entries, their bytes' physical addresses *)
let boot_entries = ref []
let boot_data = ref []

(* the root's other directories are empty: mount points *)
let entries path =
  if path = qdir then root_entries
  else if path = qboot then !boot_entries
  else if path > qdir && path < qboot then []
  else raise (Error enotdir)

(* the root's parent the root (Dev.tab_stat: its name "/") *)
let parent path = if path > qboot then dirqid qboot else dirqid qdir

(*****************************************************************************)
(* The bootdir in the kernel's image *)
(*****************************************************************************)

(* a line at [pa] (its newline within 64 bytes): the line, the next
 * address *)
let line pa =
  let s = Machine.Phys.read pa 64 in
  let n = String.index s '\n' in
  String.sub s 0 n, pa + n + 1

let init () =
  let hdr, pa = line (Machine.fs_base ()) in
  if String.length hdr < 12 || String.sub hdr 0 12 <> "9pi bootdir " then ignore (Machine.panic "devroot: no bootdir");
  Dev.kerndate := int_of_string (String.sub hdr 12 (String.length hdr - 12));
  let rec files pa i =
    let l, data = line pa in
    if l <> "end" then begin
      let sp = String.index l ' ' in
      let name = String.sub l 0 sp and size = int_of_string (String.sub l (sp + 1) (String.length l - sp - 1)) in
      boot_entries := !boot_entries @ [ { Dev.dname = name; Dev.dqid = { path = qboot + i + 1; vers = 0; typ = Qt_file };
                                          Dev.dlength = size; Dev.dperm = 0o555 } ];
      boot_data := !boot_data @ [ qboot + i + 1, (data, size) ];
      files (data + size) (i + 1)
    end in
  files pa 1;
  let d = Dev.default '/' "root" in
  Dev.register { d with
    Dev.attach = (fun _ -> Dev.attach '/' 0 (dirqid qdir));
    Dev.walk = Dev.tab_walk entries parent;
    Dev.stat = Dev.tab_stat "/" entries parent;
    Dev.dirs = Dev.tab_dirs entries;
    Dev.open_ = Dev.tab_open;
    Dev.read = (fun c n off ->
      let pa, size = List.assoc c.qid.path !boot_data in
      if off >= size then "" else Machine.Phys.read (pa + off) (min n (size - off)));
  }
