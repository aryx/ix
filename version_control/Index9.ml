(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Index9.mli *)

type state = Added | Removed | Tracked | Untracked
type qid = Noqid | Qid of { ino : int; mtime : int; size : int }
type entry = { state : state; qid : qid; mode : int; path : string; order : int }

exception Corrupt of int

let letter = function Added -> 'A' | Removed -> 'R' | Tracked -> 'T' | Untracked -> 'U'

(* git9 reads a state by its first letter, whatever it is *)
let state_of_letter = function 'A' -> Added | 'R' -> Removed | 'U' -> Untracked | _ -> Tracked

let print_qid = function
  | Noqid -> "NOQID"
  | Qid { ino; mtime; size } -> Printf.sprintf "%x.%d.%x" ino mtime size

let parse_qid s =
  if s = "NOQID" then Some Noqid
  else match String.split_on_char '.' s with
    | [ a; b; c ] -> (
        match int_of_string_opt ("0x" ^ a), int_of_string_opt b, int_of_string_opt ("0x" ^ c) with
        | Some ino, Some mtime, Some size -> Some (Qid { ino; mtime; size })
        | _ -> None)
    | _ -> None

let qid_of_stats (st : Unix.stats) = Qid { ino = st.st_ino; mtime = int_of_float (st.st_mtime *. 1e6); size = st.st_size }

let path git = Fpath.(git / "INDEX9")

let read caps git =
  match Files.read_opt caps (path git) with
  | None -> None
  | Some s ->
      let lines = String.split_on_char '\n' s in
      let entries = List.concat (List.mapi (fun i ln ->
        if ln = "" then []
        else
          (* getfields on blanks, empty fields dropped: four of them *)
          match List.filter (fun f -> f <> "") (String.split_on_char ' ' (String.map (fun c -> if c = '\t' then ' ' else c) ln)) with
          | [ st; q; mode; p ] -> (
              match parse_qid q with
              | Some qid ->
                  let mode = match int_of_string_opt ("0o" ^ mode) with Some m -> m | None -> 0 in
                  [ { state = state_of_letter st.[0]; qid; mode; path = Repo.cleanname p; order = i } ]
              | None -> raise (Corrupt (i + 1)))
          | _ -> raise (Corrupt (i + 1))) lines) in
      Some (List.stable_sort (fun a b -> compare a.path b.path) entries)

let line e = Printf.sprintf "%c %s %o %s\n" (letter e.state) (print_qid e.qid) e.mode e.path

let write caps git entries =
  let rec last = function
    | a :: (b :: _ as rest) when a.path = b.path -> last rest
    | a :: rest -> a :: last rest
    | [] -> [] in
  let s = String.concat "" (List.map line (List.filter (fun e -> e.state <> Untracked) (last entries))) in
  let tmp = Fpath.(git / "INDEX9.new") in
  Files.write caps tmp s;
  Unix.rename (Fpath.to_string tmp) (Fpath.to_string (path git))

let append caps git lines =
  let old = Option.value (Files.read_opt caps (path git)) ~default:"" in
  Files.write caps (path git) (old ^ String.concat "" (List.map (fun (st, p) -> Printf.sprintf "%c NOQID 0 %s\n" (letter st) p) lines))
