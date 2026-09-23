(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The worked examples of editor/'s .mli files, checked. *)
open Ix_ed

let t name f = Testo.create name (fun () -> f (); Testo.Promise.return ())
let int = Alcotest.(check int)
let spans = Alcotest.(check (option (list (pair int int))))

(* the whole match and the first groups *)
let exec ?(groups = 0) p s = Option.map (fun a -> Array.to_list (Array.sub a 0 (groups + 1))) (Regex.exec (Regex.compile p) s 0)

let regex_tests = [
  t "regex: leftmost-longest" (fun () ->
    spans "o|on" (Some [ (0, 2) ]) (exec "o|on" "one");
    spans "(o|on)(e|ne)*" (Some [ (0, 3); (0, 1); (1, 3) ]) (exec ~groups:2 "(o|on)(e|ne)*" "one");
    spans "(a*)(a*)" (Some [ (0, 3); (0, 3); (3, 3) ]) (exec ~groups:2 "(a*)(a*)" "aaa");
    spans "no match" None (exec "x" "abc"));
  t "regex: libregexp's thread order shows" (fun () ->
    (* the list overflows; ed takes the empty match found first *)
    spans "((x?)?)*" (Some [ (0, 0) ]) (exec "((x?)?)*" "xxb");
    spans "(x?)*" (Some [ (0, 2) ]) (exec "(x?)*" "xxb"));
  t "regex: x*+ is (x+)*" (fun () -> spans "b?+?" (Some [ (0, 0) ]) (exec "b?+?" "ba"));
  t "regex: utf-8, . takes a character" (fun () -> spans "h." (Some [ (0, 3) ]) (exec "h." "h\xc3\xa9llo"));
  t "regex: errors" (fun () ->
    List.iter (fun p ->
      match Regex.compile p with
      | _ -> Alcotest.fail ("no error: " ^ p)
      | exception Regex.Error _ -> ()) [ "()"; "a|"; "|a"; "*a"; "[]"; "("; ")"; "[a-]" ]);
]

let text_tests = [
  t "text: a mark follows its line" (fun () ->
    let tx = Text.create () in
    int "appended" 3 (Text.append tx 0 [ "x1"; "y"; "x2" ]);
    int "dol" 3 (Text.dol tx);
    int "dot" 3 (Text.dot tx);
    Text.mark tx 'a' 2;
    Text.move tx 1 2 3;
    Alcotest.(check (list string)) "moved" [ "x2"; "x1"; "y" ] (List.init 3 (fun i -> Text.text tx (i + 1)));
    Alcotest.(check (option int)) "'a" (Some 3) (Text.find_mark tx 'a');
    Text.delete tx 3 3;
    Alcotest.(check (option int)) "gone" None (Text.find_mark tx 'a'));
]

let input_tests = [
  t "input: pushback" (fun () ->
    let i = Input.of_string "1p\n" in
    int "1" (Char.code '1') (Input.getc i);
    Input.unget i (Char.code '1');
    int "1 again" (Char.code '1') (Input.getc i);
    int "p" (Char.code 'p') (Input.getc i);
    int "nl" Input.nl (Input.getc i);
    int "eof" Input.eof (Input.getc i));
]

let address_tests = [
  t "address: searches from dot, wrapping" (fun () ->
    let at s =
      let tx = Text.create () in
      ignore (Text.append tx 0 [ "x1"; "y"; "x2" ]);
      Text.set_dot tx 2;
      Address.address { Address.input = Input.of_string s; text = tx; pattern = None }
    in
    Alcotest.(check (option int)) "/x/" (Some 3) (at "/x/");
    Alcotest.(check (option int)) "?x?" (Some 1) (at "?x?");
    Alcotest.(check (option int)) "$-" (Some 2) (at "$-");
    Alcotest.(check (option int)) "none" None (at "p");
    match at "'a" with _ -> Alcotest.fail "'a" | exception Input.Error _ -> ());
]

let tests = regex_tests @ text_tests @ input_tests @ address_tests
