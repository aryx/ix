(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Commands.mli *)

type caps = < Store.caps; Cap.stdout; Cap.stderr >

exception Die of string

let die fmt = Printf.ksprintf (fun s -> raise (Die s)) fmt

let print caps s = Console.print caps s
let eprint caps s = Console.eprint caps s

let store_caps (caps : caps) = (caps :> Store.caps)

(* the scripts cd to the root (gitup); their paths are then relative to
 * it: cleanname -d $gitrel $* *)
let rel_paths (r : Repo.t) args = List.filter_map (Repo.relative r) args

let exists r p = Sys.file_exists (Filename.concat (Fpath.to_string r.Repo.root) p)
let full r p = Filename.concat (Fpath.to_string r.Repo.root) p

(* mkdir -p, which Plan 9's leaves alone when the path exists, even as
 * a file *)
let rec mkdir_p d =
  if d <> "" && d <> "." && d <> "/" && not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    try Unix.mkdir d 0o755 with Unix.Unix_error _ -> ()
  end

let rec rm_rf p =
  match Unix.lstat p with
  | { st_kind = S_DIR; _ } -> Array.iter (fun f -> rm_rf (Filename.concat p f)) (Sys.readdir p); Unix.rmdir p
  | _ -> Sys.remove p
  | exception Unix.Unix_error _ -> ()

