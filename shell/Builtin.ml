(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Builtin.mli *)

let status t s = Env.set_status (Eval.env t) s
let var t name = Env.get (Eval.env t) name

let cd t args =
  match args with
  | _ :: _ :: _ -> Eval.eprint "Usage: cd [directory]\n"; status t "usage"
  | _ ->
      let dir = match args with [ d ] -> d | _ -> (match var t "home" with h :: _ -> h | [] -> "/") in
      let tries =
        if dir <> "" && (dir.[0] = '/' || String.length dir > 1 && String.sub dir 0 2 = "./") then [ dir ]
        else match var t "cdpath" with [] -> [ dir ] | cdpath ->
          List.map (fun p -> if p = "" || p = "." then dir else Filename.concat p dir) cdpath
      in
      let rec go = function
        | [] -> ()
        | d :: rest -> (
            match CapUnix.chdir (Eval.caps t) d with
            | () -> status t ""
            | exception Unix.Unix_error (e, _, _) ->
                if rest = [] then begin
                  Eval.eprint (Printf.sprintf "Can't cd %s: %s\n" dir (Unix.error_message e));
                  status t "can't cd"
                end
                else go rest)
      in
      go tries

let exit_ t args = raise (Eval.Exit (match args with s :: _ -> s | [] -> Env.status (Eval.env t)))

(* the lines of a file, read as it is read: a terminal or a pipe one
 * byte at a time, so that the commands run get the rest *)
let refill_of_fd ~prompt (fd : Unix.file_descr) : bool -> string option =
  let byte = Bytes.create 1 in
  fun continued ->
    prompt continued;
    let b = Buffer.create 80 in
    let rec go () =
      match Unix.read fd byte 0 1 with
      | 0 -> if Buffer.length b = 0 then None else Some (Buffer.contents b)
      | _ ->
          Buffer.add_char b (Bytes.get byte 0);
          if Bytes.get byte 0 = '\n' then Some (Buffer.contents b) else go ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
    in
    go ()

let dot t args =
  let interactive, args = match args with "-i" :: rest -> true, rest | _ -> false, args in
  match args with
  | [] -> Eval.eprint "Usage: . [-i] file [arg ...]\n"; status t "usage"
  | file :: rest ->
      let found = if String.contains file '/' then Some file else Process.search ~path:(var t "path") file in
      (* 9base's words for it: file: rc (argv0): .: can't open: why *)
      let cant why =
        Eval.eprint (Printf.sprintf "%s: rc (%s): .: can't open: %s\n" file (Eval.argv0 t) why);
        raise (Eval.Error "")
      in
      match found with
      | None -> cant "No such file or directory"
      | Some path -> (
          match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
          | exception Unix.Unix_error (e, _, _) -> cant (Unix.error_message e)
          | fd ->
              let prompt continued =
                if interactive then
                  match var t "prompt" with
                  | p1 :: p2 :: _ -> Eval.eprint (if continued then p2 else p1)
                  | [ p1 ] -> if not continued then Eval.eprint p1
                  | [] -> ()
              in
              let lx =
                if (not interactive) && (Unix.fstat fd).Unix.st_kind = Unix.S_REG then begin
                  let ic = Unix.in_channel_of_descr fd in
                  let text = really_input_string ic (in_channel_length ic) in
                  close_in ic;
                  Lexer.of_string text
                end
                else Lexer.create ~refill:(refill_of_fd ~prompt fd)
              in
              let env = Eval.env t in
              Env.local env "*" rest (fun () ->
                Env.local env "0" [ file ] (fun () ->
                  Eval.source t ~name:(Some file) ~interactive lx)))

let eval t args =
  if args = [] then raise (Eval.Error "Usage: eval cmd ...");
  Eval.source t ~name:None ~interactive:false (Lexer.of_string (String.concat " " args ^ "\n"))

let exec t args =
  match args with
  | [] -> ()
  | _ -> Process.exec (Eval.caps t) ~path:(var t "path") ~env:(Env.export (Eval.env t)) args

(* shift more than there is: all of them, no error (builtins.c) *)
let shift t args =
  match args with
  | _ :: _ :: _ -> Eval.eprint "Usage: shift [n]\n"; status t "shift usage"
  | _ ->
      let n = match args with [ s ] -> Option.value (int_of_string_opt s) ~default:0 | _ -> 1 in
      Env.set (Eval.env t) "*" (List.filteri (fun i _ -> i >= n) (var t "*"));
      status t ""

let wait t args =
  let caps = Eval.caps t in
  match args with
  | [ pid ] -> (
      match int_of_string_opt pid with
      | Some p when List.mem p (Eval.background t) -> status t (Process.wait caps p); Eval.forget t p
      | _ -> status t "")
  | _ ->
      List.iter (fun p -> status t (Process.wait caps p); Eval.forget t p) (Eval.background t)

let whatis t args =
  let env = Eval.env t in
  let bad = ref false in
  args |> List.iter (fun name ->
    let v = Env.get env name and f = Env.fn env name in
    if v <> [] then
      Eval.print (Printf.sprintf "%s=%s\n" (Ast.quote name)
                    (match v with [ x ] -> Ast.quote x | l -> "(" ^ String.concat " " (List.map Ast.quote l) ^ ")"));
    (match f with
     | Some body -> Eval.print (Printf.sprintf "fn %s %s\n" (Ast.quote name) (Ast.to_string Ast.cmd body))
     | None -> ());
    if v = [] && f = None then
      if Hashtbl.mem Eval.builtins name || name = "builtin" then Eval.print ("builtin " ^ name ^ "\n")
      else match Process.search ~path:(Env.get env "path") name with
        | Some p -> Eval.print (p ^ "\n")
        | None -> Eval.eprint (name ^ ": not found\n"); bad := true);
  status t (if !bad then "not found" else "")

let flag t args =
  let env = Eval.env t in
  match args with
  | [ c ] when String.length c = 1 -> status t (if Env.flag env c.[0] then "" else "flag not set")
  | [ c; "+" ] when String.length c = 1 -> Env.set_flag env c.[0] true; status t ""
  | [ c; "-" ] when String.length c = 1 -> Env.set_flag env c.[0] false; status t ""
  | _ -> Eval.eprint "Usage: flag [letter] [+-]\n"; status t "flag usage"

let init () =
  List.iter (fun (name, f) -> Hashtbl.replace Eval.builtins name f)
    [ "cd", cd; "exit", exit_; ".", dot; "eval", eval; "exec", exec; "shift", shift;
      "wait", wait; "whatis", whatis; "flag", flag;
      "rfork", (fun t _ -> status t ""); "finit", (fun t _ -> status t "") ]
