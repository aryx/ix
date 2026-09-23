(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See CLI.mli *)

let link ~verbose arch format entry out files =
  let t = Link.create arch ~text_start:0 in
  let headr = Exe.headr (format, arch) in
  (* 5l's INITTEXT: after the header, in the page Linux's arm expects *)
  t.text_start <- (match format with Exe.Elf -> 0x8000 + headr | Exe.Plan9 -> 4096 + headr);
  (* the entry is the first name needed, before any object (5l's main) *)
  ignore (Link.lookup t entry 0);
  Link.load t ~needs:Arm.needs files;
  Arm.prepare t;
  Link.resolve t;
  Link.layout_data t;
  Arm.follow t;
  Arm.rewrite t;
  Arm.layout t;
  let text = Arm.encode t in
  (* the listing, as 5l -a *)
  if verbose then
    List.iter (fun (p : Link.prog) ->
      let w = if p.pc >= t.text_start && p.pc + 4 <= t.text_start + t.text_size then Bytes.get_int32_le text (p.pc - t.text_start) else 0l in
      Printf.printf "%08x: %08lx\t%s\n" p.pc w (Asm.show_item (Ins { op = p.op; suffixes = p.suffixes; args = p.args }))) t.progs;
  let data = Link.data_bytes t in
  Exe.write format arch out
    { text; data; bss = t.bss_size; text_start = t.text_start; data_start = t.data_start; entry = Link.entry t entry }

let main (argv : string array) : int =
  let arch = ref Asm.Arm and format = ref Exe.Elf and entry = ref "_main" and out = ref "a.out"
  and lib = ref "" and files = ref [] and verbose = ref false in
  let rec args = function
    | "-m" :: "5" :: rest -> arch := Asm.Arm; args rest
    | "-m" :: "7" :: rest -> arch := Asm.Arm64; args rest
    | "-H7" :: rest -> format := Exe.Elf; args rest
    | "-H2" :: rest -> format := Exe.Plan9; args rest
    | "-E" :: e :: rest -> entry := e; args rest
    | "-o" :: o :: rest -> out := o; args rest
    | "-a" :: l :: rest -> lib := l; args rest
    | "-s" :: rest -> args rest
    | "-v" :: rest -> verbose := true; args rest
    | f :: rest -> files := f :: !files; args rest
    | [] -> ()
  in
  args (List.tl (Array.to_list argv));
  let files = List.rev !files in
  match files with
  | [] -> prerr_endline "usage: tinyld -m 5|7 [-H2|-H7] [-E entry] [-o out] files... | -a lib.a objects..."; 1
  | _ -> (
      try
        if !lib <> "" then Link.make_library !lib files
        else if !arch = Asm.Arm64 then Link.error "arm64: not yet"
        else link ~verbose:!verbose !arch !format !entry !out files;
        0
      with Link.Error m -> prerr_endline ("tinyld: " ^ m); 1)
