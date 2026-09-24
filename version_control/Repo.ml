(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Repo.mli *)

type t = { root : Fpath.t; rel : int; cwd : string; store : Store.t }

exception Not_a_repository

let at caps root = { root; rel = 0; cwd = ""; store = Store.open_git caps Fpath.(root / ".git") }

let find caps =
  let rec up dir rel below =
    if Sys.file_exists (Filename.concat dir ".git/HEAD") then
      { root = Fpath.v dir; rel; cwd = String.concat "/" below; store = Store.open_git caps (Fpath.v (Filename.concat dir ".git")) }
    else if dir = "/" then raise Not_a_repository
    else up (Filename.dirname dir) (rel + 1) (Filename.basename dir :: below)
  in
  up (Sys.getcwd ()) 0 []

let cleanname path =
  let abs = String.length path > 0 && path.[0] = '/' in
  let parts = List.filter (fun p -> p <> "" && p <> ".") (String.split_on_char '/' path) in
  let rev = List.fold_left (fun acc p ->
    match p, acc with
    | "..", x :: rest when x <> ".." -> rest
    | "..", [] when abs -> []
    | p, acc -> p :: acc) [] parts in
  let s = String.concat "/" (List.rev rev) in
  if abs then "/" ^ s else if s = "" then "." else s

let relative t arg =
  let root = Fpath.to_string t.root in
  if String.length arg > 0 && arg.[0] = '/' then
    if String.starts_with ~prefix:root arg then Some (cleanname ("./" ^ String.sub arg (String.length root) (String.length arg - String.length root)))
    else None
  else
    let p = cleanname ("./" ^ t.cwd ^ "/" ^ arg) in
    if p = ".." || String.starts_with ~prefix:"../" p then None else Some p
