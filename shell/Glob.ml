(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Glob.mli *)

type piece = { text : string; literal : bool }
type word = piece list

let to_string (w : word) = String.concat "" (List.map (fun p -> p.text) w)

let special c = c = '*' || c = '?' || c = '['

let is_pattern (w : word) = List.exists (fun p -> (not p.literal) && String.exists special p.text) w

(* a pattern, one element per character *)
type elem = Char of char | Any | Star | Set of bool * (char * char) list   (* negated, ranges *)

let compile (w : word) : elem list =
  let out = ref [] in
  w |> List.iter (fun p ->
    if p.literal then String.iter (fun c -> out := Char c :: !out) p.text
    else begin
      let s = p.text and n = String.length p.text in
      let i = ref 0 in
      while !i < n do
        (match s.[!i] with
         | '*' -> out := Star :: !out
         | '?' -> out := Any :: !out
         | '[' -> (
             match String.index_from_opt s (!i + 1) ']' with
             | None -> out := Char '[' :: !out
             | Some j ->
                 let body = String.sub s (!i + 1) (j - !i - 1) in
                 let neg = body <> "" && body.[0] = '~' in
                 let body = if neg then String.sub body 1 (String.length body - 1) else body in
                 let rec ranges k =
                   if k >= String.length body then []
                   else if k + 2 < String.length body && body.[k + 1] = '-' then
                     (body.[k], body.[k + 2]) :: ranges (k + 3)
                   else (body.[k], body.[k]) :: ranges (k + 1)
                 in
                 out := Set (neg, ranges 0) :: !out;
                 i := j)
         | c -> out := Char c :: !out);
        incr i
      done
    end);
  List.rev !out

let rec match_elems (pat : elem list) (s : string) (i : int) : bool =
  let n = String.length s in
  match pat with
  | [] -> i = n
  | Star :: rest ->
      let rec try_from k = match_elems rest s k || (k < n && try_from (k + 1)) in
      try_from i
  | Any :: rest -> i < n && match_elems rest s (i + 1)
  | Char c :: rest -> i < n && s.[i] = c && match_elems rest s (i + 1)
  | Set (neg, rs) :: rest ->
      i < n
      && List.exists (fun (a, b) -> a <= s.[i] && s.[i] <= b) rs <> neg
      && match_elems rest s (i + 1)

let matches (w : word) (s : string) = match_elems (compile w) s 0

(* split a pattern at its /s, into its path components *)
let components (pat : elem list) : elem list list =
  let rec go cur acc = function
    | [] -> List.rev (List.rev cur :: acc)
    | Char '/' :: rest -> go [] (List.rev cur :: acc) rest
    | e :: rest -> go (e :: cur) acc rest
  in
  go [] [] pat

let files ~(readdir : string -> string list option) ~(exists : string -> bool) (w : word) :
    string list =
  if not (is_pattern w) then [ to_string w ]
  else
    let join dir name = if dir = "" then name else if dir = "/" then "/" ^ name else dir ^ "/" ^ name in
    (* a component with no meta character: its text *)
    let rec literal = function
      | [] -> Some ""
      | Char c :: rest -> Option.map (fun s -> String.make 1 c ^ s) (literal rest)
      | (Any | Star | Set _) :: _ -> None
    in
    (* each directory reached so far, component by component *)
    let rec walk dirs = function
      | [] -> dirs
      | [] :: rest -> walk (List.map (fun d -> if d = "" then "/" else d ^ "/") dirs) rest
      | comp :: rest ->
          let next =
            match literal comp with
            | Some name -> List.map (fun d -> join d name) dirs
            | None ->
                dirs |> List.concat_map (fun d ->
                  match readdir d with
                  | None -> []
                  | Some names ->
                      List.filter (fun name -> match_elems comp name 0) (List.sort compare names)
                      |> List.map (join d))
          in
          walk next rest
    in
    let found =
      match components (compile w) with
      | [] :: rest -> walk [ "/" ] rest   (* an absolute path *)
      | comps -> walk [ "" ] comps
    in
    (* a literal component after a pattern was only appended *)
    let found = List.filter exists found in
    if found = [] then [ to_string w ] else found
