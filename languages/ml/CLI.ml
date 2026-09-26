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

type caps = < Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr >

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

(* the assembly into the object, through mini-asm's parser *)
let gas = ref false

let output (caps : < caps; .. >) mach ~listing ~out ~file text =
  if listing then print caps text
  else if !gas then Files.write caps out (Gas.obj (Ix_asm.Parser.parse caps (Gen.arch mach) file text))
  else Ix_asm.Asm.save caps out (Ix_asm.Parser.parse caps (Gen.arch mach) file text)

let main (caps : < caps; .. >) (argv : string array) : int =
  let dast = ref false and dscope = ref false and dir = ref false and listing = ref false and start = ref false and deps = ref false in
  let show_types = ref false and unsafe = ref false in
  let mach = ref Gen.arm and out = ref "" and incs = ref [] and files = ref [] in
  let rec args = function
    | "-dast" :: rest -> dast := true; args rest
    | "-dscope" :: rest -> dscope := true; args rest
    | "-dir" :: rest -> dir := true; args rest
    | "-M" :: rest -> deps := true; args rest
    | "-i" :: rest -> show_types := true; args rest
    | "-unsafe-types" :: rest -> unsafe := true; args rest
    | "-S" :: rest -> listing := true; args rest
    | "-gas" :: rest -> gas := true; args rest
    | "-start" :: rest -> start := true; args rest
    | "-m" :: "5" :: rest -> mach := Gen.arm; args rest
    | "-m" :: "7" :: rest -> mach := Gen.arm64; args rest
    | "-o" :: o :: rest -> out := o; args rest
    | "-I" :: d :: rest -> incs := d :: !incs; args rest
    | f :: rest -> files := f :: !files; args rest
    | [] -> ()
  in
  args (List.tl (Array.to_list argv));
  if !gas then mach := Gen.gnu !mach;
  let path s = match Files.path s with Ok p -> p | Error m -> failwith m in
  let ext = match Gen.arch !mach with _ when !gas -> ".s" | Arm -> ".5" | Arm64 -> ".7" in
  let outfile file = if !out <> "" then path !out else Fpath.set_ext ext (Fpath.base file) in
  let fail m = eprint caps (m ^ "\n"); 1 in
  match List.rev !files, List.map path (List.rev !incs) with
  | units, _ when !start ->
      let file = path "start.s" in
      (match output caps !mach ~listing:!listing ~out:(outfile file) ~file (Gen.startup !mach units) with
       | () -> 0
       | exception Failure m -> fail ("mini-ml: " ^ m))
  | [ f ], incs -> (
      let file = path f in
      match parse caps file with
      | Error m -> fail m
      | Ok (`Sig items) ->
          if !dast then print caps (String.concat "\n" (List.map Ast.show_sig items) ^ "\n");
          0
      | Ok (`Str items) -> (
          if !dast then print caps (String.concat "\n" (List.map Ast.show_item items) ^ "\n");
          let name = String.capitalize_ascii (Fpath.to_string (Fpath.rem_ext (Fpath.base file))) in
          match Scope.implementation (loader caps (Fpath.parent file :: incs)) name items with
          | exception Scope.Error (l, m) -> fail (Printf.sprintf "%s:%d: %s" (Fpath.to_string file) l m)
          | items -> (
              if !dscope then print caps (String.concat "\n" (List.map Scope.show_item items) ^ "\n");
              if !deps then print caps (String.concat " " (Scope.units_named ()) ^ "\n");
              if !dast || !dscope || !deps then 0
              else
                match if !unsafe then [] else Typing.unit_ name items with
                | exception Typing.Error (l, m) -> fail (Printf.sprintf "%s:%d: %s" (Fpath.to_string file) l m)
                | types when !show_types -> List.iter (fun (x, t) -> print caps (Printf.sprintf "val %s : %s\n" x t)) types; 0
                | _ ->
                match Lower.unit_ name items with
                | exception Failure m -> fail (Printf.sprintf "%s: %s" (Fpath.to_string file) m)
                | u ->
                    if !dir then
                      List.iter (fun (fn : Lower.func) ->
                        print caps (fn.name ^ ":\n" ^ String.concat "" (List.map (fun i -> "\t" ^ Lower.show i ^ "\n") fn.code))) u.funcs;
                    match Gen.unit_ !mach u with
                    | exception Failure m -> fail (Printf.sprintf "%s: %s" (Fpath.to_string file) m)
                    | text -> if !dir then 0 else (output caps !mach ~listing:!listing ~out:(outfile file) ~file text; 0))))
  | _ -> eprint caps "usage: mini-ml [-m 5|7] [-S] [-o out] [-I dir] file.ml | -start Unit...\n"; 2
  | exception Failure m -> fail ("mini-ml: " ^ m)
