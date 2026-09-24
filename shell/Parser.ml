(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Parser.mli *)
open Ast
module L = Lexer

exception Error of string

(* tokens read ahead of the parser (two, to tell <{ from < ) *)
type p = { lx : L.t; mutable ahead : L.token list; mutable last_if : bool }

let peek p = match p.ahead with t :: _ -> t | [] -> let t = L.token p.lx in p.ahead <- [ t ]; t
let next p = let t = peek p in p.ahead <- List.tl p.ahead; t
let unread p t = p.ahead <- t :: p.ahead
(* lex.c's yyerror names the token, unless it is a newline *)
let error p =
  match peek p with
  | L.NEWLINE -> raise (Error "syntax error")
  | t -> raise (Error (Printf.sprintf "token %s: syntax error" (Ast.quote (L.show t))))
let expect p t = if peek p = t then ignore (next p) else error p
let skipnl p =
  while peek p = L.NEWLINE do ignore (next p) done;
  if p.ahead = [] then L.skip_newlines p.lx

(* the keyword a command starts with, if its first word is one *)
let kw p : L.keyword option = match peek p with L.WORD (s, false) -> L.keyword_of s | _ -> None
let is_kw p k = kw p = Some k

(* can this token start a word? *)
let starts_word = function
  | L.WORD _ | L.DOLLAR | L.COUNT | L.JOIN | L.LPAREN | L.BACKQUOTE -> true
  | _ -> false

let is_redir = function L.REDIR _ -> true | _ -> false

(* can a word start here: a word's token, or <{ and >{ (rc's PIPEFD is a
 * comword) *)
(* old: <{ and >{ recognised apart, at the start of a command and among
 * its arguments, where they made a word without word's ^: <{true}^x was
 * a syntax error *)
let word_next p =
  starts_word (peek p)
  || match peek p with
     | L.REDIR (Open (Ast.Read, 0) | Open (Ast.Write, 1)) -> let t = next p in let brace = peek p = L.LBRACE in unread p t; brace
     | _ -> false

(*****************************************************************************)
(* Words *)
(*****************************************************************************)

let rec word p : word =
  let w = ref (comword p) in
  while peek p = L.CARET do ignore (next p); w := Concat (!w, comword p) done;
  !w

and comword p : word =
  match next p with
  | L.WORD (s, q) -> Word (s, q)
  | L.DOLLAR ->
      let v = comword p in
      if peek p = L.SUB then (ignore (next p); let ws = words p in expect p L.RPAREN; Sub (v, ws))
      else Dollar v
  | L.COUNT -> Count (comword p)
  | L.JOIN -> Join (comword p)
  | L.LPAREN -> let ws = words p in expect p L.RPAREN; Paren ws
  | L.BACKQUOTE ->
      if peek p = L.LBRACE then Backquote (None, brace_body p)
      else let sep = word p in Backquote (Some sep, brace_body p)
  | L.REDIR (Open (Ast.Read, 0)) when peek p = L.LBRACE -> Pipefd (Reads, brace_body p)
  | L.REDIR (Open (Ast.Write, 1)) when peek p = L.LBRACE -> Pipefd (Writes, brace_body p)
  | t -> unread p t; error p

and words p : word list =
  if word_next p then let w = word p in w :: words p else []

(*****************************************************************************)
(* Commands *)
(*****************************************************************************)

(* a redirection token, and its file for > < >> <> << *)
and redir p : redir =
  match next p with
  | L.REDIR (Open (k, fd)) -> Open (k, fd, word p)
  | L.REDIR (Here fd) -> (
      match next p with
      | L.WORD (tag, quoted) ->
          let h = { tag; expand = not quoted; body = "" } in
          L.add_heredoc p.lx h;
          Here (fd, h)
      | t -> unread p t; error p)
  | L.REDIR (Dup (a, b)) -> Dup (a, b)
  | L.REDIR (Close a) -> Close a
  | t -> unread p t; error p

and brace_body p : cmd =
  expect p L.LBRACE;
  let c = body p (( = ) L.RBRACE) in
  expect p L.RBRACE;
  c

(* commands separated by ; & and newlines, up to a token that [stop]s
 * them (not consumed); an empty command doesn't forget an `if` *)
and body p (stop : L.token -> bool) : cmd =
  let c = cmd p in
  (* code.c: an `if not if(...)` counts as an if, for the next `if not` *)
  if c <> Empty then p.last_if <- (match c with If _ | IfNot (If _) -> true | _ -> false);
  let t = peek p in
  if stop t then c
  else match t with
    | L.SEMI | L.NEWLINE -> ignore (next p); if stop (peek p) then c else Seq (c, body p stop)
    | L.AMP -> ignore (next p); if stop (peek p) then Async c else Seq (Async c, body p stop)
    | _ -> error p

and cmd p : cmd =
  let c = ref (bang p) in
  let rec go () =
    match peek p with
    | L.ANDAND -> ignore (next p); c := And (!c, bang p); go ()
    | L.OROR -> ignore (next p); c := Or (!c, bang p); go ()
    | _ -> ()
  in
  go ();
  !c

(* the prefixes ! @ and redirections, before [rest]: a pipeline in
 * bang, one command on the right of a | *)
and prefixed p ~(rest : p -> cmd) : cmd =
  let again () = prefixed p ~rest in
  if is_kw p `Bang then (ignore (next p); Not (again ()))
  else if is_kw p `At then (ignore (next p); Subshell (again ()))
  (* <{cmd} is a word, not a redirection *)
  else if is_redir (peek p) && not (word_next p) then (let r = redir p in Redirect (r, again ()))
  else rest p

and bang p : cmd = prefixed p ~rest:pipe

and pipe p : cmd = pipe_from p (unit p)

and pipe_from p (c : cmd) : cmd =
  match peek p with
  | L.PIPE (l, r) ->
      ignore (next p);
      pipe_from p (Pipe (l, r, c, prefixed p ~rest:unit))
  | _ -> c

and unit p : cmd =
  match kw p, peek p with
  | Some `If, _ ->
      ignore (next p);
      if is_kw p `Not then begin
        ignore (next p);
        if not p.last_if then raise (Error "`if not' does not follow `if(...)'");
        skipnl p;
        IfNot (cmd p)
      end else begin
        let c = paren p in
        skipnl p;
        let body = cmd p in
        If (c, body)
      end
  | Some `While, _ -> ignore (next p); let c = paren p in skipnl p; While (c, cmd p)
  | Some `For, _ ->
      ignore (next p);
      expect p L.LPAREN;
      let x = word p in
      let list = if is_kw p `In then (ignore (next p); Some (words p)) else None in
      expect p L.RPAREN;
      skipnl p;
      For (x, list, cmd p)
  | Some `Switch, _ ->
      ignore (next p);
      let w = word p in
      skipnl p;
      Switch (w, Brace (brace_body p))
  | Some `Fn, _ ->
      ignore (next p);
      let names = words p in
      if peek p = L.LBRACE then Fn (names, Some (Brace (brace_body p))) else Fn (names, None)
  | Some `Match, _ -> ignore (next p); let w = word p in Match (w, words p)
  | _, L.LBRACE ->
      let c = Brace (brace_body p) in
      (* an epilog: redirections after the brace apply to it *)
      let rs = ref [] in
      while is_redir (peek p) do rs := redir p :: !rs done;
      List.fold_left (fun c r -> Redirect (r, c)) c !rs
  | _ when word_next p -> simple_from p (word p)
  | _ -> Empty

and paren p : cmd =
  expect p L.LPAREN;
  let c = body p (( = ) L.RPAREN) in
  expect p L.RPAREN;
  c

(* a simple command, or an assignment, from its first word *)
and simple_from p (first : word) : cmd =
  if peek p = L.EQUAL then begin
    ignore (next p);
    let v = word p in
    if word_next p || is_redir (peek p) || peek p = L.LBRACE then Assign (first, v, Some (bang p))
    else Assign (first, v, None)
  end else begin
    let args = ref [ first ] and redirs = ref [] in
    let rec go () =
      if word_next p then (args := word p :: !args; go ())
      else if is_redir (peek p) then (redirs := redir p :: !redirs; go ())
    in
    go ();
    (* the first redirection is the outermost: applied first *)
    List.fold_left (fun c r -> Redirect (r, c)) (Simple (List.rev !args)) !redirs
  end

(*****************************************************************************)
(* Entry points *)
(*****************************************************************************)

let parsers : (L.t * p) list ref = ref []

(* one parser per lexer, so that `if not` sees the previous line's `if` *)
let parser_of (lx : L.t) : p =
  match List.assq_opt lx !parsers with
  | Some p -> p
  | None -> let p = { lx; ahead = []; last_if = false } in parsers := (lx, p) :: !parsers; p

let line (lx : L.t) : cmd option =
  let p = parser_of lx in
  L.new_command lx;
  let rec go () =
    match peek p with
    | L.EOF -> None
    | L.NEWLINE -> ignore (next p); L.new_command lx; go ()
    | _ ->
        let c =
          try body p (fun t -> t = L.NEWLINE || t = L.EOF) with
          | (Error _ | L.Error _) as e ->
              if not (List.mem L.NEWLINE p.ahead || List.mem L.EOF p.ahead) then L.skip_line lx;
              p.ahead <- [];
              raise e
        in
        (match peek p with L.NEWLINE -> ignore (next p) | L.EOF -> () | _ -> error p);
        Some c
  in
  go ()

let parse_string (s : string) : cmd =
  let lx = L.of_string s in
  let rec all acc =
    match line lx with None -> List.rev acc | Some c -> all (c :: acc)
  in
  match all [] with [] -> Empty | c :: cs -> List.fold_left (fun a b -> Seq (a, b)) c cs
