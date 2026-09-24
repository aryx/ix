(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Flags.mli *)

exception Usage

let parse ~flags ~with_arg args =
  let rec go acc = function
    | "--" :: rest -> List.rev acc, rest
    | a :: rest when String.length a > 1 && a.[0] = '-' ->
        let rec letters i acc rest =
          if i >= String.length a then go acc rest
          else
            let c = a.[i] in
            if String.contains with_arg c then
              if i + 1 < String.length a then go ((c, String.sub a (i + 1) (String.length a - i - 1)) :: acc) rest
              else match rest with v :: rest -> go ((c, v) :: acc) rest | [] -> raise Usage
            else if String.contains flags c then letters (i + 1) ((c, "") :: acc) rest
            else raise Usage
        in
        letters 1 acc rest
    | rest -> List.rev acc, rest
  in
  go [] args

let has fl c = List.mem_assoc c fl
let get fl c = List.assoc_opt c fl
let all fl c = List.filter_map (fun (c', v) -> if c = c' then Some v else None) fl
