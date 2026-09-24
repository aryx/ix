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

type caps = < Store.caps; Cap.stdout; Cap.stderr; Cap.argv >

exception Fatal of string

let fatal fmt = Printf.ksprintf (fun s -> raise (Fatal s)) fmt

(*****************************************************************************)
(* The plumbing: git9's C programs *)
(*****************************************************************************)

let query (caps : caps) args =
  let fl, args = Flags.parse ~flags:"cprd" ~with_arg:"" args in
  if args = [] then raise Flags.Usage;
  let r = Repo.find (caps :> Store.caps) in
  (* the words joined, each followed by a space, as git9 does *)
  let hs = try Query.eval r.store (String.concat "" (List.map (fun a -> a ^ " ") args)) with Query.Error m -> fatal "resolve: %s" m in
  (if Flags.has fl 'c' then
     match hs with
     | h0 :: rest -> List.iter (fun h -> List.iter (fun l -> Console.print caps (l ^ "\n")) (Query.changes r.store h0 h)) rest
     | [] -> ()
   else
     let prefix = if Flags.has fl 'p' then Fpath.to_string r.root ^ "/.git/fs/object/" else "" in
     (* -r toggles, as in git9 (reverse ^= 1) *)
     let rev = List.length (List.filter (fun (c, _) -> c = 'r') fl) mod 2 = 1 in
     List.iter (fun h -> Console.print caps (prefix ^ Hash.to_hex h ^ "\n")) (if rev then List.rev hs else hs));
  0

let conf (caps : caps) args =
  let fl, args = Flags.parse ~flags:"ra" ~with_arg:"f" args in
  let r = Repo.find (caps :> Store.caps) in
  if Flags.has fl 'r' then (Console.print caps (Fpath.to_string r.root ^ "\n"); 0)
  else begin
    let files = match Flags.all fl 'f' with [] -> Conf.default_files r.root | fs -> List.map Fpath.v fs in
    List.iter (fun a -> List.iter (fun v -> Console.print caps (v ^ "\n")) (Conf.lookup caps ~all:(Flags.has fl 'a') files a)) args;
    0
  end

(*****************************************************************************)
(* Dispatch *)
(*****************************************************************************)

let commands : (string * (caps -> string list -> int) * string) list = [
  "query", query, "[-pcr] query";
  "conf", conf, "[-f file] [-r] keys..";
]

let main (caps : < caps; .. >) =
  let caps = (caps :> caps) in
  match Array.to_list (CapSys.argv caps) with
  | _ :: name :: args -> (
      match List.find_opt (fun (n, _, _) -> n = name) commands with
      | None -> Console.eprint caps (Printf.sprintf "tinygit: unknown command %s\n" name); 1
      | Some (_, f, usage) -> (
          let die m = Console.eprint caps (Printf.sprintf "git/%s: %s\n" name m); 1 in
          try f caps args with
          | Flags.Usage -> Console.eprint caps (Printf.sprintf "usage: git/%s %s\n" name usage); 1
          | Fatal m -> die m
          | Query.Error m -> die m
          | Repo.Not_a_repository -> die "not a git repository"
          | Store.Missing h -> die ("bad hash " ^ Hash.to_hex h)
          | Object.Corrupt m -> die m))
  | _ ->
      Console.eprint caps ("usage: tinygit CMD args, CMD one of: " ^ String.concat " " (List.map (fun (n, _, _) -> n) commands) ^ "\n");
      1
