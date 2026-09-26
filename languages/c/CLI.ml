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

let print = Console.print and eprint = Console.eprint

(* what the command asks of a back end: its hooks in the front end set
 * (after the front end's own state), a function's code, the file's
 * end, its listing and its object *)
type backend = {
  init : unit -> unit;
  codgen : Tree.sym -> Tree.stmt -> unit;
  finish : unit -> unit;
  listing : unit -> string;
  obj : Fpath.t -> Ix_asm.Asm.obj;
}

(* 5c's and 7c's at -O0, byte for byte (compat/) *)
let compat (mach : Tree.machine) : backend =
  let open Ix_cc_compat in
  {
    init = (fun () ->
      (match mach.thechar with
       | '5' -> Emit.be := Some Arm.backend; Gen.hooks := Some Arm.hooks
       | _ -> Emit.be := Some Arm64.backend; Gen.hooks := Some Arm64.hooks);
      (* acom first: a pass of 5c's front end, the listing's *)
      Check.xcom := (fun n -> Gen.xcom (Acom.acom n));
      Check.outstring := Emit.outstring;
      Declare.gextern := Emit.gextern;
      Emit.init ());
    codgen = Gen.codgen;
    finish = Emit.gclean;
    listing = Emit.listing;
    obj = Emit.obj;
  }

(* a front end's state is global: one file per run; the tokens are
 * read by Lexer, from its input stack, not a lexbuf *)
let compile (caps : < caps; .. >) (mach : Tree.machine) (be : backend) ~dump ~listing ~out defs incs file =
  Tree.mach := Some mach;
  Tree.init_types ();
  Pre.profile := true;
  Lexer.init ();
  let s = Tree.lookup ".string" in
  let t = Tree.typ Tree.Tarray (Some (Tree.ty Tree.Tchar)) in
  t.width <- 0;
  s.sclass <- Tree.Cstatic; s.typ <- Some t;
  List.iter Pre.dodefine defs;
  (* "." is the source's directory; <...> skips it *)
  Pre.includes := Fpath.parent file :: incs;
  Pre.read_file := Files.read_opt caps;
  be.init ();
  Declare.on_function := (fun (f : Tree.sym) body ->
    if dump then print caps (Tree.prtree f.name body);
    be.codgen f body);
  match Files.read_opt caps file with
  | None -> Error (Printf.sprintf "cannot open %s" (Fpath.to_string file))
  | Some text ->
      Pre.push text;
      Tree.lineno := 1;
      (match Parser.prog (fun _ -> Lexer.token ()) (Lexing.from_string "") with
       | () ->
           be.finish ();
           if listing then print caps (be.listing ());
           Ix_asm.Asm.save caps out (be.obj file);
           Ok ()
       | exception Tree.Error m -> Error (Printf.sprintf "%s:%s" (Fpath.to_string file) m)
       | exception Parsing.Parse_error -> Error (Printf.sprintf "%s:%d: syntax error" (Fpath.to_string file) !Tree.lineno))

let main (caps : < caps; .. >) (argv : string array) : int =
  let mach = ref Machines.arm and simple = ref false and dump = ref false and listing = ref false and out = ref "" and defs = ref [] and incs = ref [] and files = ref [] in
  let rec args = function
    | "-m" :: "5" :: rest -> mach := Machines.arm; args rest
    | "-m" :: "7" :: rest -> mach := Machines.arm64; args rest
    | "-simple" :: rest -> simple := true; args rest
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
  let path s = match Files.path s with Ok p -> p | Error m -> failwith m in
  match List.map path !files, List.map path (List.rev !incs) with
  | _ when !simple -> eprint caps "mini-cc: -simple: not yet (plan_cc.md, decision 8)\n"; 1
  | [ file ], incs -> (
      (* x.c to x.5, in the current directory, as 5c *)
      let out = if !out <> "" then path !out else Fpath.set_ext ("." ^ String.make 1 !mach.thechar) (Fpath.base file) in
      match compile caps !mach (compat !mach) ~dump:!dump ~listing:!listing ~out (List.rev !defs) incs file with
      | Ok () -> 0
      | Error m -> eprint caps (m ^ "\n"); 1)
  | exception Failure m -> eprint caps ("mini-cc: " ^ m ^ "\n"); 1
  | _, _ -> eprint caps "usage: mini-cc -m 5|7 [-x] [-S] [-Idir] [-Dname=value] [-o out] file.c\n"; 1
