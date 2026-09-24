(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Conf.mli *)

let show caps ~all file sect key =
  match Files.read_opt caps file with
  | None -> []
  | Some s ->
      let found = ref [] and foundsect = ref (sect = None) and stop = ref false in
      List.iter (fun ln ->
        let p = String.trim ln in
        if not !stop then
          if String.length p > 0 && p.[0] = '[' && sect <> None then
            foundsect := String.starts_with ~prefix:(Option.get sect) ln
          else if !foundsect && String.starts_with ~prefix:key p then begin
            let rest = String.trim (String.sub p (String.length key) (String.length p - String.length key)) in
            if String.length rest > 0 && rest.[0] = '=' then begin
              found := String.trim (String.sub rest 1 (String.length rest - 1)) :: !found;
              if not all then stop := true
            end
          end) (String.split_on_char '\n' s);
      List.rev !found

let lookup caps ?(all = false) files arg =
  (* sect.key: split at the first dot *)
  let sect, key = match String.index_opt arg '.' with
    | None -> None, arg
    | Some i -> Some ("[" ^ String.sub arg 0 i ^ "]"), String.sub arg (i + 1) (String.length arg - i - 1) in
  let rec first = function [] -> [] | f :: rest -> (match show caps ~all f sect key with [] -> first rest | vs -> vs) in
  first files

let default_files root =
  [ Fpath.(root / ".git" / "config") ]
  @ (match Sys.getenv_opt "HOME" with Some h -> [ Fpath.(v h / "lib" / "git" / "config") ] | None -> [])
  @ [ Fpath.v "/lib/git/config" ]
