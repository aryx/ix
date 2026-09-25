(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The test suite of shell/: the .mli examples and the laws (Unit_rc),
 * the corpus against the outputs recorded from 9base's rc
 * (differential.sh check, one test per case), and two laws on real
 * processes. From the root: make test. *)

let corpus_dir = "shell/tests/corpus"

let sh cmd = Sys.command cmd = 0

let corpus () =
  if not (Sys.file_exists corpus_dir) then []
  else
    Sys.readdir corpus_dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".rc") |> List.sort compare
    |> List.map (fun f ->
      Testo.create ("corpus: " ^ Filename.chop_suffix f ".rc") (fun () ->
        if not (sh (Printf.sprintf "./shell/tests/differential.sh check %s/%s >/dev/null" corpus_dir f))
        then Alcotest.fail ("differs from 9base: " ^ f);
        Testo.Promise.return ()))

let mini_rc = "./_build/default/shell/Main.exe"

(* what [script] prints under mini-rc *)
let output script =
  let tmp = Filename.temp_file "mini-rc" ".out" in
  ignore (Sys.command (Printf.sprintf "%s -c %s > %s 2>&1" mini_rc (Filename.quote script) tmp));
  let s = In_channel.with_open_bin tmp In_channel.input_all in
  Sys.remove tmp;
  s

let process_laws = [
  (* rc folds all but the last stage into one status (9base: false |
   * false | false leaves 1|1), so the law is about truth: a pipeline
   * succeeds exactly when every stage does *)
  Testo.create "law: a pipeline is true when all its stages are" (fun () ->
    let stages = [ "true"; "false" ] in
    let rec all n = if n = 0 then [ [] ] else List.concat_map (fun s -> List.map (fun r -> s :: r) (all (n - 1))) stages in
    List.concat_map all [ 1; 2; 3; 4 ] |> List.iter (fun cmds ->
      let pipe = String.concat " | " cmds in
      let expected = if List.for_all (( = ) "true") cmds then "yes\n" else "no\n" in
      Alcotest.(check string) pipe expected (output (pipe ^ " && echo yes || echo no")));
    Testo.Promise.return ());
  Testo.create "law: {cmd} and @{cmd} print the same" (fun () ->
    [ "echo a; echo b"; "for(i in 1 2) echo $i"; "ls /dev/null | wc -l" ]
    |> List.iter (fun c ->
      Alcotest.(check string) c (output ("{" ^ c ^ "}")) (output ("@{" ^ c ^ "}")));
    Testo.Promise.return ());
]

(* milestone 3: an interactive session, through a pipe, prompts and all,
 * against what 9base's rc printed for it *)
let session =
  Testo.create "session: the prompt, errors, exit" (fun () ->
    let cmd =
      Printf.sprintf "cd /tmp && env -i PATH=/usr/bin:/bin HOME=/nonexistent %s -i < %s/session.in 2>&1; echo \"[exit $?]\""
        (Sys.getcwd () ^ "/" ^ mini_rc) (Sys.getcwd () ^ "/" ^ corpus_dir)
    in
    let tmp = Filename.temp_file "session" ".out" in
    ignore (Sys.command (Printf.sprintf "(%s) | sed 's|rc ([^)]*)|rc (ARGV0)|' > %s" cmd tmp));
    let got = In_channel.with_open_bin tmp In_channel.input_all in
    Sys.remove tmp;
    let expected = In_channel.with_open_bin (corpus_dir ^ "/session.expected") In_channel.input_all in
    Alcotest.(check string) "as 9base's rc" expected got;
    Testo.Promise.return ())

let tests _env = Unit_rc.tests @ process_laws @ (session :: corpus ())

let () = Cap.main (fun (_ : Cap.all_caps) -> Testo.interpret_argv ~project_name:"ix-rc" tests)
