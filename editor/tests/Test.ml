(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The test suite of editor/: the .mli examples (Unit_ed), the corpus
 * against the outputs recorded from 9base's ed (differential.sh check,
 * one test per case), and the laws, on mini-ed run as a program. From
 * the root: make test. *)

let corpus_dir = "editor/tests/corpus"
let mini_ed = "./_build/default/editor/Main.exe"

let corpus () =
  Sys.readdir corpus_dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".ed") |> List.sort compare
  |> List.map (fun f ->
    Testo.create ("corpus: " ^ Filename.chop_suffix f ".ed") (fun () ->
      if Sys.command (Printf.sprintf "./editor/tests/differential.sh check %s/%s >/dev/null" corpus_dir f) <> 0
      then Alcotest.fail ("differs from 9base: " ^ f);
      Testo.Promise.return ()))

(* Filename.temp_dir is OCaml 5.1's *)
let temp_dir () = let d = Filename.temp_file "mini-ed" "" in Sys.remove d; Sys.mkdir d 0o700; d

let write file s = Out_channel.with_open_bin file (fun oc -> output_string oc s)
let read file = In_channel.with_open_bin file In_channel.input_all

(* [edit text script]: the file after mini-ed ran script on it *)
let edit text script =
  let dir = temp_dir () in
  let f = Filename.concat dir "f" and s = Filename.concat dir "s" in
  write f text;
  write s script;
  ignore (Sys.command (Printf.sprintf "%s - %s < %s > /dev/null 2>&1" mini_ed f s));
  let r = read f in
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir));
  r

let texts = [ "a\nb\nc\n"; "one\ntwo\nthree\nfour\nfive\n"; "x\n\ny\nx\n"; "int main() {\n  return 0;\n}\n" ]
let t name f = Testo.create name (fun () -> f (); Testo.Promise.return ())
let str = Alcotest.(check string)

let laws = [
  t "law: diff -e a b, then w, makes a into b" (fun () ->
    List.iter (fun a -> List.iter (fun b ->
      let dir = temp_dir () in
      let fa = Filename.concat dir "a" and fb = Filename.concat dir "b" in
      write fa a;
      write fb b;
      let ic = Unix.open_process_in (Printf.sprintf "diff -e %s %s" fa fb) in
      let script = In_channel.input_all ic in
      ignore (Unix.close_process_in ic);
      str "diff -e" b (edit a (script ^ "w\nq\n"));
      ignore (Sys.command ("rm -rf " ^ Filename.quote dir))) texts) texts);
  t "law: s then u is nothing" (fun () ->
    List.iter (fun a -> str "s u" a (edit a "1s/./X/g\nu\nw\nq\n")) texts);
  t "law: m there and m back is nothing" (fun () ->
    List.iter (fun a -> str "m m" a (edit a "1m$\n$m0\nw\nq\n")) texts);
  t "law: t then d of the copy is nothing" (fun () ->
    List.iter (fun a -> str "t d" a (edit a "1,2t$\n$-1,$d\nw\nq\n")) texts);
  t "law: g/re/p prints what grep -E prints" (fun () ->
    List.iter (fun re -> List.iter (fun a ->
      let dir = temp_dir () in
      let f = Filename.concat dir "f" in
      write f a;
      let run cmd = let ic = Unix.open_process_in cmd in let s = In_channel.input_all ic in ignore (Unix.close_process_in ic); s in
      let ours = run (Printf.sprintf "printf 'g/%s/p\\nq\\n' | %s - %s" re mini_ed f) in
      let grep = run (Printf.sprintf "grep -E '%s' %s" re f) in
      str re grep ours;
      ignore (Sys.command ("rm -rf " ^ Filename.quote dir))) texts) [ "o"; "^t"; "e$"; "[a-c]"; "x|y"; "(on)+" ]);
]

let tests _env = Unit_ed.tests @ laws @ corpus ()

let () = Cap.main (fun (_ : Cap.all_caps) -> Testo.interpret_argv ~project_name:"ix-ed" tests)
