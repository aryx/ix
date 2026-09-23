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

let main (argv : string array) : int =
  let arch = ref Asm.Arm and out = ref "" and files = ref [] in
  let rec args = function
    | "-m" :: "5" :: rest -> arch := Asm.Arm; args rest
    | "-m" :: "7" :: rest -> arch := Asm.Arm64; args rest
    | "-o" :: o :: rest -> out := o; args rest
    | f :: rest -> files := f :: !files; args rest
    | [] -> ()
  in
  args (List.tl (Array.to_list argv));
  match !files with
  | [ file ] -> (
      let text = In_channel.with_open_bin file In_channel.input_all in
      match Parser.parse !arch file text with
      | obj ->
          let ext = match !arch with Asm.Arm -> ".5" | Asm.Arm64 -> ".7" in
          let out = if !out <> "" then !out else Filename.remove_extension (Filename.basename file) ^ ext in
          Asm.save out obj;
          0
      | exception Parser.Error (l, m) -> Printf.eprintf "%s:%d: %s\n" file l m; 1)
  | _ -> prerr_endline "usage: tinyasm -m 5|7 [-o out] file.s"; 1
