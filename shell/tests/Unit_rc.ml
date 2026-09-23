(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The worked examples of shell/'s .mli files, checked, and the laws. *)
open Ix_rc

let t name f = Testo.create name (fun () -> f (); Testo.Promise.return ())
let strs = Alcotest.(check (list string))
let str = Alcotest.(check string)

(* expand words with fixed variables, no shell *)
let ctx vars : Word.ctx = {
  var = (fun n -> Option.value (List.assoc_opt n vars) ~default:[]);
  backquote = (fun _ _ -> "one two\n");
  pipefd = (fun _ _ -> "/dev/fd/9");
}

let expand vars src =
  match Parser.parse_string ("echo " ^ src) with
  | Ast.Simple (_ :: ws) -> List.concat_map (fun w -> List.map Glob.to_string (Word.expand (ctx vars) w)) ws
  | _ -> Alcotest.fail "not a simple command"

let print src = Ast.to_string Ast.cmd (Parser.parse_string src)

let word_tests = [
  t "word: lists" (fun () ->
    let v = [ "x", [ "a"; "b"; "c" ]; "*", [ "p"; "q" ]; "y", [ "x" ] ] in
    strs "$x" [ "a"; "b"; "c" ] (expand v "$x");
    strs "$#x" [ "3" ] (expand v "$#x");
    strs "join" [ "a b c" ] (expand v "$\"x");
    strs "$x(2)" [ "b" ] (expand v "$x(2)");
    strs "$x(2-)" [ "b"; "c" ] (expand v "$x(2-)");
    strs "$x(9)" [] (expand v "$x(9)");
    strs "$2" [ "q" ] (expand v "$2");
    strs "$$y" [ "a"; "b"; "c" ] (expand v "$$y"));
  t "word: concatenation distributes" (fun () ->
    let v = [ "x", [ "a"; "b"; "c" ] ] in
    strs "a^(b c)" [ "ab"; "ac" ] (expand v "a^(b c)");
    strs "pairwise" [ "ac"; "bd" ] (expand v "(a b)^(c d)");
    strs "free caret" [ "a.o"; "b.o"; "c.o" ] (expand v "$x.o");
    strs "x$x" [ "xa"; "xb"; "xc" ] (expand v "x$x");
    (match expand v "(a b)^(c d e)" with
     | _ -> Alcotest.fail "no error"
     | exception Word.Error m -> str "mismatch" "mismatched list lengths in concatenation" m);
    (match expand v "$none^a" with
     | _ -> Alcotest.fail "no error"
     | exception Word.Error m -> str "null" "null list in concatenation" m));
  t "word: backquote splits on ifs" (fun () ->
    strs "`{}" [ "one"; "two" ] (expand [ "ifs", [ " \t\n" ] ] "`{echo}"));
]

let glob_tests = [
  t "glob: patterns" (fun () ->
    let w s q = [ { Glob.text = s; literal = q } ] in
    Alcotest.(check bool) "*.c" true (Glob.matches (w "*.c" false) "a.c");
    Alcotest.(check bool) "'*'.c literal" false (Glob.matches (w "*" true @ w ".c" false) "a.c");
    Alcotest.(check bool) "[~a]" false (Glob.matches (w "[~a].c" false) "a.c");
    Alcotest.(check bool) "* matches / in ~" true (Glob.matches (w "*" false) "a/b");
    let files = [ "", [ "b.c"; "a.c"; ".hidden"; "d1" ]; "d1", [ "x.c" ] ] in
    let readdir d = List.assoc_opt d files in
    let exists f = List.mem f [ "a.c"; "b.c"; ".hidden"; "d1"; "d1/x.c" ] in
    strs "*.c" [ "a.c"; "b.c" ] (Glob.files ~readdir ~exists (w "*.c" false));
    strs "*" [ ".hidden"; "a.c"; "b.c"; "d1" ] (Glob.files ~readdir ~exists (w "*" false));
    strs "no match" [ "nomatch*" ] (Glob.files ~readdir ~exists (w "nomatch*" false));
    strs "*/*.c" [ "d1/x.c" ] (Glob.files ~readdir ~exists (w "*/*.c" false)));
]

let parser_tests = [
  t "parser: precedences, as syn.y" (fun () ->
    str "if body" "if(c)a && b" (print "if(c) a && b");
    str "! pipe" "! a|b" (print "! a | b");
    str "assign" "x=1 a|b" (print "x=1 a | b");
    str "prefix redir after |" "a|>f b" (print "a | >f b");
    str "keywords as words" "echo if for" (print "echo if for");
    str "carets" "echo $x^.c x^$y" (print "echo $x.c x$y"));
  t "parser: if not needs an if" (fun () ->
    (* an if not after an if, or after an if not if(...) -- not after a
     * plain if not (9base agrees) *)
    ignore (Parser.parse_string "if(c) a\nif not if(d) e\nif not f\n");
    (match Parser.parse_string "if(c) a\nif not b\nif not f\n" with
     | _ -> Alcotest.fail "if not after if not"
     | exception Parser.Error _ -> ());
    match Parser.parse_string "a\nif not b\n" with
    | _ -> Alcotest.fail "accepted"
    | exception Parser.Error _ -> ());
]

(* the printer's law: what it prints reads back as the same *)
let laws = [
  t "law: print, read, print is the same" (fun () ->
    [ "fn f { echo in f $*; if(~ $1 a*) x=`{ls} || echo no }";
      "for(i in *.c) { cc -c $i >[2=1] | grep -v warn }";
      "switch($x){case a; echo A; case *; echo other}";
      "@{ cd /; x=1 echo $x } &"; "a |[2] b >>f <g"; "while(! test -f x) sleep 1" ]
    |> List.iter (fun src ->
      let p1 = print src in
      str src p1 (print p1)));
]

let tests = word_tests @ glob_tests @ parser_tests @ laws
