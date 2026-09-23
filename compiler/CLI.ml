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

type caps = < Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr >

let print (_ : < Cap.stdout; .. >) s = print_string s
let eprint (_ : < Cap.stderr; .. >) s = prerr_string s; flush stderr

let read_file (caps : < Cap.open_in; .. >) file =
  match CapStdlib.open_in caps file with
  | ic -> Some (Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic)))
  | exception Sys_error _ -> None

(* a front end's state is global: one file per run; the tokens are
 * read by Lexer, from its input stack, not a lexbuf *)
let compile (caps : < caps; .. >) (mach : Tree.machine) ~dump ~listing ~out defs incs file =
  Tree.mach := Some mach;
  let codegen = true in
  (match mach.thechar with
   | '5' -> Emit.be := Some Arm.backend; Gen.hooks := Some Arm.hooks
   | _ -> Emit.be := Some Arm64.backend; Gen.hooks := Some Arm64.hooks);
  Tree.init_types ();
  Pre.profile := true;
  Lexer.init ();
  let s = Tree.lookup ".string" in
  let t = Tree.typ Tree.Tarray (Some (Tree.ty Tree.Tchar)) in
  t.width <- 0;
  s.sclass <- Tree.Cstatic; s.typ <- Some t;
  List.iter Pre.dodefine defs;
  (* "." is the source's directory; <...> skips it *)
  let dir = if String.contains file '/' then Filename.dirname file else "." in
  Pre.includes := dir :: incs;
  Pre.read_file := read_file caps;
  if codegen then begin
    Check.xcom := Gen.xcom;
    Check.outstring := Emit.outstring;
    Declare.gextern := Emit.gextern;
    Emit.init ()
  end;
  Declare.on_function := (fun f body ->
    if dump then print caps (Tree.prtree (Some f) "func" ^ Tree.prtree (Some body) "body");
    if codegen then Gen.codgen body f);
  match read_file caps file with
  | None -> Error (Printf.sprintf "cannot open %s" file)
  | Some text ->
      Pre.push text;
      Tree.lineno := 1;
      (match Parser.prog (fun _ -> Lexer.token ()) (Lexing.from_string "") with
       | () ->
           if codegen then begin
             Emit.gclean ();
             if listing then print caps (Emit.listing ());
             Ix_asm.Asm.save caps out (Emit.obj file)
           end;
           Ok ()
       | exception Tree.Error m -> Error (Printf.sprintf "%s:%s" file m)
       | exception Parsing.Parse_error -> Error (Printf.sprintf "%s:%d: syntax error" file !Tree.lineno))

let main (caps : < caps; .. >) (argv : string array) : int =
  let mach = ref Arm.machine and dump = ref false and listing = ref false and out = ref "" and defs = ref [] and incs = ref [] and files = ref [] in
  let rec args = function
    | "-m" :: "5" :: rest -> mach := Arm.machine; args rest
    | "-m" :: "7" :: rest -> mach := Arm64.machine; args rest
    | "-x" :: rest -> dump := true; args rest
    | "-o" :: o :: rest -> out := o; args rest
    | "-S" :: rest -> listing := true; args rest
    | "-I" :: d :: rest -> incs := d :: !incs; args rest
    | "-D" :: d :: rest -> defs := d :: !defs; args rest
    | a :: rest when String.length a > 2 && String.sub a 0 2 = "-I" -> incs := String.sub a 2 (String.length a - 2) :: !incs; args rest
    | a :: rest when String.length a > 2 && String.sub a 0 2 = "-D" -> defs := String.sub a 2 (String.length a - 2) :: !defs; args rest
    | a :: rest when String.length a > 1 && a.[0] = '-' -> args rest   (* 5c's other flags: -w, -F, -V... *)
    | f :: rest -> files := f :: !files; args rest
    | [] -> ()
  in
  args (List.tl (Array.to_list argv));
  match !files with
  | [ file ] -> (
      (* x.c to x.5, in the current directory, as 5c *)
      let out = if !out <> "" then !out else Filename.remove_extension (Filename.basename file) ^ "." ^ String.make 1 !mach.thechar in
      match compile caps !mach ~dump:!dump ~listing:!listing ~out (List.rev !defs) (List.rev !incs) file with
      | Ok () -> 0
      | Error m -> eprint caps (m ^ "\n"); 1)
  | _ -> eprint caps "usage: tinycc -m 5|7 [-x] [-S] [-Idir] [-Dname=value] [-o out] file.c\n"; 1
