(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The test suite of database/: chidb's 131 .dbmf cases (its course's
 * tests: a program, the rows and registers it must produce), run on
 * TinyDb's machine. The corpus is read from chidb's checkout
 * ($CHIDB_DIR, ~/github/chidb by default), as the toolchain's tests
 * read goken's. From the root: make test. *)
open Ix_db

let chidb_dir = match Sys.getenv_opt "CHIDB_DIR" with Some d -> d | None -> Filename.concat (Sys.getenv "HOME") "github/chidb"
let files = Filename.concat chidb_dir "tests/files"

(* Filename.temp_dir is OCaml 5.1's *)
let temp_dir () = let d = Filename.temp_file "tinydb" "" in Sys.remove d; Sys.mkdir d 0o700; d

let rec find dir =
  Sys.readdir dir |> Array.to_list |> List.sort compare |> List.concat_map (fun f ->
    let p = Filename.concat dir f in
    if Sys.is_directory p then find p else if Filename.check_suffix f ".dbmf" then [ p ] else [])

(* the case's database, a fresh copy in [dir] *)
let setup dir (db : Dbmfile.db) =
  let file = Filename.concat dir "db.cdb" in
  (match db with
   | No_dbfile | Create _ -> ()
   | Use f -> ignore (Sys.command (Printf.sprintf "cp %s %s" (Filename.quote (Filename.concat files ("databases/" ^ f))) (Filename.quote file))));
  file

let check_register m (n, (e : Dbmfile.expected)) =
  let where = Printf.sprintf "R_%d" n in
  if n >= Dbm.n_registers m then Alcotest.failf "%s: the machine has only %d registers" where (Dbm.n_registers m);
  match e, Dbm.register m n with
  | Unspecified, Unspecified | Null, Null | Binary, Record _ -> ()
  | Integer (Some v), Int x -> Alcotest.(check int) where v x
  | Integer None, Int _ -> ()
  | String (Some v), Text x -> Alcotest.(check string) where v x
  | String None, Text _ -> ()
  | _, v -> Alcotest.failf "%s: of type %s" where (match v with Unspecified -> "unspecified" | Null -> "null" | Int _ -> "integer" | Text _ -> "string" | Record _ -> "binary")

let run caps (case : Dbmfile.t) =
  let dir = temp_dir () in
  let bt = Btree.open_file caps (Fpath.v (setup dir case.db)) in
  let program = match case.program with
    | Instructions rows -> Array.of_list (List.map Dbm.of_row rows)
    | Sql lines ->
        (* each line compiled against the database's schema; the last kept, as chidb's *)
        List.fold_left (fun _ line ->
          match Sql.parse caps line with
          | Some stmt -> let schema = Schema.load bt in (Codegen.compile schema (Optimizer.optimize schema stmt)).code
          | None -> Alcotest.failf "does not parse: %s" line) [||] lines in
  let m = Dbm.create bt program in
  let rec rows acc = match Dbm.step m with Dbm.Row -> rows (Dbmfile.show_row (Dbm.result_row m) :: acc) | Done -> List.rev acc in
  let got = rows [] in
  Btree.close bt;
  Alcotest.(check (list string)) "result rows" case.results got;
  List.iter (check_register m) case.registers;
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let corpus caps =
  if not (Sys.file_exists files) then []
  else
    find (Filename.concat files "dbm-programs") |> List.map (fun path ->
      let name = Filename.chop_suffix (Filename.basename path) ".dbmf" in
      let case = Dbmfile.parse (In_channel.with_open_bin path In_channel.input_all) in
      Testo.create ("dbmf: " ^ name) (fun () -> run caps case; Testo.Promise.return ()))

let () = Cap.main (fun (caps : Cap.all_caps) -> Testo.interpret_argv ~project_name:"ix-db" (fun _env -> corpus caps))
