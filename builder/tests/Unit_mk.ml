(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The worked examples of the .mli files, checked: if one of these
 * fails, the explanation and the code have drifted apart. *)
open Ix_mk
module U = Testutil_mk

let t name f = Testo.create name (fun () -> f (); Testo.Promise.return ())
let words = Alcotest.(check (list string))
let str = Alcotest.(check string)
let boolean = Alcotest.(check bool)

let lookup vars name = List.assoc_opt name vars

(*****************************************************************************)
(* Word.mli *)
(*****************************************************************************)

let word_tests = [
  t "word: a list glues at its ends" (fun () ->
    let lookup = lookup [ "X", [ "a"; "b" ]; "OBJS", [ "hello.5"; "world.5" ] ] in
    let split = Word.split Word.Rc ~lookup in
    words "OBJS" [ "hello.5"; "world.5" ] (split "$OBJS");
    words "$X.o" [ "a"; "b.o" ] (split "$X.o");
    words "pre$X" [ "prea"; "b" ] (split "pre$X");
    words "$X$X" [ "a"; "ba"; "b" ] (split "$X$X");
    words "undefined" [ "xy" ] (split "x${NONE}y");
    words "undefined alone" [] (split "$NONE");
    words "quoted" [ "a"; "b.o"; "c d" ] (split "$X.o 'c d'"));
  t "word: substitution" (fun () ->
    let lookup = lookup [ "SRC", [ "Ast.ml"; "Main.ml"; "lexer.mll" ] ] in
    let split = Word.split Word.Rc ~lookup in
    words "%.ml=%.cmo" [ "Ast.cmo"; "Main.cmo"; "lexer.mll" ] (split "${SRC:%.ml=%.cmo}");
    words "no % on the right" [ "gone"; "gone"; "lexer.mll" ] (split "${SRC:%.ml=gone}");
    words "undefined" [ "UNDEF" ] (split "${UNDEF:%.c=%.o}"));
  t "word: quoting" (fun () ->
    let none _ = None in
    words "rc" [ "it's" ] (Word.split Word.Rc ~lookup:none "'it''s'");
    words "sh" [ "a b"; "c d"; "e f" ] (Word.split Word.Sh ~lookup:none "'a b' \"c d\" e\\ f");
    words "rc keeps double quotes" [ "\"x"; "y\"" ] (Word.split Word.Rc ~lookup:none "\"x y\"");
    Alcotest.(check (option int)) "x='a:b' y:z" (Some 1)
      (Word.find_unquoted Word.Rc "x='a:b' y:z" ~from:0 ":=");
    Alcotest.(check (option int)) "${SRC:...}: foo" (Some 17)
      (Word.find_unquoted Word.Rc "${SRC:%.ml=%.cmo}: foo" ~from:0 ":"));
  t "word: UTF-8 is a word character" (fun () ->
    words "é" [ "café.o" ] (Word.split Word.Rc ~lookup:(lookup [ "é", [ "café" ] ]) "$é.o"));
]

(*****************************************************************************)
(* Pattern.mli *)
(*****************************************************************************)

let pattern_tests = [
  t "pattern: the table" (fun () ->
    let m ?(regexp = false) p name = Pattern.matches (Pattern.of_target ~regexp p) name in
    let stems = Alcotest.(check (option (array string))) in
    stems "literal" (Some [||]) (m "hello" "hello");
    stems "%" (Some [| "hello" |]) (m "%.5" "hello.5");
    stems "% and /" (Some [| "dir/hello" |]) (m "%.5" "dir/hello.5");
    stems "& and /" None (m "&.5" "dir/hello.5");
    stems ":R:" (Some [| "hello.5"; "hello" |]) (m ~regexp:true "(.+)\\.5" "hello.5"));
  t "pattern: subst" (fun () ->
    let p = Pattern.of_target ~regexp:false "%.5" in
    str "%.c" "hello.c" (Pattern.subst p [| "hello" |] "%.c");
    str "every %" "hello/hello.c" (Pattern.subst p [| "hello" |] "%/%.c");
    let r = Pattern.of_target ~regexp:true "(.+)\\.5" in
    str "\\1.c" "hello.c" (Pattern.subst r [| "hello.5"; "hello" |] "\\1.c"));
]

(*****************************************************************************)
(* Mkfile.mli *)
(*****************************************************************************)

