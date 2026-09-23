(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* parsecheck file...: parse each rc script; print what did not parse,
 * and check the printer's law: print, read back, print again gives the
 * same text. With -recipes, the files are mkfiles and their recipes
 * (the lines starting with a tab) are read instead. *)
open Ix_rc

let read file =
  let ic = open_in_bin file in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let recipes text =
  String.split_on_char '\n' text
  |> List.filter_map (fun l -> if String.length l > 0 && l.[0] = '\t' then Some (String.sub l 1 (String.length l - 1)) else None)
  |> String.concat "\n"

let print c = Ast.to_string Ast.cmd c

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let rec_mode = List.mem "-recipes" args in
  let show = List.mem "-print" args in
  let files = List.filter (fun a -> a <> "-recipes" && a <> "-print") args in
  let ok = ref 0 and bad = ref 0 and unstable = ref 0 in
  files |> List.iter (fun f ->
    let text = read f in
    let text = if rec_mode then recipes text else text in
    match Parser.parse_string text with
    | c ->
        incr ok;
        let p1 = print c in
        if show then print_string p1;
        (match Parser.parse_string p1 with
         | c2 -> if print c2 <> p1 then (incr unstable; Printf.printf "UNSTABLE %s\n" f)
         | exception (Parser.Error m | Lexer.Error m) -> incr unstable; Printf.printf "REPRINT %s: %s\n" f m)
    | exception (Parser.Error m | Lexer.Error m) -> incr bad; Printf.printf "FAIL %s: %s\n" f m);
  Printf.printf "%d parsed, %d failed, %d not stable when printed\n" !ok !bad !unstable
