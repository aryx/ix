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
 * "ADDR\tTEXT" lines, for decode_check.py. *)
open Ix_machine

let () =
  let words = In_channel.with_open_text Sys.argv.(1) In_channel.input_all |> String.split_on_char '\n' |> List.filter (( <> ) "") in
  List.iteri (fun i w ->
    let addr = 4 * i in
    Printf.printf "%x\t%s\n" addr (Arm32.print ~addr (Arm32.decode (int_of_string ("0x" ^ w))))) words