let mkfile_tests = [
  t "mkfile: evaluated as read" (fun () ->
    let mk = U.mkfile "Y=early\nlate:V: $Y\nY=changed\n" in
    words "late's prereqs" [ "early" ] (List.concat_map (fun (r : Mkfile.rule) -> r.prereqs) (Mkfile.rules_for mk "late"));
    words "Y at the end" [ "changed" ] (Option.get (Mkfile.lookup mk "Y")));
  t "mkfile: rules for one target, in mk's order" (fun () ->
    let mk = U.mkfile "a: b\na: c\na: d\n" in
    words "b d c" [ "b"; "d"; "c" ]
      (List.concat_map (fun (r : Mkfile.rule) -> r.prereqs) (Mkfile.rules_for mk "a")));
  t "mkfile: the command line blocks every assignment" (fun () ->
    let mk = U.mkfile ~args:[ "CC=z" ] "CC=a\nx: $CC\nCC=b\ny: $CC\n" in
    let pre t = List.concat_map (fun (r : Mkfile.rule) -> r.prereqs) (Mkfile.rules_for mk t) in
    words "x" [ "z" ] (pre "x");
    words "y" [ "z" ] (pre "y"));
  t "mkfile: a comment after a header is its recipe" (fun () ->
    let mk = U.mkfile "all:V: foo\n# a comment\n\nfoo:V:\n\techo foo\n" in
    str "recipe" "# a comment\n" (List.hd (Mkfile.rules_for mk "all")).recipe;
    str "foo's" "echo foo\n" (List.hd (Mkfile.rules_for mk "foo")).recipe);
  t "mkfile: attributes, includes, backquotes" (fun () ->
    let mk = U.mkfile ~files:[ "inc.mk", "I=included\n" ]
        "<inc.mk\nB=`echo hi`\nt:VQPcmp -s: a\n\ttrue\nX=U=hidden\n" in
    let r = List.hd (Mkfile.rules_for mk "t") in
    boolean "V" true r.attrs.virtual_;
    boolean "Q" true r.attrs.quiet;
    Alcotest.(check (option string)) "P" (Some "cmp -s") r.attrs.prog;
    words "include" [ "included" ] (Option.get (Mkfile.lookup mk "I"));
    words "backquote" [ "ECHO"; "HI" ] (Option.get (Mkfile.lookup mk "B"));
    boolean "U" false (List.mem_assoc "X" (Mkfile.exported mk)));
  t "mkfile: the default targets" (fun () ->
    let mk = U.mkfile "%.o: %.c\n\tcc\nfirst second:V:\n\techo\nthird:V:\n\techo\n" in
    words "first rule without %" [ "first"; "second" ] (Mkfile.default_targets mk));
]

(*****************************************************************************)
(* Graph.mli *)
(*****************************************************************************)

let hello = "OBJS=hello.5 world.5\nhello: $OBJS\n\t5l\n%.5: %.c\n\t5c $stem.c\n"

let graph ?(files = []) text target =
  let mk = U.mkfile text in
  let g = Graph.create mk ~stat:(fun f -> if List.mem f files then 1. else 0.) in
  Graph.node g ~nrep:1 target

let graph_tests = [
  t "graph: hello" (fun () ->
    let root = graph ~files:[ "hello.c"; "world.c" ] hello "hello" in
    words "hello" [ "hello.5"; "world.5" ] (U.prereqs root);
    let h5 = Option.get (List.hd root.arcs).prereq in
    words "hello.5" [ "hello.c" ] (U.prereqs h5);
    str "stem" "hello" (List.hd h5.arcs).stems.(0));
  t "graph: vacuous arcs are dropped" (fun () ->
    let text = "%.5: %.c\n\t5c\n%.5: %.s\n\t5a\n" in
    words "only the .c" [ "hello.c" ] (U.prereqs (graph ~files:[ "hello.c" ] text "hello.5"));
    (match graph ~files:[ "x.c"; "x.s" ] text "x.5" with
     | _ -> Alcotest.fail "both exist: ambiguous"
     | exception Graph.Error msg ->
         boolean "ambiguous" true (String.length msg > 0 && String.sub msg 0 9 = "ambiguous")));
  t "graph: NREP" (fun () ->
    let text = "%: %.gz\n\tgunzip\n" in
    words "once" [ "foo.gz" ] (U.prereqs (graph ~files:[ "foo.gz" ] text "foo"));
    let mk = U.mkfile text in
    let g = Graph.create mk ~stat:(fun f -> if f = "foo.gz.gz" then 1. else 0.) in
    let n = Graph.node g ~nrep:2 "foo" in
    words "twice" [ "foo.gz.gz" ] (U.prereqs (Option.get (List.hd n.arcs).prereq)));
  t "graph: a simple rule beats a metarule" (fun () ->
    let n = graph "b.o:V:\n\techo simple\n%.o:V:\n\techo meta\n" "b.o" in
    str "the simple one" "echo simple\n" (List.hd n.arcs).rule.recipe;
    Alcotest.(check int) "one arc" 1 (List.length n.arcs));
  t "graph: a cycle" (fun () ->
    match graph "a: b\n\tx\nb: a\n\tx\n" "a" with
    | _ -> Alcotest.fail "no cycle found"
    | exception Graph.Error msg -> str "message" "cycle in graph detected at target a" msg);
]

