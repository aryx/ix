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

(* another unit's source, by module name: its .mli, else its .ml, in
 * the directories in order, its file's name lowercase or not *)
let loader (caps : < caps; .. >) dirs : Scope.loader =
 fun name ->
  let names = List.concat_map (fun ext -> [ String.uncapitalize_ascii name ^ ext; name ^ ext ]) [ ".mli"; ".ml" ] in
  let candidates = List.concat_map (fun d -> List.map (fun n -> Fpath.(d / n)) names) dirs in
  match List.find_opt (fun f -> Files.read_opt caps f <> None) candidates with
  | None -> None
  | Some f -> (
      match parse caps f with
      | Ok (`Sig s) -> Some (`Sig s)
      | Ok (`Str s) -> Some (`Str s)
      | Error m -> raise (Scope.Error (0, m)))

let main (caps : < caps; .. >) (argv : string array) : int =
  let dast = ref false and dscope = ref false and incs = ref [] and files = ref [] in
  let rec args = function
    | "-dast" :: rest -> dast := true; args rest
    | "-dscope" :: rest -> dscope := true; args rest
    | "-I" :: d :: rest -> incs := d :: !incs; args rest
    | f :: rest -> files := f :: !files; args rest
    | [] -> ()
  in
  args (List.tl (Array.to_list argv));
  let path s = match Files.path s with Ok p -> p | Error m -> failwith m in
  match List.map path (List.rev !files), List.map path (List.rev !incs) with
  | [ file ], incs -> (
      match parse caps file with
      | Error m -> eprint caps (m ^ "\n"); 1
      | Ok (`Sig items) ->
          if !dast then print caps (String.concat "\n" (List.map Ast.show_sig items) ^ "\n");
          0
      | Ok (`Str items) -> (
          if !dast then print caps (String.concat "\n" (List.map Ast.show_item items) ^ "\n");
          let name = String.capitalize_ascii (Fpath.to_string (Fpath.rem_ext (Fpath.base file))) in
          match Scope.implementation (loader caps (Fpath.parent file :: incs)) name items with
          | items ->
              if !dscope then print caps (String.concat "\n" (List.map Scope.show_item items) ^ "\n");
              0
          | exception Scope.Error (l, m) -> eprint caps (Printf.sprintf "%s:%d: %s\n" (Fpath.to_string file) l m); 1))
  | _ -> eprint caps "usage: mini-ml [-dast] [-dscope] [-I dir] file.ml\n"; 2
  | exception Failure m -> eprint caps ("mini-ml: " ^ m ^ "\n"); 1
