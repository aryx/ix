(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Recipe.mli *)

type job = {
  rule : Mkfile.rule;
  stems : string array;
  targets : string list;
  alltargets : string list;
  prereqs : string list;
  newprereqs : string list;
  nodes : Graph.node list;
}

(*****************************************************************************)
(* The environment *)
(*****************************************************************************)

let stem_vars = List.init 10 (Printf.sprintf "stem%d")

let specials =
  [ "target"; "prereq"; "stem" ] @ stem_vars
  @ [ "alltarget"; "newprereq"; "pid"; "nproc"; "newmember" ]

(* lib.a(foo.o) -> foo.o, for $newmember *)
let member (name : string) : string option =
  match String.index_opt name '(', String.rindex_opt name ')' with
  | Some i, Some j when j > i -> Some (String.sub name (i + 1) (j - i - 1))
  | _ -> None

let env mk ?job ~slot ~pid () : (string * string list) list =
  let own =
    match job with
    | None -> List.map (fun v -> v, []) specials
    | Some j ->
        let regexp = j.rule.attrs.regexp in
        [ "target", j.targets;
          "prereq", j.prereqs;
          "stem", (if regexp then [] else [ Pattern.stem j.rule.pattern j.stems ]);
          "alltarget", j.alltargets;
          "newprereq", j.newprereqs;
          "pid", [ string_of_int pid ];
          "nproc", [ string_of_int slot ];
          "newmember", List.filter_map member j.newprereqs ]
        @ List.mapi (fun i v ->
            v, if regexp && i < Array.length j.stems then [ j.stems.(i) ] else [])
            stem_vars
  in
  own @ List.filter (fun (k, _) -> not (List.mem k specials)) (Mkfile.exported mk)