(*****************************************************************************)
(* Outofdate.mli *)
(*****************************************************************************)

let outofdate_tests = [
  t "outofdate: the table" (fun () ->
    let check c o =
      let mk = U.mkfile "foo.o: foo.c\n\tcc\n" in
      let time = function "foo.c" -> c | "foo.o" -> o | _ -> 0. in
      let g = Graph.create mk ~stat:time in
      let n = Graph.node g ~nrep:1 "foo.o" in
      let ctx = Outofdate.create ~time ~prog:(fun _ _ _ -> true) in
      let a = List.hd n.arcs in
      Outofdate.arc ctx n a (Option.get a.prereq)
    in
    boolean "equal" true (check 100. 100.);
    boolean ".o newer by 0.5" false (check 100.2 100.7);
    boolean ".c newer by 0.5" true (check 100.7 100.2));
]

(*****************************************************************************)
(* Build.mli *)
(*****************************************************************************)

let build_tests = [
  t "build: hello, in mk's order" (fun () ->
    let w = U.world [ "hello.c"; "world.c" ] in
    words "from scratch" [ "hello.5"; "world.5"; "hello" ] (U.build w (U.mkfile hello) "hello");
    words "again" [] (U.build w (U.mkfile hello) "hello");
    str "up to date" "mk: 'hello' is up to date\n" w.out;
    U.edit w "world.c";
    words "world.c edited" [ "world.5"; "hello" ] (U.build w (U.mkfile hello) "hello"));
  t "build: NPROC=2, the two compilations at once" (fun () ->
    let w = U.world [ "hello.c"; "world.c" ] in
    let _ = U.build ~nproc:2 w (U.mkfile hello) "hello" in
    words "no job before its prerequisites" [] w.violations;
    str "linked" "hello(hello.5(hello.c),world.5(world.c))" (Option.get (U.content w "hello")));
  t "build: early cutoff" (fun () ->
    let text = "foo.o: config.h\n\tcc\nconfig.h: config.in\n\tgen\n" in
    let w = U.world ~cutoff:[ "config.h" ] [ "config.in" ] in
    words "first" [ "config.h"; "foo.o" ] (U.build w (U.mkfile text) "foo.o");
    (* config.in is touched, not changed: the header comes out the same *)
    Hashtbl.replace w.files "config.in" (U.tick w, "config.in");
    words "config.h regenerated, foo.o not" [ "config.h" ] (U.build w (U.mkfile text) "foo.o"));
  t "build: -n prints, and makes nothing" (fun () ->
    let w = U.world [ "hello.c"; "world.c" ] in
    let _ = U.build ~flags:{ U.flags with dry = true } w (U.mkfile hello) "hello" in
    str "printed" "5c hello.c\n5c world.c\n5l\n" w.out;
    boolean "nothing made" false (Hashtbl.mem w.files "hello"));
]

(*****************************************************************************)
(* Archive.mli *)
(*****************************************************************************)

(* an archive with members a.o, dated 1000, and b.o/ (System V's
 * trailing slash), dated 3000, both of 1 byte *)
let archive =
  let member name date = Printf.sprintf "%-16s%-12d%-6d%-6d%-8d%-10d`\n" name date 0 0 644 1 ^ "x\n" in
  "!<arch>\n" ^ member "a.o" 1000 ^ member "b.o/" 3000

let archive_tests = [
  t "archive: member dates" (fun () ->
    let a = Archive.create ~read:(fun _ -> Some archive) ~mtime:(fun _ -> 2000.) in
    Alcotest.(check (float 0.)) "a.o" 1000. (Archive.time a "lib.a(a.o)");
    Alcotest.(check (float 0.)) "b.o, after its archive: at - 1" 1999. (Archive.time a "lib.a(b.o)");
    Alcotest.(check (float 0.)) "missing" 0. (Archive.time a "lib.a(c.o)"));
  t "archive: touch" (fun () ->
    let s = Archive.touch_date ~now:1500. archive "a.o" in
    let a = Archive.create ~read:(fun _ -> Some s) ~mtime:(fun _ -> 2000.) in
    Alcotest.(check (float 0.)) "a.o touched" 1500. (Archive.time a "lib.a(a.o)"));
]

let tests = archive_tests @ word_tests @ pattern_tests @ mkfile_tests @ graph_tests @ outofdate_tests @ build_tests
