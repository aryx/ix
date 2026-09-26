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

type caps = < Cap.open_in; Cap.stdout; Cap.stderr >

let print = Console.print and eprint = Console.eprint

(* a file's tree: an interface for a .mli, else an implementation *)
let parse (caps : < caps; .. >) file =
  match Files.read_opt caps file with
  | None -> Error (Printf.sprintf "cannot open %s" (Fpath.to_string file))
  | Some text -> (
      let lexbuf = Lexing.from_string text in
      let where () = Printf.sprintf "%s:%d" (Fpath.to_string file) lexbuf.Lexing.lex_curr_p.pos_lnum in
      try
        if Fpath.has_ext ".mli" file then Ok (`Sig (Parser.interface Lexer.token lexbuf))
        else Ok (`Str (Parser.implementation Lexer.token lexbuf))
      with
      | Parsing.Parse_error -> Error (where () ^ ": syntax error")
      | Lexer.Error m -> Error (where () ^ ": " ^ m))

let main (caps : < caps; .. >) (argv : string array) : int =
  let dast = ref false and files = ref [] in
  let rec args = function
    | "-dast" :: rest -> dast := true; args rest
    | f :: rest -> files := f :: !files; args rest
    | [] -> ()
  in
  args (List.tl (Array.to_list argv));
  match List.rev !files with
  | [ f ] -> (
      match Files.path f with
      | Error m -> eprint caps ("mini-ml: " ^ m ^ "\n"); 1
      | Ok file -> (
          match parse caps file with
          | Error m -> eprint caps (m ^ "\n"); 1
          | Ok tree ->
              if !dast then
                print caps
                  (match tree with
                   | `Str items -> String.concat "\n" (List.map Ast.show_item items) ^ "\n"
                   | `Sig items -> String.concat "\n" (List.map Ast.show_sig items) ^ "\n");
              0))
  | _ -> eprint caps "usage: mini-ml [-dast] file.ml\n"; 2
