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

type caps = < Recipe.caps; Cap.env; Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr >

let usage = "Usage: mk [-f file] [-(n|a|e|t|k|i|H)] [-d[egp]] [targets ...]"
let hashfile = ".mkhash"

(*****************************************************************************)
(* The outside world *)
(*****************************************************************************)

(* mk's standard output is buffered, and flushed only before a job or a
 * :P: command runs and at the end; its errors are not. So under -n an
 * error is printed before the recipes that came first, as in 9base. *)
let out = Buffer.create 4096
let print (_ : < Cap.stdout; .. >) s = Buffer.add_string out s
let flush_out (_ : < Cap.stdout; .. >) = print_string (Buffer.contents out); Buffer.clear out; flush stdout
let eprint (_ : < Cap.stderr; .. >) s = prerr_string s; flush stderr

let read_file (caps : < Cap.open_in; .. >) (file : string) : string option =
  if not (Sys.file_exists file) then None
  else
    let ic = CapStdlib.open_in caps file in
    let s = really_input_string ic (in_channel_length ic) in
    close_in ic;
    Some s

(* modification times are read through the capability to read files *)
let stat (_ : < Cap.open_in; .. >) (name : string) : float =
  match Unix.stat name with st -> st.Unix.st_mtime | exception Unix.Unix_error _ -> 0.

let write_file (_ : < Cap.open_out; .. >) (file : string) (s : string) : unit =
  let oc = open_out_bin file in
  output_string oc s;
  close_out oc

