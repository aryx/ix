(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Sql.mli *)

(* the statements of a text, or None *)
let statements text =
  match Parser.main Lexer.token (Lexing.from_string text) with
  | queries -> Some queries
  | exception (Parsing.Parse_error | Failure _) -> None

let with_semicolon sql = if sql <> "" && sql.[String.length sql - 1] = ';' then sql else sql ^ ";"

let parse_quiet sql =
  match statements (with_semicolon sql) with
  | Some queries -> (match List.rev (List.filter_map fst queries) with stmt :: _ -> Some stmt | [] -> None)
  | None -> None

let parse (_ : < Cap.stderr; .. >) (sql : string) : Ast.t option =
  let text = with_semicolon sql in
  let fail () =
    Printf.eprintf "syntax error (line %d)\n" !Ast.line;
    Printf.eprintf "invalid sql: \"%s\"\n%!" text;
    None
  in
  match statements text with
  | Some queries -> (
      (* the last statement, and the last query's EXPLAIN flag *)
      let explain = snd (List.nth queries (List.length queries - 1)) in
      match List.rev (List.filter_map fst queries) with
      | stmt :: _ -> Some { Ast.stmt; explain; text }
      | [] -> fail ())
  | None -> fail ()
