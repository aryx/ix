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

type quoting = Rc | Sh

exception Error of string

let quoting_of_shell (shell : string list) : quoting =
  match shell with
  | cmd :: _
    when Filename.check_suffix cmd "rc" || Filename.check_suffix cmd "rcsh" ->
      Rc
  | _ -> Sh

let is_wordchar (c : char) : bool =
  c > ' ' && not (String.contains "!\"#$%&'()*+,-./:;<=>?@[\\]^`{|}~" c)

let is_blank (c : char) : bool = c = ' ' || c = '\t' || c = '\n'

(*****************************************************************************)
(* Quotes *)
(*****************************************************************************)

(* [unquote q s i buf]: s.[i] opens a quote (or is a backslash in sh);
 * add what it quotes to [buf] and return the index after it. An
 * unterminated quote runs to the end of the string. *)
let unquote (q : quoting) (s : string) (i : int) (buf : Buffer.t) : int =
  let n = String.length s in
  match q, s.[i] with
  | _, '\'' ->
      let rec go j =
        if j >= n then n
        else if s.[j] <> '\'' then (Buffer.add_char buf s.[j]; go (j + 1))
        else if q = Rc && j + 1 < n && s.[j + 1] = '\'' then
          (Buffer.add_char buf '\''; go (j + 2))
        else j + 1
      in
      go (i + 1)
  | Sh, '"' ->
      let rec go j =
        if j >= n then n
        else match s.[j] with
          | '"' -> j + 1
          | '\\' when j + 1 < n && String.contains "\"\\$`" s.[j + 1] ->
              Buffer.add_char buf s.[j + 1]; go (j + 2)
          | c -> Buffer.add_char buf c; go (j + 1)
      in
      go (i + 1)
  | Sh, '\\' when i + 1 < n -> Buffer.add_char buf s.[i + 1]; i + 2
  | _, c -> Buffer.add_char buf c; i + 1

let opens_quote (q : quoting) (c : char) : bool =
  c = '\'' || (q = Sh && (c = '"' || c = '\\'))

let find_unquoted (q : quoting) (s : string) ~(from : int) (chars : string) :
    int option =
  let n = String.length s in
  let rec go i in_braces =
    if i >= n then None
    else match s.[i] with
      | c when opens_quote q c -> go (unquote q s i (Buffer.create 0)) in_braces
      | '$' -> go (i + 1) (in_braces || (i + 1 < n && s.[i + 1] = '{'))
      | '}' when in_braces -> go (i + 1) false
      | c when String.contains chars c && not in_braces -> Some i
      | _ -> go (i + 1) in_braces
  in
  go from false

(*****************************************************************************)
(* Gluing *)
(*****************************************************************************)

(* A word being built is a list of words, reversed, whose head is still
 * open: [glue acc vs] appends the list [vs], its first word joining
 * the open one (the "ends, not distributed" rule of the .mli). *)
let glue (acc : string list) (vs : string list) : string list =
  match acc, vs with
  | _, [] -> acc
  | [], _ -> List.rev vs
  | last :: rest, v :: vs' -> List.rev_append vs' ((last ^ v) :: rest)

let name_at (s : string) (i : int) : string =
  let j = ref i in
  while !j < String.length s && is_wordchar s.[!j] do incr j done;
  String.sub s i (!j - i)

(*****************************************************************************)
(* Main algorithm *)
(*****************************************************************************)

let rec split (q : quoting) ~(lookup : string -> string list option)
    (s : string) : string list =
  let n = String.length s in
  let words = ref [] in
  let i = ref 0 in
  while !i < n do
    while !i < n && is_blank s.[!i] do incr i done;
    if !i < n then begin
      (* one blank-separated unit, which may expand to several words *)
      let acc = ref [] and buf = Buffer.create 16 in
      let flush () =
        if Buffer.length buf > 0 then begin
          acc := glue !acc [Buffer.contents buf];
          Buffer.clear buf
        end
      in
      while !i < n && not (is_blank s.[!i]) do
        match s.[!i] with
        | c when opens_quote q c -> i := unquote q s !i buf
        | '$' -> flush (); let vs, j = var q ~lookup s !i in acc := glue !acc vs; i := j
        | c -> Buffer.add_char buf c; incr i
      done;
      flush ();
      words := List.rev_append (List.rev !acc) !words
    end
  done;
  List.filter (fun w -> w <> "") (List.rev !words)

(* s.[i] is a '$': the value it refers to, and the index after it *)
and var q ~lookup (s : string) (i : int) : string list * int =
  let value name =
    match lookup name with None -> [] | Some vs -> List.filter (( <> ) "") vs
  in
  let braced = i + 1 < String.length s && s.[i + 1] = '{' in
  let start = if braced then i + 2 else i + 1 in
  let name = name_at s start in
  if name = "" then raise (Error (Printf.sprintf "missing variable name <%s>" s));
  let after = start + String.length name in
  if not braced then value name, after
  else if after < String.length s && s.[after] = '}' then value name, after + 1
  else if after < String.length s && s.[after] = ':' then
    match find_unquoted q s ~from:(after + 1) "}" with
    | None -> raise (Error (Printf.sprintf "missing '}': %s" s))
    | Some close ->
        let spec = String.sub s (after + 1) (close - after - 1) in
        let result =
          match value name with
          | [] -> [name]
          | vs -> List.concat_map (subst q ~lookup spec) vs
        in
        result, close + 1
  else raise (Error (Printf.sprintf "bad variable name <%s>" name))

(* ${name:A%B=C%D} applied to one word [w] of $name; each of A, B, C, D
 * is itself split into words, as in the original (varsub.c's subsub) *)
and subst q ~lookup (spec : string) (w : string) : string list =
  let n = String.length spec in
  let is_pct i = i < n && (spec.[i] = '%' || spec.[i] = '&') in
  let extract from chars =
    match find_unquoted q spec ~from chars with
    | Some j -> j, split q ~lookup (String.sub spec from (j - from))
    | None -> n, split q ~lookup (String.sub spec from (n - from))
  in
  let cp, a = extract 0 "=%&" in
  let cp, b = if is_pct cp then extract (cp + 1) "=" else cp, [] in
  let has_c = cp < n && spec.[cp] = '=' in
  let cp, c = if has_c then extract (cp + 1) "&%" else cp, [] in
  let pct = is_pct cp in
  let d =
    if pct then split q ~lookup (String.sub spec (cp + 1) (n - cp - 1))
    else if cp < n then split q ~lookup (String.sub spec cp (n - cp))
    else []
  in
  let len = String.length w in
  let prefix =
    match a with
    | [] -> Some 0
    | _ ->
        List.find_opt (fun p -> String.length p <= len && String.sub w 0 (String.length p) = p) a
        |> Option.map String.length
  in
  let stem =
    match prefix with
    | None -> None
    | Some na -> (
        let rest = len - na in
        match b with
        | [] -> Some (String.sub w na rest)
        | _ ->
            List.find_opt (fun suf ->
                let ns = String.length suf in
                ns <= rest && String.sub w (len - ns) ns = suf) b
            |> Option.map (fun suf -> String.sub w na (rest - String.length suf)))
  in
  match stem with
  | None -> [w]
  | Some stem ->
      let acc = List.rev c in
      let acc = if pct && stem <> "" then glue acc [stem] else acc in
      let acc = glue acc d in
      if acc = [] && not has_c then [w] else List.rev acc
