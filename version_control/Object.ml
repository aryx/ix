(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Object.mli *)

module Kind = struct
  type t = Blob | Tree | Commit | Tag
  let to_string = function Blob -> "blob" | Tree -> "tree" | Commit -> "commit" | Tag -> "tag"
  let of_string = function "blob" -> Some Blob | "tree" -> Some Tree | "commit" -> Some Commit | "tag" -> Some Tag | _ -> None
end

type mode = File | Exec | Dir | Link | Submodule
type entry = { mode : mode; name : string; hash : Hash.t }
type person = { id : string; time : int; tz : string }
type commit = { tree : Hash.t; parents : Hash.t list; author : person; committer : person; extra : string; msg : string }
type t = Blob of string | Tree of entry list | Commit of commit | Tag of string

exception Corrupt of string

let corrupt fmt = Printf.ksprintf (fun s -> raise (Corrupt s)) fmt

let kind : t -> Kind.t = function Blob _ -> Blob | Tree _ -> Tree | Commit _ -> Commit | Tag _ -> Tag

let mode_bits = function File -> 0o100644 | Exec -> 0o100755 | Dir -> 0o40000 | Link -> 0o120000 | Submodule -> 0o160000

(* git9 reads a mode by its bits: a directory bit, and the owner's x *)
let mode_of_bits m =
  if m = 0o160000 then Submodule
  else if m = 0o120000 then Link
  else if m land 0o40000 <> 0 then Dir
  else if m land 0o100 <> 0 then Exec
  else File

let compare_entries a b =
  let key e = if e.mode = Dir || e.mode = Submodule then e.name ^ "/" else e.name in
  String.compare (key a) (key b)

(*****************************************************************************)
(* Parsing *)
(*****************************************************************************)

let parse_tree s =
  let n = String.length s in
  let rec go pos acc =
    if pos = n then List.rev acc
    else
      let sp = try String.index_from s pos ' ' with Not_found -> corrupt "tree: no space" in
      let nul = try String.index_from s sp '\000' with Not_found -> corrupt "tree: no name end" in
      if nul + 21 > n then corrupt "tree: short hash";
      let mode = try int_of_string ("0o" ^ String.sub s pos (sp - pos)) with Failure _ -> corrupt "tree: bad mode" in
      let e = { mode = mode_of_bits mode; name = String.sub s (sp + 1) (nul - sp - 1); hash = Sha1.of_raw (String.sub s (nul + 1) 20) } in
      go (nul + 21) (e :: acc)
  in
  go 0 []

(* "Name <email> 1600000000 +0000": the last two words are the date *)
let parse_person line =
  match String.rindex_opt line ' ' with
  | None -> corrupt "bad person %S" line
  | Some i -> (
      let tz = String.sub line (i + 1) (String.length line - i - 1) in
      let rest = String.sub line 0 i in
      match String.rindex_opt rest ' ' with
      | None -> corrupt "bad person %S" line
      | Some j -> (
          match int_of_string_opt (String.sub rest (j + 1) (String.length rest - j - 1)) with
          | Some time -> { id = String.sub rest 0 j; time; tz }
          | None -> corrupt "bad date in %S" line))

(* the first position of [sub] in [s] *)
let find s sub =
  let n = String.length sub in
  let rec go i = if i + n > String.length s then None else if String.sub s i n = sub then Some i else go (i + 1) in
  go 0

let parse_commit s =
  let hdr, msg =
    match find s "\n\n" with
    | Some i -> String.sub s 0 (i + 1), String.sub s (i + 2) (String.length s - i - 2)
    | None -> s, "" in
  (* the header lines; a continuation line (a signature's) starts with a
   * space and stays with its header, in extra *)
  let lines = String.split_on_char '\n' hdr in
  let lines = match List.rev lines with "" :: rest -> List.rev rest | _ -> lines in
  let field name l = let p = name ^ " " in
    if String.starts_with ~prefix:p l then Some (String.sub l (String.length p) (String.length l - String.length p)) else None in
  let hash l = if Hash.is_hex l then Hash.of_hex l else corrupt "bad hash %S" l in
  match lines with
  | t :: rest -> (
      let tree = match field "tree" t with Some h -> hash h | None -> corrupt "commit: no tree" in
      let rec parents acc = function
        | l :: rest when field "parent" l <> None -> parents (hash (Option.get (field "parent" l)) :: acc) rest
        | rest -> List.rev acc, rest in
      let ps, rest = parents [] rest in
      match rest with
      | a :: c :: extra when field "author" a <> None && field "committer" c <> None ->
          { tree; parents = ps; author = parse_person (Option.get (field "author" a));
            committer = parse_person (Option.get (field "committer" c));
            extra = String.concat "" (List.map (fun l -> l ^ "\n") extra); msg }
      | _ -> corrupt "commit: no author or committer")
  | [] -> corrupt "empty commit"

let parse (k : Kind.t) s =
  match k with
  | Blob -> Blob s
  | Tree -> Tree (parse_tree s)
  | Commit -> Commit (parse_commit s)
  | Tag -> Tag s

(*****************************************************************************)
(* Printing *)
(*****************************************************************************)

let person p = Printf.sprintf "%s %d %s" p.id p.time p.tz

let print = function
  | Blob s | Tag s -> s
  | Tree es ->
      String.concat "" (List.map (fun e -> Printf.sprintf "%o %s\000%s" (mode_bits e.mode) e.name (Sha1.raw e.hash)) es)
  | Commit c ->
      String.concat ""
        ([ "tree " ^ Hash.to_hex c.tree ^ "\n" ]
         @ List.map (fun p -> "parent " ^ Hash.to_hex p ^ "\n") c.parents
         @ [ "author " ^ person c.author ^ "\n"; "committer " ^ person c.committer ^ "\n"; c.extra; "\n"; c.msg ])

let hash o = Hash.of_object (Kind.to_string (kind o)) (print o)

let local_time p =
  let tz = match int_of_string_opt p.tz with Some n -> n | None -> 0 in
  (* C's / and %, truncating: -0130 is -1 hour and -30 minutes *)
  p.time + (3600 * (tz / 100)) + (60 * (tz mod 100))

let message c =
  let n = String.length c.msg in
  let rec skip i = if i < n && (match c.msg.[i] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false) then skip (i + 1) else i in
  let i = skip 0 in
  String.sub c.msg i (n - i)
