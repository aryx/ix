(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Lexer.mli *)

type token =
  | WORD of string * bool
  | DOLLAR | COUNT | JOIN
  | CARET | SUB
  | LPAREN | RPAREN | LBRACE | RBRACE
  | BACKQUOTE | EQUAL | SEMI | AMP | NEWLINE | EOF
  | ANDAND | OROR
  | PIPE of int * int
  | REDIR of Ast.rkind * int
  | HERE of int
  | DUP of int * int
  | CLOSE of int

exception Error of string

type t = {
  refill : bool -> string option;
  mutable buf : string;
  mutable pos : int;
  mutable eof : bool;
  mutable continued : bool;    (* inside a command: prompt 2 *)
  mutable lastword : bool;     (* the last token was a word: carets, subscripts *)
  mutable lastdol : bool;      (* the last token was $, $# or dollar-quote: a name follows *)
  mutable line : int;
  mutable raw : bool;          (* in a quote or a comment: no backslash-newline *)
  mutable heredocs : Ast.heredoc list;   (* to read after this line, reversed *)
}

let create ~refill = {
  refill; buf = ""; pos = 0; eof = false; continued = false;
  lastword = false; lastdol = false; line = 1; raw = false; heredocs = [];
}

let of_string s =
  let fed = ref false in
  create ~refill:(fun _ -> if !fed then None else (fed := true; Some s))

let line lx = lx.line
let new_command lx = lx.continued <- false
let add_heredoc lx h = lx.heredocs <- h :: lx.heredocs

let keywords = [ "for"; "in"; "while"; "if"; "not"; "switch"; "fn"; "~"; "!"; "@" ]
let is_keyword s = List.mem s keywords

let wordchr c = not (String.contains "\n \t#;&|^$=`'{}()<>" c)
let idchr c = c > ' ' && not (String.contains "!\"#$%&'()+,-./:;<=>?@[\\]^`{|}~" c)

(*****************************************************************************)
(* Characters *)
(*****************************************************************************)

(* input.c's getnext(): outside a quote or a comment, a backslash-newline
 * is a blank *)
let continues lx =
  (not lx.raw) && lx.pos + 1 < String.length lx.buf
  && lx.buf.[lx.pos] = '\\' && lx.buf.[lx.pos + 1] = '\n'

let rec peek lx : char option =
  if continues lx then Some ' '
  else if lx.pos < String.length lx.buf then Some lx.buf.[lx.pos]
  else if lx.eof then None
  else
    match lx.refill lx.continued with
    | None -> lx.eof <- true; None
    | Some s -> lx.continued <- true; lx.buf <- s; lx.pos <- 0; peek lx

let advance lx : char option =
  let c = peek lx in
  if continues lx then (lx.pos <- lx.pos + 2; lx.line <- lx.line + 1)
  else if c <> None then lx.pos <- lx.pos + 1;
  if c = Some '\n' then lx.line <- lx.line + 1;
  c

let next_is lx c = if peek lx = Some c then (ignore (advance lx); true) else false

let rec skip_white lx =
  match peek lx with
  | Some (' ' | '\t') -> ignore (advance lx); skip_white lx
  | Some '#' ->
      lx.raw <- true;
      let rec to_eol () = match peek lx with Some '\n' | None -> () | _ -> ignore (advance lx); to_eol () in
      to_eol ();
      lx.raw <- false
  | _ -> ()

let rec skip_newlines lx =
  skip_white lx;
  if peek lx = Some '\n' then (ignore (advance lx); skip_newlines lx)

let skip_line lx =
  lx.lastword <- false;
  lx.lastdol <- false;
  lx.heredocs <- [];
  let rec go () = match advance lx with Some '\n' | None -> () | _ -> go () in
  go ()

(* a here document's lines, up to the one that is its tag, read raw *)
let read_heredoc lx (h : Ast.heredoc) =
  let b = Buffer.create 80 in
  let rec lines () =
    let l = Buffer.create 80 in
    let rec chars () =
      match advance lx with
      | None -> false
      | Some '\n' -> true
      | Some c -> Buffer.add_char l c; chars ()
    in
    let more = chars () in
    if Buffer.contents l <> h.tag then begin
      if more || Buffer.length l > 0 then (Buffer.add_buffer b l; Buffer.add_char b '\n');
      if more then lines ()
    end
  in
  lines ();
  h.body <- Buffer.contents b

(*****************************************************************************)
(* Tokens *)
(*****************************************************************************)

(* after > < | : an optional [fd], [fd=] or [fd=fd] *)
let fds lx ~pipe (arrow : token) : token =
  if not (next_is lx '[') then arrow
  else
    let number () =
      let rec go n seen =
        match peek lx with
        | Some ('0' .. '9' as c) -> ignore (advance lx); go ((n * 10) + Char.code c - 48) true
        | _ -> if seen then n else raise (Error (if pipe then "pipe syntax" else "redirection syntax"))
      in
      go 0 false
    in
    let a = number () in
    let t =
      if next_is lx '=' then
        match peek lx with
        | Some '0' .. '9' ->
            let b = number () in
            if pipe then PIPE (a, b) else DUP (a, b)
        | _ -> if pipe then raise (Error "pipe syntax") else CLOSE a
      else match arrow with
        | PIPE _ -> PIPE (a, 0)
        | REDIR (k, _) -> REDIR (k, a)
        | HERE _ -> HERE a
        | t -> t
    in
    if not (next_is lx ']') then raise (Error (if pipe then "pipe syntax" else "redirection syntax"));
    t

let token lx : token =
  let lastword = lx.lastword in
  lx.lastword <- false;
  let d = if lastword then peek lx else None in
  match d with
  | Some '(' -> ignore (advance lx); SUB
  | Some c when wordchr c || c = '\'' || c = '`' || c = '$' || c = '"' -> CARET
  | _ -> (
      skip_white lx;
      let dol = lx.lastdol in
      lx.lastdol <- false;
      match advance lx with
      | None -> EOF
      | Some '\'' ->
          lx.raw <- true;
          let b = Buffer.create 16 in
          let rec go () =
            match advance lx with
            | None -> raise (Error "eof in quoted string")
            | Some '\'' when next_is lx '\'' -> Buffer.add_char b '\''; go ()
            | Some '\'' -> ()
            | Some c -> Buffer.add_char b c; go ()
          in
          go ();
          lx.raw <- false;
          lx.lastword <- true;
          WORD (Buffer.contents b, true)
      | Some '&' -> if next_is lx '&' then (skip_newlines lx; ANDAND) else AMP
      | Some '$' ->
          lx.lastdol <- true;
          if next_is lx '#' then COUNT else if next_is lx '"' then JOIN else DOLLAR
      | Some '|' ->
          if next_is lx '|' then (skip_newlines lx; OROR)
          else (let t = fds lx ~pipe:true (PIPE (1, 0)) in skip_newlines lx; t)
      | Some '>' -> fds lx ~pipe:false (if next_is lx '>' then REDIR (Ast.Append, 1) else REDIR (Ast.Write, 1))
      | Some '<' ->
          fds lx ~pipe:false
            (if next_is lx '<' then HERE 0 else if next_is lx '>' then REDIR (Ast.RdWr, 0)
             else REDIR (Ast.Read, 0))
      | Some '\n' ->
          (* the here documents of this line follow it *)
          let hs = List.rev lx.heredocs in
          lx.heredocs <- [];
          List.iter (read_heredoc lx) hs;
          NEWLINE
      | Some ';' -> SEMI
      | Some '^' -> CARET
      | Some '(' -> LPAREN
      | Some ')' -> RPAREN
      | Some '{' -> LBRACE
      | Some '}' -> RBRACE
      | Some '`' -> BACKQUOTE
      | Some '=' -> EQUAL
      | Some c when not (wordchr c) -> raise (Error (Printf.sprintf "unexpected %c" c))
      | Some c ->
          let b = Buffer.create 16 in
          Buffer.add_char b c;
          let ok c = if dol then idchr c else wordchr c in
          let rec go () =
            match peek lx with
            | Some c when ok c -> ignore (advance lx); Buffer.add_char b c; go ()
            | _ -> ()
          in
          go ();
          let s = Buffer.contents b in
          lx.lastword <- not (is_keyword s);
          WORD (s, false))

let show (t : token) : string =
  match t with
  | WORD (s, _) -> s
  | DOLLAR -> "$" | COUNT -> "$#" | JOIN -> "$\"" | CARET -> "^" | SUB -> "( [SUB]"
  | LPAREN -> "(" | RPAREN -> ")" | LBRACE -> "{" | RBRACE -> "}"
  | BACKQUOTE -> "`" | EQUAL -> "=" | SEMI -> ";" | AMP -> "&" | NEWLINE -> "\n" | EOF -> "EOF"
  | ANDAND -> "&&" | OROR -> "||"
  | PIPE _ -> "|" | REDIR _ -> "redirection" | HERE _ -> "<<" | DUP _ | CLOSE _ -> ">[]"
