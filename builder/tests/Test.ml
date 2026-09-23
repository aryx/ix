(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The test suite of builder/: the .mli examples (Unit_mk), the laws
 * (Laws), and the corpus of builder/tests/corpus/ against the outputs
 * recorded from 9base's mk (differential.sh check, one test per case).
 *
 * From the root of the repository: make test, or
 * ./_build/default/builder/tests/Test.exe -s vars   (the tests with "vars") *)

let corpus_dir = "builder/tests/corpus"

let corpus () =
  if not (Sys.file_exists corpus_dir) then []
  else
    Sys.readdir corpus_dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".mk")
    |> List.sort compare
    |> List.map (fun f ->
      Testo.create ("corpus: " ^ Filename.chop_suffix f ".mk") (fun () ->
        let cmd = Printf.sprintf "./builder/tests/differential.sh check %s/%s" corpus_dir f in
        if Sys.command cmd <> 0 then Alcotest.fail ("differs from 9base: " ^ f);
        Testo.Promise.return ()))

let tests _env = Unit_mk.tests @ Laws.laws @ corpus ()

let () =
  Cap.main (fun (_caps : Cap.all_caps) ->
    Testo.interpret_argv ~project_name:"ix" tests)