let environment ~shell (vars : (string * string list) list) : string array =
  let rc = Word.quoting_of_shell shell = Word.Rc in
  vars
  (* an empty list is not exported to rc: on Plan 9 it is an empty /env
   * file, which rc reads as (); a Unix rc reads "X=" as ('') instead,
   * and ocamlc $X then gets an empty argument (omk's Shell.ml has the
   * same fix; 9base's mk does not) *)
  |> List.filter (fun (_, vs) -> not (rc && vs = []))
  |> List.map (fun (k, vs) -> k ^ "=" ^ String.concat (if rc then "\001" else " ") vs)
  |> Array.of_list

(*****************************************************************************)
(* Printing *)
(*****************************************************************************)

let shprint mk (env : (string * string list) list) ~(quoting : Word.quoting)
    (recipe : string) : string =
  let b = Buffer.create (String.length recipe) in
  let n = String.length recipe in
  let is_quote c = c = '\'' || (quoting = Word.Sh && (c = '"' || c = '`')) in
  let rec go i =
    if i >= n then ()
    else if is_quote recipe.[i] then begin
      (* a quoted string is copied as is, through its closing quote *)
      let j =
        match String.index_from_opt recipe (i + 1) recipe.[i] with
        | Some j -> j + 1
        | None -> n
      in
      Buffer.add_string b (String.sub recipe i (j - i));
      go j
    end
    else if recipe.[i] = '$' then begin
      let braced = i + 1 < n && recipe.[i + 1] = '{' in
      let start = if braced then i + 2 else i + 1 in
      let stop =
        if braced then Option.value (String.index_from_opt recipe start '}') ~default:n
        else
          let j = ref start in
          while !j < n && Word.is_wordchar recipe.[!j] do incr j done;
          !j
      in
      let name = String.sub recipe start (stop - start) in
      (* shprint.c's vexpand() skips a '}' after the name even when it
       * is not braced: `{cmd $X} prints without its '}' once $X is
       * expanded (checked on 9base) *)
      let after = if stop < n && recipe.[stop] = '}' then stop + 1 else stop in
      (match List.assoc_opt name env with
       | Some vs when Mkfile.set_here mk name || List.mem name specials ->
           Buffer.add_string b (String.concat " " vs)
       | _ -> Buffer.add_string b (String.sub recipe i (after - i)));
      go after
    end
    else (Buffer.add_char b recipe.[i]; go (i + 1))
  in
  go 0;
  Buffer.contents b

let front (s : string) : string =
  let fields = String.split_on_char ' ' s |> List.concat_map (String.split_on_char '\t')
               |> List.concat_map (String.split_on_char '\n') in
  let fields =
    if List.length fields > 5 then
      List.filteri (fun i _ -> i < 3) fields @ [ "..."; List.nth fields (List.length fields - 1) ]
    else fields
  in
  String.concat "" (List.map (fun f -> f ^ " ") fields)

(*****************************************************************************)
(* Processes *)
(*****************************************************************************)

type caps = < Cap.fork; Cap.exec; Cap.wait >

(* rc's -I: not interactive, even on a terminal (principia's rc.c) *)
let shell_flags shell = match Word.quoting_of_shell shell with Word.Rc -> [ "-I" ] | Word.Sh -> []

(* the shell's path: as given, or found in the recipe environment's PATH *)
let resolve (cmd : string) (env : string array) : string =
  if String.contains cmd '/' then cmd
  else
    let path =
      Array.to_list env |> List.find_map (fun kv ->
        if String.length kv > 5 && String.sub kv 0 5 = "PATH=" then
          Some (String.sub kv 5 (String.length kv - 5))
        else None)
      |> Option.value ~default:"/bin:/usr/bin"
    in
    String.split_on_char ':' path |> List.map (fun d -> Filename.concat d cmd)
    |> List.find_opt Sys.file_exists |> Option.value ~default:cmd

let rec write_all fd s off =
  if off < String.length s then
    match Unix.write_substring fd s off (String.length s - off) with
    | k -> write_all fd s (off + k)
    | exception Unix.Unix_error (Unix.EPIPE, _, _) -> ()   (* it did not read it all *)

let spawn caps ~shell ~env ~args ~stdin ~stdout =
  let argv = Array.of_list (shell @ shell_flags shell @ args) in
  let prog = resolve (List.hd shell) env in
  match CapUnix.fork caps () with
  | 0 ->
      Option.iter (fun fd -> Unix.dup2 fd Unix.stdin) stdin;
      Option.iter (fun fd -> Unix.dup2 fd Unix.stdout) stdout;
      (try CapUnix.execve caps prog argv env with _ -> ());
      prerr_endline ("mk: can't exec " ^ prog);
      Unix._exit 127
  | pid -> pid

let start caps ~shell ~env ~args script =
  let rd, wr = Unix.pipe ~cloexec:true () in
  let pid = spawn caps ~shell ~env ~args ~stdin:(Some rd) ~stdout:None in
  Unix.close rd;
  write_all wr script 0;
  Unix.close wr;
  pid

let describe (st : Unix.process_status) : string =
  match st with
  | Unix.WEXITED 0 -> ""
  | Unix.WEXITED n -> Printf.sprintf "exit(%d)" n
  | Unix.WSIGNALED n | Unix.WSTOPPED n -> Printf.sprintf "signal %d" n

let rec wait caps =
  match CapUnix.wait caps () with
  | pid, st -> pid, describe st
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait caps

let output caps ~shell ~env ~stdin cmd =
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let pid, in_w =
    if stdin then begin
      let in_r, in_w = Unix.pipe ~cloexec:true () in
      let pid = spawn caps ~shell ~env ~args:[] ~stdin:(Some in_r) ~stdout:(Some out_w) in
      Unix.close in_r;
      pid, Some in_w
    end else spawn caps ~shell ~env ~args:[ "-c"; cmd ] ~stdin:None ~stdout:(Some out_w), None
  in
  Unix.close out_w;
  Option.iter (fun fd -> write_all fd cmd 0; Unix.close fd) in_w;
  let b = Buffer.create 1024 and chunk = Bytes.create 4096 in
  let rec read () =
    match Unix.read out_r chunk 0 4096 with
    | 0 -> ()
    | k -> Buffer.add_subbytes b chunk 0 k; read ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read ()
  in
  read ();
  Unix.close out_r;
  let rec reap () =
    match CapUnix.waitpid caps [] pid with
    | _, st -> st
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
  in
  let st = reap () in
  Buffer.contents b, st = Unix.WEXITED 0
