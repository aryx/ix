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

(* a machine's passes, over its opcodes *)
type 'm machine = {
  decode : string -> 'm option;
  show : 'm -> string;
  prepare : 'm Link.t -> unit;
  needs : 'm Link.prog list -> string list;
  follow : 'm Link.t -> unit;
  rewrite : 'm Link.t -> unit;
  layout : 'm Link.t -> unit;
  encode : 'm Link.t -> Bytes.t;
}

let arm = { decode = Arm.decode; show = Arm.show; prepare = Arm.prepare; needs = Arm.needs; follow = Arm.follow;
            rewrite = Arm.rewrite; layout = Arm.layout; encode = Arm.encode }
let arm64 = { decode = Arm64.decode; show = Arm64.show; prepare = Arm64.prepare; needs = (fun _ -> []); follow = Arm64.follow;
              rewrite = Arm64.rewrite; layout = Arm64.layout; encode = Arm64.encode }

type caps = < Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr >

let print = Console.print and eprint = Console.eprint

let link (m : _ machine) caps ~verbose arch format entry out files =
  let t = Link.create arch ~text_start:0 in
  let headr = Exe.headr (format, arch) in
  (* 5l's and 7l's INITTEXT: after the header *)
  t.text_start <- (match format, arch with
    | Exe.Elf, Asm.Arm -> 0x8000 + headr | Exe.Elf, Asm.Arm64 -> 0x400000 + headr
    | Exe.Plan9, Asm.Arm -> 4096 + headr | Exe.Plan9, Asm.Arm64 -> 0x10000 + headr
    | Exe.Macho, _ -> (1 lsl 32) + headr);
  t.data_round <- (match format, arch with Exe.Macho, _ -> 0x4000 | Exe.Plan9, Asm.Arm64 -> 0x10000 | _ -> 4096);
  t.pie <- format = Exe.Macho;
  (* the entry is the first name needed, before any object (5l's main) *)
  ignore (Link.lookup t entry 0);
  Link.load caps t ~decode:m.decode ~needs:m.needs files;
  m.prepare t;
  Link.resolve t;
  Link.layout_data t;
  m.follow t;
  Link.drop_nops t;
  m.rewrite t;
  m.layout t;
  let text = m.encode t in
  (* the listing, as 5l -a *)
  if verbose then
    List.iter (fun (p : _ Link.prog) ->
      let w = if p.pc >= t.text_start && p.pc + 4 <= t.text_start + t.text_size then Bytes.get_int32_le text (p.pc - t.text_start) else 0l in
      print caps @@ Printf.sprintf "%08x: %08lx\t%s\n" p.pc w (Link.show m.show p)) t.progs;
  let data = Link.data_bytes t in
  Exe.write caps format arch out
    { text; data; bss = t.bss_size; text_start = t.text_start; data_start = t.data_start; entry = Link.entry t entry;
      pointers = Link.pointers t; round = t.data_round }

let main (caps : < caps; .. >) (argv : string array) : int =
  let arch = ref Asm.Arm and format = ref Exe.Elf and entry = ref "_main" and out = ref "a.out"
  and lib = ref "" and files = ref [] and verbose = ref false in
  let rec args = function
    | "-m" :: "5" :: rest -> arch := Asm.Arm; args rest
    | "-m" :: "7" :: rest -> arch := Asm.Arm64; args rest
    | "-H7" :: rest -> format := Exe.Elf; args rest
    | "-H2" :: rest -> format := Exe.Plan9; args rest
    | "-H6" :: rest -> format := Exe.Macho; args rest
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
  | [] -> eprint caps "usage: tinyld -m 5|7 [-H2|-H6|-H7] [-E entry] [-o out] files... | -a lib.a objects...\n"; 1
  | _ -> (
      try
        let path s = match Files.path s with Ok p -> p | Error m -> failwith m in
        let files = List.map path files and out = path !out in
        if !lib <> "" then Link.make_library caps (path !lib) files
        else (match !arch with
          | Asm.Arm -> link arm caps ~verbose:!verbose !arch !format !entry out files
          | Asm.Arm64 -> link arm64 caps ~verbose:!verbose !arch !format !entry out files);
        0
      with Link.Error m | Sys_error m | Failure m -> eprint caps ("tinyld: " ^ m ^ "\n"); 1)
