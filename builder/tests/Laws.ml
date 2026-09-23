(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The laws a build system must obey (Mokhov, Mitchell and Peyton Jones,
 * "Build Systems a la Carte", 2018), checked on random graphs, one per
 * seed:
 *
 *   correct      after a build, every target is what a clean build
 *                makes
 *   minimal      after a leaf changes, exactly the targets that depend
 *                on it are made again
 *   idempotent   a second build runs nothing
 *   parallel     NPROC=4, jobs ending in a random order, makes the same
 *                files as NPROC=1, and starts no job before its
 *                prerequisites are made
 *)
module U = Testutil_mk

let t name f = Testo.create name (fun () -> f (); Testo.Promise.return ())
let seeds = List.init 50 (fun i -> i + 1)

let dag seed = U.random_dag seed ~targets:12 ~leaves:5

let check_correct seed (w : U.world) deps =
  deps |> List.iter (fun (t, _) ->
    Alcotest.(check (option string)) (Printf.sprintf "seed %d: %s" seed t)
      (Some (U.expected deps w t)) (U.content w t))

let sorted = List.sort compare

let laws = [
  t "laws: correct, minimal, idempotent" (fun () ->
    seeds |> List.iter (fun seed ->
      let text, leaves, deps = dag seed in
      let w = U.world leaves in
      let _ = U.build w (U.mkfile text) "all" in
      check_correct seed w deps;
      Alcotest.(check (list string)) (Printf.sprintf "seed %d: idempotent" seed)
        [ "all" ] (U.build w (U.mkfile text) "all");
      let leaf = List.nth leaves (seed mod List.length leaves) in
      U.edit w leaf;
      let ran = U.build w (U.mkfile text) "all" in
      check_correct seed w deps;
      Alcotest.(check (list string)) (Printf.sprintf "seed %d: minimal after %s" seed leaf)
        (sorted ("all" :: U.dependents deps leaf)) (sorted ran)));
  t "laws: parallel = sequential" (fun () ->
    seeds |> List.iter (fun seed ->
      let text, leaves, deps = dag seed in
      let order = Random.State.make [| seed * 7 |] in
      let w = U.world ~order leaves in
      let _ = U.build ~nproc:4 w (U.mkfile text) "all" in
      Alcotest.(check (list string)) (Printf.sprintf "seed %d: no early start" seed) [] w.violations;
      check_correct seed w deps;
      let leaf = List.nth leaves (seed mod List.length leaves) in
      U.edit w leaf;
      let ran = U.build ~nproc:4 w (U.mkfile text) "all" in
      Alcotest.(check (list string)) (Printf.sprintf "seed %d: no early start (2)" seed) [] w.violations;
      check_correct seed w deps;
      Alcotest.(check (list string)) (Printf.sprintf "seed %d: minimal" seed)
        (sorted ("all" :: U.dependents deps leaf)) (sorted ran)));
]
