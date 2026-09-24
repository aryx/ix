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

let log (caps : caps) args =
  let fl, args = Flags.parse ~flags:"s" ~with_arg:"cne" args in
  let r = Repo.find (caps :> Store.caps) in
  let filter = if args = [] then None else Some (Log.filter (List.filter_map (Repo.relative r) args)) in
  let count = ref (match Flags.get fl 'n' with Some n -> (match int_of_string_opt n with Some n -> n | None -> 0) | None -> -1) in
  let short = Flags.has fl 's' in
  let show h c =
    if Log.matches r.store filter c then begin
      Console.print caps (Log.show ~short h c);
      if !count <> -1 then decr count
    end in
  let commit h = match Store.read r.store h with Commit c -> c | _ -> fatal "%s: not a commit" (Hash.to_hex h) in
  (match Flags.get fl 'e' with
   | Some q ->
       let hs = try Query.eval r.store q with Query.Error m -> fatal "resolve: %s" m in
       List.iter (fun h -> if !count <> 0 then show h (commit h)) hs
   | None ->
       let c = Option.value (Flags.get fl 'c') ~default:"HEAD" in
       let h = try Query.eval1 r.store c with Query.Error m -> fatal "resolve %s: %s" c m in
       ignore (commit h);
       let rec go s = if !count <> 0 then match s () with Seq.Nil -> () | Seq.Cons ((h, c), rest) -> show h c; go rest in
       go (Query.history r.store h));
  0

(* git/fs's paths, read without a mount: a file's bytes, a directory's
 * names (a directory's with a trailing /, as ls -F) *)
let fs (caps : caps) args =
  let r = Repo.find (caps :> Store.caps) in
  let status = ref 0 in
  List.iter (fun p ->
    match Fs.resolve r p with
    | Some (File s) -> Console.print caps s
    | Some (Dir names) ->
        List.iter (fun n ->
          let slash = match Fs.resolve r (p ^ "/" ^ n) with Some (Dir _) -> "/" | _ -> "" in
          Console.print caps (n ^ slash ^ "\n")) names
    | None -> Console.eprint caps (Printf.sprintf "git/fs: %s: file does not exist\n" p); status := 1) args;
  !status

(*****************************************************************************)
(* Dispatch *)
(*****************************************************************************)

let commands : (string * (caps -> string list -> int) * string) list = [
  "query", query, "[-pcr] query";
  "init", (fun c -> Commands.init (c :> Commands.caps)), "[-u upstream] [-b branch] name";
  "add", (fun c -> Commands.add (c :> Commands.caps)), "[-r] file ...";
  "rm", (fun c -> Commands.rm (c :> Commands.caps)), "file ...";
  "walk", (fun c -> Commands.walk (c :> Commands.caps)), "[-qbcI] [-f filt] [-b base] [paths...]";
  "save", (fun c -> Commands.save (c :> Commands.caps)), "-n name -e email -m message -d date [files...]";
  "commit", (fun c -> Commands.commit (c :> Commands.caps)), "[-re] [-m msg] [file ...]";
  "branch", (fun c -> Commands.branch (c :> Commands.caps)), "[-abrnsmM] [branch]";
  "revert", (fun c -> Commands.revert (c :> Commands.caps)), "[-c query] file ...";
  "diff", (fun c -> Commands.diff (c :> Commands.caps)), "[-c branch] [-su] [file ...]";
  "conf", conf, "[-f file] [-r] keys..";
  "fs", fs, "path ...";
  "log", log, "[-s] [-e expr | -c commit] files..";
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
          | Object.Corrupt m -> die m
          | Commands.Die m -> die m))
  | _ ->
      Console.eprint caps ("usage: tinygit CMD args, CMD one of: " ^ String.concat " " (List.map (fun (n, _, _) -> n) commands) ^ "\n");
      1
