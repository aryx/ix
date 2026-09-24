(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Shell.mli *)

type caps = < Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr >
type db = { bt : Btree.t; mutable schema : Schema.item list }
type mode = List | Column
type t = { caps : caps; mutable db : db option; mutable header : bool; mutable mode : mode }

let print (_ : < Cap.stdout; .. >) s = print_string s
let eprint (_ : < Cap.stderr; .. >) s = prerr_string s; flush stderr

let create caps = { caps; db = None; header = false; mode = List }

let open_file caps file =
  match Btree.open_file caps (Fpath.v file) with
  | bt -> Some { bt; schema = Schema.load bt }
  | exception (Btree.Corrupt_header | Btree.Bad_node _ | Pager.Bad_page _ | Unix.Unix_error _ | Invalid_argument _) -> None

let open_db t file =
  match open_file t.caps file with
  | Some db -> Option.iter (fun (old : db) -> Btree.close old.bt) t.db; t.db <- Some db; true
  | None -> eprint t.caps (Printf.sprintf "ERROR: Could not open file %s or file is not well formed.\n" file); false

let close t = Option.iter (fun (db : db) -> Btree.close db.bt) t.db

(*****************************************************************************)
(* SQL *)
(*****************************************************************************)

(* the compiled program, or None if the SQL is refused (CHIDB_EINVALIDSQL) *)
let prepare t (db : db) sql : (Codegen.program * bool) option =
  match Sql.parse t.caps sql with
  | None -> None
  | Some stmt -> (
      match Codegen.compile db.schema (Optimizer.optimize db.schema stmt) with
      | program -> Some (program, stmt.explain)
      | exception Codegen.Invalid -> None)

(* a value as the shell prints it; None for an invalid type *)
let cell mode (v : Dbm.value) =
  match v, mode with
  | Int n, List -> Some (string_of_int n)
  | Int n, Column -> Some (Printf.sprintf "%10d" n)
  | Null, List -> Some ""
  | Null, Column -> Some (String.make 10 ' ')
  | Text s, List -> Some s
  | Text s, Column -> Some (Printf.sprintf "%-10s" (if String.length s > 10 then String.sub s 0 10 else s))
  | (Unspecified | Record _), _ -> None

let print_row t (vs : Dbm.value list) =
  let sep = match t.mode with List -> "|" | Column -> " " in
  let b = Buffer.create 64 in
  let rec go i = function
    | [] -> ()
    | v :: rest -> (
        if i > 0 then Buffer.add_string b sep;
        match cell t.mode v with
        (* claude: chidb prints the type, SQL_NOTVALID, as the column *)
        | None -> Buffer.add_string b "ERROR: Column -1 return an invalid type.\n"
        | Some s -> Buffer.add_string b s; go (i + 1) rest)
  in
  go 0 vs;
  Buffer.add_string b "\n";
  print t.caps (Buffer.contents b)

let print_header t names =
  if t.header then begin
    let cut s = if String.length s > 10 then String.sub s 0 10 else s in
    match t.mode with
    | List -> print t.caps (String.concat "|" names ^ "\n")
    | Column ->
        print t.caps (String.concat " " (List.map (fun n -> Printf.sprintf "%-10s" (cut n)) names) ^ "\n");
        print t.caps (String.concat " " (List.map (fun _ -> "----------") names) ^ "\n")
  end

let explain_names = [ "addr"; "opcode"; "p1"; "p2"; "p3"; "p4" ]

let run_sql t (db : db) sql =
  match prepare t db sql with
  | None -> print t.caps "SQL syntax error.\n"
  | Some (program, true) ->
      print_header t explain_names;
      Array.iteri (fun addr i ->
        let r = Dbm.to_row i in
        print_row t [ Int addr; Text r.opcode; Int r.p1; Int r.p2; Int r.p3; (match r.p4 with Some s -> Text s | None -> Null) ]) program.code
  | Some (program, false) ->
      print_header t program.columns;
      let m = Dbm.create db.bt program.code in
      let rec loop () = match Dbm.step m with Row -> print_row t (Dbm.result_row m); loop () | Done -> () in
      (match loop () with
       | () -> if program.schema_change then db.schema <- Schema.load db.bt
       | exception Dbm.Constraint -> print t.caps "ERROR: SQL statement failed because of a constraint violation.\n"
       | exception (Pager.Bad_page _ | Btree.Bad_node _ | Invalid_argument _ | Failure _ | Record.Invalid_type _) -> ())

(*****************************************************************************)
(* The commands *)
(*****************************************************************************)

let help = [
  "open", ".open FILENAME     Close existing database (if any) and open FILENAME";
  "parse", ".parse \"SQL\"       Show parse tree for statement SQL";
  "opt", ".opt \"SQL\"       Show parse tree and optimized parse tree for statement SQL";
  "dbmrun", ".dbmrun DBMFILE    Run DBM program in DBMFILE";
  "headers", ".headers on|off    Switch display of headers on or off in query results";
  "mode", ".mode MODE         Switch display mode. MODE is one of:\n                     column  Left-aligned columns\n                     list    Values delimited by | (default)";
  "explain", ".explain on|off    Turn output mode suitable for EXPLAIN on or off.";
  "help", ".help              Show this message";
]

let usage t name msg = eprint t.caps (Printf.sprintf "ERROR: %s\n%s\n" msg (List.assoc name help))

let no_db t = eprint t.caps "ERROR: No database is open.\n"

