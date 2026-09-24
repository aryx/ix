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