(* Plan 9's walk -f: the files under the paths, recursively *)
let rec walk_files root path =
  let p = if path = "." then root else Filename.concat root path in
  match Unix.stat p with
  | { st_kind = S_DIR; _ } ->
      Sys.readdir p |> Array.to_list |> List.sort compare
      |> List.concat_map (fun f -> walk_files root (if path = "." then f else path ^ "/" ^ f))
  | _ -> [ path ]
  | exception Unix.Unix_error _ -> []

let walk_run r opts = try Walk.run r opts with Walk.Error m -> die "%s" m

(*****************************************************************************)
(* init, add, rm *)
(*****************************************************************************)

let init (caps : caps) args =
  let fl, args = try Flags.parse ~flags:"" ~with_arg:"ub" args with Flags.Usage -> die "usage: git/init [-u upstream] [-b branch] name" in
  let dir = match args with d :: _ -> d | [] -> "." in
  let branch = Option.value (Flags.get fl 'b') ~default:"master" in
  let git = Filename.concat dir ".git" in
  if Sys.file_exists git then die "%s already exists" git;
  let name = Filename.basename (Repo.cleanname (if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir)) in
  let upstream = match Flags.get fl 'u' with
    | Some u -> Some u
    | None ->
        let home = match Sys.getenv_opt "HOME" with Some h -> [ Fpath.(v h / "lib" / "git" / "config") ] | None -> [] in
        (match Conf.lookup caps (home @ [ Fpath.v "/lib/git/config" ]) "defaults \"origin\".baseurl" with
         | u :: _ -> Some (u ^ "/" ^ name)
         | [] -> None) in
  List.iter (fun d -> mkdir_p (Filename.concat git d)) [ "refs/heads"; "refs/remotes"; "fs"; "objects" ];
  (* claude: repositoryformatversion 0, not git9's p9.0, which C git
   * refuses (plan_vcs.md, deliberate difference 1) *)
  let config =
    "[core]\n\trepositoryformatversion = 0\n"
    ^ (match upstream with Some u -> "[remote \"origin\"]\n\turl = " ^ u ^ "\n" | None -> "")
    ^ "[branch \"" ^ branch ^ "\"]\n\tremote = origin\n" in
  Files.write caps (Fpath.v (Filename.concat git "config")) config;
  Files.write caps (Fpath.v (Filename.concat git "INDEX9")) "";
  Files.write caps (Fpath.v (Filename.concat git "HEAD")) ("ref: refs/heads/" ^ branch ^ "\n");
  0

let add_as state (caps : caps) args =
  let fl, args = try Flags.parse ~flags:"r" ~with_arg:"" args with Flags.Usage -> die "usage: git/add [-r] file ..." in
  if args = [] then die "usage: git/add [-r] file ...";
  let state = if Flags.has fl 'r' then Index9.Removed else state in
  let r = Repo.find (store_caps caps) in
  let root = Fpath.to_string r.root in
  let files = List.concat_map (fun p ->
    let fs = walk_files root p in
    if fs = [] then eprint caps (Printf.sprintf "walk: %s: does not exist\n" p);
    fs) (rel_paths r args) in
  let files = List.filter (fun f -> not (f = ".git" || String.starts_with ~prefix:".git/" f)) files in
  Index9.append caps r.store.git (List.map (fun f -> state, f) files);
  0

let add caps args = add_as Index9.Added caps args
let rm caps args = add_as Index9.Removed caps ("-r" :: args)

(*****************************************************************************)
(* walk and save, the plumbing *)
(*****************************************************************************)

let walk (caps : caps) args =
  let fl, args = try Flags.parse ~flags:"qcI" ~with_arg:"fbr" args with Flags.Usage -> die "usage: git/walk [-qbcI] [-f filt] [-b base] [paths...]" in
  let r = Repo.find (store_caps caps) in
  let show = match Flags.get fl 'f' with
    | None -> []
    | Some f -> List.map (function 'T' -> Walk.Tracked | 'A' -> Added | 'M' -> Modified | 'R' -> Removed | 'U' -> Untracked
                                    | _ -> die "usage: git/walk [-qbcI] [-f filt] [-b base] [paths...]") (List.of_seq (String.to_seq f)) in
  let base = Option.map (fun b -> try Query.eval1 r.store b with Query.Error _ -> die "no such ref '%s'" b) (Flags.get fl 'b') in
  let paths = List.map (fun a -> match Repo.relative r a with Some p -> p | None -> die "path outside repo: %s" a) args in
  let lines, dirty = walk_run r { show; quiet = Flags.has fl 'q'; bare = Flags.has fl 'c'; base; invalidate = Flags.has fl 'I'; rel = Flags.get fl 'r'; paths } in
  List.iter (fun l -> print caps (l ^ "\n")) lines;
  if dirty = [] then 0 else 1

(* GIT_AUTHOR_DATE, as C git reads it ("SECONDS" or "SECONDS +ZONE"):
 * the tests' way to fix the date (plan_vcs.md, deliberate difference 5) *)
let now () =
  match Sys.getenv_opt "GIT_AUTHOR_DATE" with
  | Some d -> (match int_of_string_opt (List.hd (String.split_on_char ' ' (String.trim d))) with Some n -> n | None -> int_of_float (Unix.time ()))
  | None -> int_of_float (Unix.time ())

let save (caps : caps) args =
  let fl, args = try Flags.parse ~flags:"" ~with_arg:"mneNEpd" args with Flags.Usage -> die "usage: git/save -n name -e email -m message -d date [files...]" in
  let r = Repo.find (store_caps caps) in
  let get c what = match Flags.get fl c with Some v -> v | None -> die "missing %s" what in
  let msg = get 'm' "message" and name = get 'n' "name" and email = get 'e' "email" in
  let committer = match Flags.get fl 'N', Flags.get fl 'E' with
    | Some n, Some e -> { Save.name = n; email = e }
    | None, None -> { name; email }
    | _ -> die "partially specified committer" in
  let date = match Flags.get fl 'd' with
    | Some d -> (match int_of_string_opt d with Some n -> n | None -> die "could not parse date %s" d)
    | None -> now () in
  let parents = List.map (fun p -> try Query.eval1 r.store p with Query.Error m -> die "invalid parent: %s" m) (Flags.all fl 'p') in
  let h = try Save.save r { author = { name; email }; committer; msg; date; parents } (rel_paths r args) with Save.Error m -> die "%s" m in
  print caps (Hash.to_hex h ^ "\n");
  0

(*****************************************************************************)
(* commit *)
(*****************************************************************************)

let cleanmsg s =
  let blank l = String.trim l = "" in
  let comment l = let t = String.trim l in String.length t > 0 && t.[0] = '#' in
  let rstrip l = let n = ref (String.length l) in while !n > 0 && (l.[!n - 1] = ' ' || l.[!n - 1] = '\t') do decr n done; String.sub l 0 !n in
  let lines = String.split_on_char '\n' s in
  let lines = if s <> "" && s.[String.length s - 1] = '\n' then List.rev (List.tl (List.rev lines)) else lines in
  let b = Buffer.create 256 in
  let wet = ref false and empty = ref false in
  List.iter (fun l ->
    if comment l then ()
    else if blank l then empty := true
    else begin
      if !wet && !empty then Buffer.add_char b '\n';
      wet := true; empty := false;
      Buffer.add_string b (rstrip l);
      Buffer.add_char b '\n'
    end) lines;
  Buffer.contents b

let whoami caps (r : Repo.t) =
  let conf k = match Conf.lookup caps (Conf.default_files r.root) k with v :: _ -> v | [] -> "" in
  let user = Option.value (Sys.getenv_opt "USER") ~default:"none" in
  let name = match conf "user.name" with "" -> user | n -> n in
  let email = match conf "user.email" with "" -> user ^ "@" ^ Unix.gethostname () | e -> e in
  { Save.name; email }

(* git/branch with no argument: ctl's branch, "heads/master" or a hash *)
let current_branch (r : Repo.t) =
  match Fs.resolve r "ctl" with
  | Some (File s) -> (match String.split_on_char '\n' s with l :: _ -> String.sub l 7 (String.length l - 7) | [] -> "")
  | _ -> die "unable to read repo"

let merge_parents (r : Repo.t) =
  match Files.read_opt r.store.caps Fpath.(r.store.git / "merge-parents") with
  | None -> None
  | Some s -> Some (List.filter (fun l -> l <> "") (String.split_on_char '\n' s))

let commit (caps : caps) args =
  let r = Repo.find (store_caps caps) in
  let fl, args = try Flags.parse ~flags:"rep" ~with_arg:"m" args with Flags.Usage -> die "usage: git/commit [-re] [-m msg] [file ...]" in
  if Flags.has fl 'p' then die "-p: partial commits are not supported";
  let revise = Flags.has fl 'r' in
  let msg = ref (Option.map (fun m -> m ^ "\n") (Flags.get fl 'm')) in
  if !msg = None && revise then begin
    print caps (Printf.sprintf "revising commit %s" (match Fs.resolve r "HEAD/hash" with Some (File h) -> h | _ -> "\n"));
    msg := (match Fs.resolve r "HEAD/msg" with Some (File m) -> Some m | _ -> Some "")
  end;
  let merging = merge_parents r in
  let files = match merging with
    | Some (p0 :: ps) ->
        let hs = List.map (fun p -> try Query.eval1 r.store p with Query.Error m -> die "%s" m) (p0 :: ps) in
        List.concat_map (fun h -> List.map (fun l -> String.sub l 2 (String.length l - 2)) (Query.changes r.store (List.hd hs) h)) (List.tl hs)
    | _ -> [] in
  let files, clean =
    if args = [] then files, false
    else
      let lines, dirty = walk_run r { Walk.default with show = [ Removed; Modified; Added ]; bare = true; paths = rel_paths r args } in
      files @ lines, dirty = [] in
  if (clean || files = []) && merging = None && not revise then die "nothing to commit";
  let who = whoami caps r in
  let branch = current_branch r in
  let has_tree p = match Fs.resolve r p with Some (Dir _) -> true | _ -> false in
  let refpath, initial =
    if has_tree ("branch/" ^ branch ^ "/tree") then "refs/" ^ branch, false
    else if has_tree ("object/" ^ branch ^ "/tree") then "HEAD", false
    else if not (has_tree "HEAD/tree") then "refs/" ^ branch, true
    else die "invalid branch: %s" branch in
  let parents =
    if revise then (match Fs.resolve r "HEAD/parent" with Some (File s) -> List.filter (( <> ) "") (String.split_on_char '\n' s) | _ -> [])
    else match merging with
      | Some ps -> List.sort_uniq compare ps
      | None -> if initial then [] else [ Hash.to_hex (try Query.eval1 r.store branch with Query.Error m -> die "%s" m) ] in
  (* editmsg: the template, the editor, cleanmsg *)
  let edit = Flags.has fl 'e' || !msg = None in
  let text =
    match !msg with
    | Some m when not edit -> m
    | m ->
        let template = match m with
          | Some m -> m
          | None ->
              let walked, _ = walk_run r { Walk.default with show = [ Added; Modified; Removed ]; paths = files } in
              String.concat "" ([ Printf.sprintf "# Author: %s <%s>\n#\n" who.name who.email ]
                                @ List.map (fun p -> "# parent: " ^ p ^ "\n") parents
                                @ List.map (fun l -> "# " ^ l ^ "\n") walked @ [ "#\n# Commit message:\n" ]) in
        let editor = match Sys.getenv_opt "EDITOR" with
          | Some e when e <> "" -> e
          | _ -> (match Conf.lookup caps (Conf.default_files r.root) "core.editor" with e :: _ -> e | [] -> die "could not commit: no editor") in
        let tmp = Filename.temp_file "git-msg" "" in
        Out_channel.with_open_bin tmp (fun oc -> output_string oc template);
        if Sys.command (Filename.quote_command editor [ tmp ]) <> 0 then die "could not commit: editor failed";
        let s = In_channel.with_open_bin tmp In_channel.input_all in
        Sys.remove tmp;
        s in
  let text = cleanmsg text in
  if text = "" then die "empty commit message";
  let date = now () in
  let parents = List.map (fun p -> try Query.eval1 r.store p with Query.Error m -> die "invalid parent: %s" m) parents in
  let hash = try Save.save r { author = who; committer = who; msg = text; date; parents } files with Save.Error m -> die "could not commit: %s" m in
  (* update *)
  (try Sys.remove (Fpath.to_string Fpath.(r.store.git / "merge-parents")) with Sys_error _ -> ());
  print caps (Printf.sprintf "%s: %s\n" branch (Hash.to_hex hash));
  Refs.write r.store refpath hash;
  Index9.append caps r.store.git (List.map (fun f -> (if exists r f then Index9.Tracked else Index9.Removed), f) files);
  0

(*****************************************************************************)
(* branch, revert *)
(*****************************************************************************)

(* a file of a commit's tree, written to the work tree (cp -x from
 * git/fs: the x bit kept) *)
let checkout_file (r : Repo.t) commit path =
  match Store.read r.store commit with
  | Commit c -> (
      match Walk.lookup r.store c.tree path with
      | Some (File e) -> (
          match Store.read r.store e.hash with
          | Blob data ->
              let p = full r path in
              mkdir_p (Filename.dirname p);
              (try Sys.remove p with Sys_error _ -> ());
              Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] (if e.mode = Exec then 0o755 else 0o644) p
                (fun oc -> output_string oc data);
              true
          | _ -> false)
      | _ -> false)
  | _ -> false

let is_file (r : Repo.t) commit path =
  match Store.read r.store commit with
  | Commit c -> (match Walk.lookup r.store c.tree path with Some (File _) -> true | _ -> false)
  | _ -> false

let merge1_hook : (caps -> Repo.t -> string -> Hash.t -> Hash.t -> Hash.t -> string option) ref =
  ref (fun _ _ _ _ _ _ -> Some "merge: not available")

exception Stop of int

let branch (caps : caps) args =
  let r = Repo.find (store_caps caps) in
  let usage () = die "usage: git/branch [-abrnsmM] [branch]" in
  let fl, args = try Flags.parse ~flags:"arnsmM" ~with_arg:"b" args with Flags.Usage -> usage () in
  match args with
  | [] ->
      if Flags.has fl 'a' then
        Refs.list r.store
        |> List.filter (fun (n, _) -> String.starts_with ~prefix:"heads/" n || String.starts_with ~prefix:"remotes/" n)
        |> List.iter (fun (n, _) -> print caps (n ^ "\n"))
      else print caps (current_branch r ^ "\n");
      0
  | [ br ] -> (
      (* a failed git/query: its message, and exit 'bad ref' *)
      let q e = try Hash.to_hex (Query.eval1 r.store e) with Query.Error m -> eprint caps ("git/query: resolve: " ^ m ^ "\n"); raise (Stop 1) in
      try
        let new_ =
          if String.starts_with ~prefix:"refs/heads/" br then br
          else if String.starts_with ~prefix:"heads/" br then "refs/" ^ br
          else "refs/heads/" ^ br in
        let orig = q "HEAD" in
        let origbranch = "refs/" ^ current_branch r in
        let newbr = Flags.has fl 'n' in
        let baseref = ref (Flags.get fl 'b') in
        (* switching to a branch we lack but origin has: mirror it *)
        if not newbr then begin
          if !baseref <> None then die "update would clobber %s with %s" br (Option.get !baseref);
          if not (Sys.file_exists (Filename.concat (Fpath.to_string r.store.git) new_)) then begin
            let remote = "refs/remotes/origin/" ^ String.sub new_ 11 (String.length new_ - 11) in
            ignore (q remote);
            baseref := Some remote
          end
        end;
        let base = match !baseref with Some b -> q b | None -> if not newbr then q new_ else q "HEAD" in
        let changes = Query.changes r.store (Hash.of_hex orig) (Hash.of_hex base) in
        (* "- dir/" names a directory: Plan 9 ignores the slash *)
        let strip l = Repo.cleanname (String.sub l 2 (String.length l - 2)) in
        let modified = List.filter_map (fun l -> if l.[0] <> '-' then Some (strip l) else None) changes in
        let deleted = List.filter_map (fun l -> if l.[0] = '-' then Some (strip l) else None) changes in
        let remove = Flags.has fl 'r' in
        if remove && origbranch = new_ then die "cannot remove current branch";
        (* not merging: existing changes are not clobbered *)
        if (not (Flags.has fl 'm')) && (not remove) && (modified <> [] || deleted <> []) then begin
          let _, dirty = walk_run r { Walk.default with show = [ Removed; Modified; Added ]; paths = modified @ deleted } in
          if dirty <> [] then die "uncommitted changes would be clobbered"
        end;
        if remove then begin
          (try Sys.remove (Filename.concat (Fpath.to_string r.store.git) new_) with Sys_error _ -> ());
          print caps ("removed branch " ^ new_ ^ "\n");
          raise (Stop 0)
        end;
        let commit = Hash.of_hex base in
        let dirtypaths =
          if modified = [] && deleted = [] then []
          else fst (walk_run r { Walk.default with show = [ Removed; Modified; Added ]; bare = true; paths = modified @ deleted }) in
        let lines = ref [] and failed = ref false in
        List.iter (fun d ->
          if not (Sys.file_exists (full r d) && Sys.is_directory (full r d)) then begin
            rm_rf (full r d); lines := (Index9.Removed, d) :: !lines end) deleted;
        (* a change can turn a file into a directory or back: delete,
         * then copy *)
        List.iter (fun m ->
          if not (List.mem m dirtypaths) then begin
            mkdir_p (Filename.dirname (full r m));
            let a_file = Sys.file_exists (full r m) && not (Sys.is_directory (full r m)) in
            let b_file = is_file r commit m in
            if a_file <> b_file then begin rm_rf (full r m); lines := (Index9.Removed, m) :: !lines end;
            if b_file then begin
              lines := (Index9.Tracked, m) :: !lines;
              if not (checkout_file r commit m) then (print caps ("cp failed: " ^ m ^ "\n"); failed := true)
            end
          end) (modified @ deleted);
        Index9.append caps r.store.git (List.rev !lines);
        List.iter (fun ours ->
          match !merge1_hook caps r ours (Hash.of_hex orig) (Hash.of_hex orig) commit with
          | None -> ()
          | Some st -> eprint caps (Printf.sprintf "merge failed %s: %s\n" ours st)) dirtypaths;
        Refs.write r.store new_ commit;
        if Flags.has fl 's' then raise (Stop 0);
        if !failed then (eprint caps "pull failed: fix errors and try again\n"; raise (Stop 1));
        Refs.write_symbolic r.store "HEAD" new_;
        print caps (Printf.sprintf "%s: %s\n" new_ (q new_));
        0
      with Stop n -> n)
  | _ -> usage ()

let revert (caps : caps) args =
  let r = Repo.find (store_caps caps) in
  let fl, args = try Flags.parse ~flags:"" ~with_arg:"c" args with Flags.Usage -> die "usage: git/revert [-c query] file ..." in
  if args = [] then die "usage: git/revert [-c query] file ...";
  let query = Option.value (Flags.get fl 'c') ~default:"HEAD" in
  let commit = try Query.eval1 r.store query with Query.Error m -> die "%s" m in
  let files, _ = walk_run r { Walk.default with show = [ Removed; Modified ]; bare = true; base = Some commit; paths = rel_paths r args } in
  List.iter (fun f -> if checkout_file r commit f then Index9.append caps r.store.git [ Index9.Added, f ]) files;
  0

(*****************************************************************************)
(* diff *)
(*****************************************************************************)

let diff_hook : (caps -> Repo.t -> Hash.t -> string list -> unit) ref = ref (fun _ _ _ _ -> die "diff: not available")

let diff (caps : caps) args =
  let r = Repo.find (store_caps caps) in
  let fl, args = try Flags.parse ~flags:"su" ~with_arg:"c" args with Flags.Usage -> die "usage: git/diff [-c branch] [-su] [file ...]" in
  let base = Option.map (fun c -> try Query.eval1 r.store c with Query.Error m -> die "%s" m) (Flags.get fl 'c') in
  let show = if Flags.has fl 'u' then [ Walk.Modified; Added; Removed; Untracked ] else [ Modified; Added; Removed ] in
  let files = rel_paths r args in
  if Flags.has fl 's' || Flags.has fl 'u' then begin
    let lines, _ = walk_run r { Walk.default with show; base; rel = Some r.cwd; paths = files } in
    List.iter (fun l -> print caps (l ^ "\n")) lines;
    0
  end
  else begin
    let commit = match base with Some h -> h | None -> (try Query.eval1 r.store "HEAD" with Query.Error m -> die "%s" m) in
    let lines, _ = walk_run r { Walk.default with show; base; bare = true; paths = files } in
    !diff_hook caps r commit lines;
    0
  end