(* .dbmrun: the program, run on the open database or on the file's own,
 * then the program and the registers printed, as chidb's *)
let dbmrun t file =
  if not (Sys.file_exists file) then eprint t.caps (Printf.sprintf "ERROR: File does not exist: %s\n" file)
  else
    let failed () = eprint t.caps (Printf.sprintf "ERROR: Could not load DBM file %s\n" file) in
    match Dbmfile.parse (In_channel.with_open_bin file In_channel.input_all) with
    | exception Failure _ -> failed ()
    | case ->
        (* the file's own database, when none is open, with chidb's paths *)
        let own = ref None in
        let db = match t.db with
          | Some db -> Some db
          | None ->
              let path = match case.db with
                | Use f -> Some f
                | Create f -> (try Sys.remove f with Sys_error _ -> ()); Some f
                | No_dbfile -> let f = Filename.temp_file ~temp_dir:"." "chidb-tmp-" "" in own := Some f; Some f in
              Option.bind path (open_file t.caps) in
        let finish () = Option.iter Sys.remove !own in
        match db with
        | None -> failed (); finish ()
        | Some db -> (
            let program = match case.program with
              | Instructions rows -> (try Some (Array.of_list (List.map Dbm.of_row rows), rows) with Invalid_argument _ -> None)
              | Sql lines ->
                  List.fold_left (fun _ line -> Option.map (fun ((p : Codegen.program), _) -> p.code, List.map Dbm.to_row (Array.to_list p.code)) (prepare t db line)) None lines in
            match program with
            | None -> failed (); finish ()
            | Some (code, rows) ->
                let m = Dbm.create db.bt code in
                let results = ref false in
                let rec loop () =
                  match Dbm.step m with
                  | Row ->
                      if not !results then (print t.caps "RESULT ROWS\n-----------\n"; results := true);
                      print t.caps (String.concat "," (List.filter_map (fun v -> if v = Dbm.Unspecified then None else Some (Dbm.show_value v)) (Dbm.result_row m)) ^ "\n");
                      loop ()
                  | Done -> true
                  | exception _ -> false
                in
                if not (loop ()) then eprint t.caps (Printf.sprintf "ERROR: Error while running DBM file %s\n" file)
                else begin
                  print t.caps (if !results then "\n" else "This program produced no result rows.\n\n");
                  let b = Buffer.create 1024 in
                  Buffer.add_string b "     opcode          P1     P2     P3     P4\n";
                  Buffer.add_string b "     --------------- ------ ------ ------ ------\n";
                  List.iteri (fun i (r : Dbm.row) ->
                    Buffer.add_string b (Printf.sprintf "%3d: %-15s %-6d %-6d %-6d " i r.opcode r.p1 r.p2 r.p3);
                    Buffer.add_string b (match r.p4 with None -> "NULL\n" | Some s -> "\"" ^ s ^ "\"\n")) rows;
                  Buffer.add_string b "     --------------- ------ ------ ------ ------\n\n";
                  Buffer.add_string b "REGISTERS\n---------\n";
                  (match Dbm.registers m with
                   | [] -> Buffer.add_string b "None of the registers have values\n"
                   | regs -> List.iter (fun (n, v) -> Buffer.add_string b (Printf.sprintf "R_%d = %s\n" n (Dbm.show_value v))) regs);
                  print t.caps (Buffer.contents b)
                end;
                if t.db = None then Btree.close db.bt;
                finish ())

let command t name args =
  let on_off k = match args with
    | [ "on" ] -> k true
    | [ "off" ] -> k false
    | [ _ ] -> usage t name "Invalid argument"
    | _ -> usage t name "Invalid arguments" in
  match name, args with
  | "open", [ file ] -> ignore (open_db t file)
  | "parse", [ sql ] -> Option.iter (fun s -> print t.caps (Ast.show s ^ "\n")) (Sql.parse t.caps sql)
  | "opt", [ sql ] -> (
      match t.db with
      | None -> no_db t
      | Some db ->
          Option.iter (fun s ->
            print t.caps (Ast.show s ^ "\n\n");
            print t.caps (Ast.show (Optimizer.optimize db.schema s) ^ "\n")) (Sql.parse t.caps sql))
  | "dbmrun", [ file ] -> dbmrun t file
  | "headers", _ -> on_off (fun b -> t.header <- b)
  | "mode", [ "list" ] -> t.mode <- List
  | "mode", [ "column" ] -> t.mode <- Column
  | "mode", [ _ ] -> usage t name "Invalid argument"
  | "explain", _ -> on_off (fun b -> t.header <- b; t.mode <- (if b then Column else List))
  | "help", _ -> List.iter (fun (_, h) -> eprint t.caps (h ^ "\n")) help
  | ("open" | "parse" | "opt" | "dbmrun" | "mode"), _ -> usage t name "Invalid arguments"
  | _ -> ()

let handle t line =
  if line.[0] = '.' then
    match Dbmfile.tokenize line with
    | [] -> ()
    | word :: args -> (
        let word' = String.sub word 1 (String.length word - 1) in
        let starts n = String.length word' >= String.length n && String.sub word' 0 (String.length n) = n in
        match List.find_opt (fun (n, _) -> starts n) help with
        | Some (n, _) -> command t n args
        | None -> eprint t.caps (Printf.sprintf "ERROR: Unrecognized command: %s\n" word))
  else match t.db with None -> no_db t | Some db -> run_sql t db line
