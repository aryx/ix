(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See CLI.mli *)

let usage = "Usage: chidb [-c COMMAND] [DATABASE]\n"

(* getopt's "c:vh", GNU's: options anywhere, -vv, -cCOMMAND *)
type args = { command : string option; verbosity : int; files : string list }

exception Bad_option of string   (* getopt's message *)

let parse_args prog argv =
  let rec go acc = function
    | [] -> { acc with files = List.rev acc.files }
    | "--" :: rest -> { acc with files = List.rev_append acc.files rest }
    | a :: rest when String.length a > 1 && a.[0] = '-' ->
        let rec letters acc i rest =
          if i >= String.length a then go acc rest
          else match a.[i] with
            | 'v' -> letters { acc with verbosity = acc.verbosity + 1 } (i + 1) rest
            | 'h' -> print_string usage; exit 0
            | 'c' ->
                if i + 1 < String.length a then go { acc with command = Some (String.sub a (i + 1) (String.length a - i - 1)) } rest
                else (match rest with
                  | c :: rest -> go { acc with command = Some c } rest
                  | [] -> raise (Bad_option (Printf.sprintf "%s: option requires an argument -- 'c'" prog)))
            | c -> raise (Bad_option (Printf.sprintf "%s: invalid option -- '%c'" prog c))
        in
        letters acc 1 rest
    | f :: rest -> go { acc with files = f :: acc.files } rest
  in
  go { command = None; verbosity = 0; files = [] } argv

let main (caps : < Shell.caps; Cap.argv; .. >) =
  let argv = Array.to_list (CapSys.argv caps) in
  match parse_args (List.hd argv) (List.tl argv) with
  | exception Bad_option m -> prerr_endline m; print_string "ERROR: Unknown option -?\n"; 255
  | args ->
      if args.verbosity > 0 then Logs.set_level (Some (if args.verbosity = 1 then Logs.Info else Logs.Debug));
      let t = Shell.create (caps :> Shell.caps) in
      if (match args.files with f :: _ -> not (Shell.open_db t f) | [] -> false) then 1
      else begin
        (match args.command with
         | Some c -> if c <> "" then Shell.handle t c
         | None ->
             let rec loop () =
               print_string "chidb> ";
               flush stdout;
               match In_channel.input_line stdin with
               | None -> print_string "\n"
               | Some line -> if line <> "" then Shell.handle t line; loop ()
             in
             loop ());
        flush stdout;
        Shell.close t;
        0
      end
