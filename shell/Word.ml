(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Word.mli *)

exception Error of string

type ctx = {
  var : string -> string list;
  backquote : string -> Ast.cmd -> string;
  pipefd : bool -> Ast.cmd -> string;
}

let lit s : Glob.word = [ { Glob.text = s; literal = true } ]

let split (seps : string) (s : string) : string list =
  let words = ref [] and b = Buffer.create 16 in
  let flush () = if Buffer.length b > 0 then (words := Buffer.contents b :: !words; Buffer.clear b) in
  String.iter (fun c -> if String.contains seps c then flush () else Buffer.add_char b c) s;
  flush ();
  List.rev !words

let is_number s = s <> "" && String.for_all (fun c -> '0' <= c && c <= '9') s

(* $x(n), $x(n-), $x(n-m) (exec.c's subwords) *)
let subscript (v : string list) (idx : string) : string list =
  let len = List.length v in
  let num s = if is_number s then Some (int_of_string s) else None in
  let from, count =
    match String.index_opt idx '-' with
    | None -> num idx, Some 0
    | Some i ->
        let n = num (String.sub idx 0 i) and rest = String.sub idx (i + 1) (String.length idx - i - 1) in
        n, (if rest = "" then Option.map (fun n -> len - n) n
            else match n, num rest with Some n, Some m -> Some (m - n) | _ -> None)
  in
  match from, count with
  | Some n, Some m when n >= 1 && n <= len && m >= 0 ->
      let m = min m (len - n) in
      List.filteri (fun i _ -> i >= n - 1 && i <= n - 1 + m) v
  | _ -> []

let rec expand (ctx : ctx) (w : Ast.word) : Glob.word list =
  match w with
  | Ast.Word (s, q) -> [ [ { Glob.text = s; literal = q } ] ]
  | Ast.Dollar w -> List.map lit (value ctx w)
  | Ast.Count w ->
      let name = singleton ctx w in
      let n =
        if is_number name && name <> "0" then
          let n = int_of_string name in if n <= List.length (ctx.var "*") then 1 else 0
        else List.length (ctx.var name)
      in
      [ lit (string_of_int n) ]
  | Ast.Join w -> [ lit (String.concat " " (value ctx w)) ]
  | Ast.Sub (w, idx) ->
      let v = ctx.var (singleton ctx w) in
      List.concat_map (fun i -> List.map lit (subscript v (Glob.to_string i)))
        (List.concat_map (expand ctx) idx)
  | Ast.Paren ws -> List.concat_map (expand ctx) ws
  | Ast.Concat (a, b) -> (
      let l = expand ctx a and r = expand ctx b in
      match l, r with
      | [], [] -> []
      | [], _ | _, [] -> raise (Error "null list in concatenation")
      | [ x ], _ -> List.map (fun y -> x @ y) r
      | _, [ y ] -> List.map (fun x -> x @ y) l
      | _ when List.length l = List.length r -> List.map2 ( @ ) l r
      | _ -> raise (Error "mismatched list lengths in concatenation"))
  | Ast.Backquote (sep, c) ->
      let seps =
        match sep with
        | None -> String.concat "" (ctx.var "ifs")
        | Some w -> String.concat "" (List.map Glob.to_string (expand ctx w))
      in
      List.map lit (split seps (ctx.backquote seps c))
  | Ast.Pipefd (read, c) -> [ lit (ctx.pipefd read c) ]

(* $name: a variable, or $n, the nth argument *)
and value ctx (w : Ast.word) : string list =
  let name = singleton ctx w in
  if is_number name && name <> "0" then
    let n = int_of_string name in
    match List.nth_opt (ctx.var "*") (n - 1) with Some v -> [ v ] | None -> []
  else ctx.var name

and singleton ctx (w : Ast.word) : string =
  match expand ctx w with
  | [ x ] -> Glob.to_string x
  | _ -> raise (Error "variable name not singleton!")
