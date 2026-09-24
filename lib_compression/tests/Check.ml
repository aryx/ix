(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The libraries against Python's (check.py): sha1, inflate or deflate
 * standard input to standard output. *)

let () =
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  let s = In_channel.input_all stdin in
  match Sys.argv with
  | [| _; "sha1" |] -> print_string (Sha1.to_hex (Sha1.string s))
  | [| _; "deflate" |] -> print_string (Zlib.deflate s)
  | [| _; "inflate" |] ->
      (* the stream, then what follows it, as a pack's next object *)
      let data, stop = Zlib.inflate s in
      print_string data;
      prerr_string (string_of_int (String.length s - stop))
  | _ -> prerr_endline "usage: Check sha1|deflate|inflate"; exit 2
