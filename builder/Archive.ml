(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Archive.mli *)

let magic = "!<arch>\n"
let header = 60

let is_archive (s : string) = String.length s >= 8 && String.sub s 0 8 = magic

let split (name : string) : (string * string) option =
  match String.index_opt name '(' with
  | None -> None
  | Some i ->
      let rest = String.sub name (i + 1) (String.length name - i - 1) in
      let member = match String.index_opt rest ')' with Some j -> String.sub rest 0 j | None -> rest in
      Some (String.sub name 0 i, member)

(* each member's name, the offset of its header, and its date *)
let members (s : string) : (string * int * float) list =
  let n = String.length s in
  let rec go off acc =
    if off + header > n then List.rev acc
    else
      let field o len = String.trim (String.sub s (off + o) len) in
      let name = field 0 16 in
      let name =
        if String.length name > 1 && name.[String.length name - 1] = '/'
        then String.sub name 0 (String.length name - 1) else name
      in
      let date = Option.value (float_of_string_opt (field 16 12)) ~default:0. in
      let size = Option.value (int_of_string_opt (field 48 10)) ~default:0 in
      go (off + header + size + (size land 1)) ((name, off, date) :: acc)
  in
  if is_archive s then go 8 [] else []

type t = {
  read : string -> string option;
  mtime : string -> float;
  cache : (string, float * (string * float) list) Hashtbl.t;  (* archive -> its time, dates *)
}

let create ~read ~mtime = { read; mtime; cache = Hashtbl.create 7 }

let time ?(force = false) t (name : string) : float =
  match split name with
  | None -> 0.
  | Some (ar, member) ->
      let at = t.mtime ar in
      let dates =
        match Hashtbl.find_opt t.cache ar with
        | Some (seen, dates) when not force && at <= seen -> dates
        | _ ->
            let dates =
              match t.read ar with
              | None -> []
              | Some s ->
                  members s |> List.map (fun (m, _, d) ->
                    (* archive.c's two corrections *)
                    m, (if d >= at then at -. 1. else if d = 0. then 1. else d))
            in
            Hashtbl.replace t.cache ar (at, dates);
            dates
      in
      (* a long name is truncated to the 16 characters of the header *)
      let member = if String.length member > 16 then String.sub member 0 16 else member in
      Option.value (List.assoc_opt member dates) ~default:0.

let touch_date ~now (s : string) (member : string) : string =
  match List.find_opt (fun (m, _, _) -> m = member) (members s) with
  | None -> s
  | Some (_, off, _) ->
      let b = Bytes.of_string s in
      Bytes.blit_string (Printf.sprintf "%-12.0f" now) 0 b (off + 16) 12;
      Bytes.to_string b