(* file.c's touch(): update the time, or create the file; for an
 * archive member, its date in the archive's header *)
let touch (caps : < Cap.open_in; Cap.open_out; .. >) (name : string) : unit =
  match Archive.split name with
  | Some (ar, member) -> (
      match read_file caps ar with
      | Some s -> write_file caps ar (Archive.touch_date ~now:(Unix.gettimeofday ()) s member)
      | None -> write_file caps ar "!<arch>\n")
  | None ->
      if Sys.file_exists name then Unix.utimes name 0. 0.
      else Unix.close (Unix.openfile name [ Unix.O_WRONLY; Unix.O_CREAT ] 0o666)

let delete (caps : < Cap.open_out; Cap.stderr; .. >) (name : string) : unit =
  if Archive.split name <> None then eprint caps "hoon off; mk can't delete archive members\n"
  else try Sys.remove name with Sys_error msg -> eprint caps (msg ^ "\n")

let first_int mk name =
  match Mkfile.lookup mk name with
  | Some (v :: _) -> Option.value (int_of_string_opt v) ~default:1
  | _ -> 1

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let main (caps : < caps; .. >) (argv : string array) : int =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let args = List.tl (Array.to_list argv) in
  let file = ref None and whatif = ref [] in
  let dump_mkfile = ref false and dump_graph = ref false in
  let dry = ref false and touch_ = ref false and always = ref false in
  let keep = ref false and explain = ref false and seq = ref false and uflag = ref false in
  let hash = ref false in
  let mkflags = ref [] in
  (* main.c: only the first letter of an option counts *)
  let rec options = function
    | a :: rest when String.length a > 0 && a.[0] = '-' ->
        mkflags := a :: !mkflags;
        let letter = if String.length a > 1 then a.[1] else ' ' in
        (match letter, rest with
         | 'f', f :: rest -> mkflags := f :: !mkflags; file := Some f; options rest
         | 'w', rest when String.length a > 2 ->
             whatif := String.sub a 2 (String.length a - 2) :: !whatif; options rest
         | 'w', f :: rest -> whatif := f :: !whatif; options rest
         | 's', rest -> seq := true; options rest
         | 'e', rest -> explain := true; options rest
         | 'n', rest -> dry := true; options rest
         | 'H', rest -> hash := true; options rest
         | 'u', rest -> uflag := true; options rest
         | 't', rest -> touch_ := true; options rest
         | 'a', rest -> always := true; options rest
         | 'k', rest -> keep := true; options rest
         | 'i', rest -> options rest
         | 'd', rest ->
             (* -dp the mkfile as read, -dg the graph; -d both (and 9base's e) *)
             let what = if String.length a > 2 then String.sub a 2 (String.length a - 2) else "egp" in
             dump_mkfile := String.contains what 'p';
             dump_graph := String.contains what 'g';
             options rest
         | _ -> failwith usage)
    | rest -> rest
  in
  try
    let rest = options args in
    let assigns, targets = List.partition (fun a -> String.contains a '=') rest in
    let env =
      CapUnix.environment caps () |> Array.to_list |> List.filter_map (fun kv ->
        match String.index_opt kv '=' with
        | Some i -> Some (String.sub kv 0 i, String.sub kv (i + 1) (String.length kv - i - 1))
        | None -> None)
    in
    let pid = Unix.getpid () in
    let mk = Mkfile.create ~env ~default_shell:[ "sh" ] in
    let io : Mkfile.io = {
      read_file = read_file caps;
      output = (fun mk ~shell ~stdin cmd ->
        let env = Recipe.environment ~shell (Recipe.env mk ~slot:0 ~pid ()) in
        Recipe.output caps ~shell ~env ~stdin cmd);
      warn = (fun msg -> eprint caps (msg ^ "\n"));
    } in
    if assigns <> [] then
      Mkfile.read ~override:true io mk ~file:"<command line args>"
        (String.concat "" (List.map (fun a -> a ^ "\n") assigns));
    Mkfile.set mk "MKFLAGS" (List.rev !mkflags @ assigns);
    Mkfile.set mk "MKARGS" targets;
    (* principia's mk: MKSHELL from the environment or the command line *)
    (match Mkfile.lookup mk "MKSHELL" with
     | Some (_ :: _ as shell) -> Mkfile.set_default_shell mk shell
     | _ -> ());
    (match !file with
     | Some f -> (
         match read_file caps f with
         | Some text -> Mkfile.read io mk ~file:f text
         | None -> failwith (f ^ ": No such file or directory"))
     | None -> Option.iter (Mkfile.read io mk ~file:"mkfile") (read_file caps "mkfile"));
    if !dump_mkfile then print caps (Mkfile.dump mk);
    let now = Unix.gettimeofday () in
    let whatif =
      List.concat_map (fun s ->
        String.split_on_char ',' s |> List.concat_map (String.split_on_char ' ')
        |> List.concat_map (String.split_on_char '\n') |> List.filter (( <> ) "")) !whatif
    in
    (* a name with a ( is an archive member (archive.c's split) *)
    let archives = Archive.create ~read:(read_file caps) ~mtime:(stat caps) in
    let warned = Hashtbl.create 3 in
    let time ?force name =
      match Archive.split name with
      | None -> stat caps name
      | Some (ar, _) ->
          (match read_file caps ar with
           | None ->
               (* plan9port warns only about a name not ending in .a *)
               if not (Hashtbl.mem warned ar || Filename.check_suffix ar ".a") then begin
                 Hashtbl.replace warned ar ();
                 print caps (Printf.sprintf "%s doesn't exist: assuming it will be an archive\n" ar)
               end
           | Some s -> if not (Archive.is_archive s) then failwith (Printf.sprintf "'%s' is not an archive" name));
          Archive.time ?force archives name
    in
    let g = Graph.create mk ~stat:(fun name -> if List.mem name whatif then now else time name) in
    let shell_env () =
      Recipe.environment ~shell:(Mkfile.default_shell mk) (Recipe.env mk ~slot:0 ~pid ())
    in
    let bio : Build.io = {
      run = (fun (j : Recipe.job) ~slot:_ ~env ->
        flush_out caps;
        Recipe.start caps ~shell:j.rule.shell ~env:(Recipe.environment ~shell:j.rule.shell env)
          ~args:(if j.rule.attrs.noerror then [] else [ "-e" ]) j.rule.recipe);
      wait = (fun () ->
        match Recipe.wait caps with
        | r -> Some r
        | exception Unix.Unix_error (Unix.ECHILD, _, _) -> None);
      stat = time ~force:true;
      exists = Sys.file_exists;
      touch = touch caps;
      delete = delete caps;
      prog = (fun cmd target prereq ->
        flush_out caps;
        snd (Recipe.output caps ~shell:(Mkfile.default_shell mk) ~env:(shell_env ())
               ~stdin:false (Printf.sprintf "%s '%s' '%s'" cmd target prereq)));
      now = Unix.gettimeofday;
      print = print caps;
      eprint = eprint caps;
      cwd = Sys.getcwd ();
      pid;
    } in
    (* -H: the traces of the last build, in .mkhash (Outofdate) *)
    let hashes =
      if not !hash then None
      else begin
        let traces = Hashtbl.create 101 in
        Option.iter (fun s ->
          String.split_on_char '\n' s |> List.iter (fun l ->
            match String.index_opt l '\t' with
            | Some i -> Hashtbl.replace traces (String.sub l 0 i) (String.sub l (i + 1) (String.length l - i - 1))
            | None -> ())) (read_file caps hashfile);
        let digests = Hashtbl.create 101 in
        let digest name =
          match stat caps name with
          | 0. -> None
          | t -> (
              match Hashtbl.find_opt digests name with
              | Some (t', d) when t' = t -> Some d
              | _ ->
                  let d = Digest.to_hex (Digest.file name) in
                  Hashtbl.replace digests name (t, d);
                  Some d)
        in
        Some { Outofdate.digest; traces }
      end
    in
    let save_hashes () =
      match hashes with
      | Some h when not !dry ->
          Hashtbl.fold (fun k v acc -> (k ^ "\t" ^ v ^ "\n") :: acc) h.traces []
          |> List.sort compare |> String.concat "" |> write_file caps hashfile
      | _ -> ()
    in
    let b = Build.create ?hashes mk g bio
        { dry = !dry; touch = !touch_; always = !always; keep_going = !keep; explain = !explain } in
    let make target =
      let nrep = first_int mk "NREP" in
      if !dump_graph then print caps (Graph.dump (Graph.node g ~nrep target));
      Build.make b ~nproc:(first_int mk "NPROC") ~nrep target
    in
    (try
       match targets with
       | [] -> (
           match Mkfile.default_targets mk with
           | [] -> failwith "nothing to mk"
           | ts -> List.iter make ts)
       | [ t ] -> make t
       | ts when !seq -> List.iter make ts
       | ts ->
           let fake = "command line arguments" in
           Mkfile.add_rule mk ~targets:[ fake ] ~prereqs:ts ~recipe:""
             { Mkfile.no_attrs with virtual_ = true };
           make fake
     with Build.Failed ->
       (try Build.wait_all b with Build.Failed -> ());
       save_hashes ();
       raise Build.Failed);
    save_hashes ();
    if !uflag then print caps (Build.usage b);
    (* under -k, failed recipes do not change the exit status (9base) *)
    flush_out caps;
    0
  with
  | Build.Failed -> flush_out caps; 1
  | Mkfile.Error msg | Graph.Error msg | Word.Error msg | Failure msg ->
      let nl = if msg <> "" && msg.[String.length msg - 1] = '\n' then "" else "\n" in
      eprint caps ("mk: " ^ msg ^ nl);
      flush_out caps;
      1
