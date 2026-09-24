(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The decoder's printing of a file of words (8 hex digits a line),
 * word i at address 4*i, as objdump -D -b binary lays them out:
 * "ADDR\tTEXT" lines, for decode_check.py; arm64's with -64. *)
open Ix_machine

let () =
  let a64 = Sys.argv.(1) = "-64" in
  let file = Sys.argv.(Array.length Sys.argv - 1) in
  let words = In_channel.with_open_text file In_channel.input_all |> String.split_on_char '\n' |> List.filter (( <> ) "") in
  List.iteri (fun i w ->
    let addr = 4 * i in
    let w = int_of_string ("0x" ^ w) in
    let text = if a64 then Arm64.print ~addr (Arm64.decode w) else Arm32.print ~addr (Arm32.decode w) in
    Printf.printf "%x\t%s\n" addr text) words
