(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Dbmfile.mli *)

type db = No_dbfile | Use of string | Create of string
type program = Instructions of Dbm.row list | Sql of string list
type expected = Unspecified | Null | Integer of int option | String of string option | Binary
type t = { db : db; program : program; results : string list; registers : (int * expected) list }

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\011' || c = '\012'

let tokenize s =
  let n = String.length s in
  let rec skip i = if i < n && is_space s.[i] then skip (i + 1) else i in
  let rec go i acc =
    let i = skip i in
    if i >= n then List.rev acc
    else if s.[i] = '"' then
      let j = match String.index_from_opt s (i + 1) '"' with Some j -> j | None -> n in
      go (j + 1) (String.sub s (i + 1) (j - i - 1) :: acc)
    else
      let rec word j = if j < n && not (is_space s.[j]) then word (j + 1) else j in
      let j = word i in
      go j (String.sub s i (j - i) :: acc)
  in
  go 0 []

(* C's atoi: a sign, digits, 0 if none *)
let atoi s =
  let n = String.length s in
  let rec skip i = if i < n && is_space s.[i] then skip (i + 1) else i in
  let i = skip 0 in
  let neg, i = if i < n && (s.[i] = '-' || s.[i] = '+') then s.[i] = '-', i + 1 else false, i in
  let rec digits i v = if i < n && s.[i] >= '0' && s.[i] <= '9' then digits (i + 1) ((v * 10) + Char.code s.[i] - 48) else v in
  let v = Int32.to_int (Int32.of_int (digits i 0)) in
  if neg then - v else v

(* chidb's read_rr: the tokens outside quotes each followed by one space *)
let normalize_row line =
  let b = Buffer.create (String.length line) in
  let skip = ref true and quoted = ref false in
  String.iter (fun c ->
    if c <> ' ' && !skip then skip := false;
    if c = '"' then quoted := not !quoted;
    if not !skip then Buffer.add_char b c;
    if c = ' ' && not !quoted then skip := true) line;
  let s = Buffer.contents b in
  if s <> "" && s.[String.length s - 1] = ' ' then String.sub s 0 (String.length s - 1) else s

let is_sql line =
  let t = String.trim line in
  List.exists (fun k -> String.length t >= 6 && String.uppercase_ascii (String.sub t 0 6) = k) [ "SELECT"; "INSERT"; "UPDATE"; "DELETE"; "CREATE" ]

let parse text =
  let lines = String.split_on_char '\n' text |> List.map (fun l ->
    let n = String.length l in
    let rec skip i = if i < n && is_space l.[i] then skip (i + 1) else i in
    let i = skip 0 in
    let l = String.sub l i (n - i) in
    if l <> "" && l.[String.length l - 1] = '\r' then String.sub l 0 (String.length l - 1) else l)
    |> List.filter (fun l -> l <> "" && l.[0] <> '#') in
  (* the four sections, split at the %% lines *)
  let sections = List.fold_left (fun acc l ->
    if String.length l >= 2 && String.sub l 0 2 = "%%" then [] :: acc
    else match acc with s :: rest -> (l :: s) :: rest | [] -> [ [ l ] ]) [ [] ] lines
    |> List.rev_map List.rev in
  let section i = match List.nth_opt sections i with Some s -> s | None -> [] in
  let fail l = failwith ("dbmf: " ^ l) in
  let db = match section 0 with
    | [ l ] -> (match tokenize l with
        | [ "NO"; _ ] -> No_dbfile
        | [ "USE"; f ] -> Use f
        | [ "CREATE"; f ] -> Create f
        | _ -> fail l)
    | _ -> No_dbfile in
  let program = match section 1 with
    | first :: _ as ls when is_sql first -> Sql ls
    | ls -> Instructions (List.map (fun l -> match tokenize l with
        | [ opcode; p1; p2; p3; p4 ] ->
            let p s = if s <> "" && s.[0] = '_' then 0 else atoi s in
            { Dbm.opcode; p1 = p p1; p2 = p p2; p3 = p p3; p4 = (if p4 <> "" && p4.[0] = '_' then None else Some p4) }
        | _ -> fail l) ls) in
  let registers = List.map (fun l ->
    match tokenize l with
    | r :: typ :: v when String.length r > 2 && r.[0] = 'R' && r.[1] = '_' ->
        let n = atoi (String.sub r 2 (String.length r - 2)) in
        let v = match v with [ v ] -> Some v | _ -> None in
        (n, match typ with
          | "unspecified" -> Unspecified
          | "null" -> Null
          | "integer" -> Integer (Option.map atoi v)
          | "string" -> String v
          | "binary" -> Binary
          | _ -> fail l)
    | _ -> fail l) (section 3) in
  { db; program; results = List.map normalize_row (section 2); registers }

let show_row vs = String.concat " " (List.filter_map (fun v -> match v with Dbm.Unspecified -> None | _ -> Some (Dbm.show_value v)) vs)
