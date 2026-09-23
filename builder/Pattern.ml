(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Pattern.mli *)

type t =
  | Literal of string
  | Percent of string * string
  | Amp of string * string
  | Regexp of string * Re.re

let split_at (s : string) (i : int) = String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1)

let of_target ~(regexp : bool) (s : string) : t =
  if regexp then Regexp (s, Re.compile (Re.whole_string (Re.Posix.re s)))
  else
    match String.index_opt s '%', String.index_opt s '&' with
    | None, None -> Literal s
    | Some i, Some j when j < i -> let a, b = split_at s j in Amp (a, b)
    | Some i, _ -> let a, b = split_at s i in Percent (a, b)
    | None, Some j -> let a, b = split_at s j in Amp (a, b)

let is_meta (p : t) : bool = match p with Literal _ -> false | _ -> true

let affix (a : string) (b : string) (name : string) : string option =
  let n = String.length name and na = String.length a and nb = String.length b in
  if na + nb <= n && String.sub name 0 na = a && String.sub name (n - nb) nb = b
  then Some (String.sub name na (n - na - nb))
  else None

let matches (p : t) (name : string) : string array option =
  match p with
  | Literal s -> if s = name then Some [||] else None
  | Percent (a, b) -> Option.map (fun stem -> [| stem |]) (affix a b name)
  | Amp (a, b) -> (
      match affix a b name with
      | Some stem when not (String.contains stem '/' || String.contains stem '.') ->
          Some [| stem |]
      | _ -> None)
  | Regexp (_, re) -> (
      match Re.exec_opt re name with
      | None -> None
      | Some g ->
          Some (Array.init (min 10 (Re.Group.nb_groups g)) (fun i ->
            Option.value (Re.Group.get_opt g i) ~default:"")))

let subst (p : t) (stems : string array) (s : string) : string =
  match p with
  | Literal _ -> s
  | Percent _ | Amp _ ->
      (* every % and & of a prerequisite is the stem (match.c's subst) *)
      String.concat stems.(0) (List.map (fun piece ->
        String.concat stems.(0) (String.split_on_char '&' piece))
        (String.split_on_char '%' s))
  | Regexp _ ->
      (* \n refers to group n, as in Plan 9's regsub *)
      let buf = Buffer.create (String.length s) in
      let n = String.length s in
      let rec go i =
        if i < n then
          if s.[i] = '\\' && i + 1 < n && s.[i + 1] >= '0' && s.[i + 1] <= '9' then begin
            let g = Char.code s.[i + 1] - Char.code '0' in
            if g < Array.length stems then Buffer.add_string buf stems.(g);
            go (i + 2)
          end else (Buffer.add_char buf s.[i]; go (i + 1))
      in
      go 0;
      Buffer.contents buf

let stem (p : t) (stems : string array) : string =
  match p with Percent _ | Amp _ -> stems.(0) | Literal _ | Regexp _ -> ""
