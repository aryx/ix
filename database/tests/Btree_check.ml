(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* btree_check OUT table KEYS | btree_check OUT index M VALS: build,
 * through the B-tree layer alone, the file chidb makes from
 *   table: CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); then an
 *          INSERT (k, "name number k padded to be longer") per key;
 *   index: CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER); the
 *          first M values inserted (keys 1, 2, ...), CREATE INDEX iv
 *          ON t(v), then the rest;
 * so that btree_differential.sh can compare them byte for byte, before
 * the machine exists to run the SQL. *)
open Ix_db

let schema bt key typ name root sql =
  Btree.insert_in_table bt 1 key (Bytes.of_string (Record.pack [ Text typ; Text name; Text "t"; Int (W32, root); Text sql ]))

let () =
  Cap.main (fun caps ->
    let out = Fpath.v Sys.argv.(1) in
    (try Sys.remove Sys.argv.(1) with Sys_error _ -> ());
    let bt = Btree.open_file caps out in
    let ints s = List.map int_of_string (String.split_on_char ',' s) in
    (match Array.to_list Sys.argv with
     | [ _; _; "table"; keys ] ->
         let root = Btree.new_node bt Table Leaf in
         schema bt 1 "table" "t" root "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);";
         List.iter (fun k ->
           let r = Record.pack [ Null; Text (Printf.sprintf "name number %d padded to be longer" k) ] in
           Btree.insert_in_table bt root k (Bytes.of_string r)) (ints keys)
     | [ _; _; "index"; m; vals ] ->
         let m = int_of_string m and vals = ints vals in
         let troot = Btree.new_node bt Table Leaf in
         schema bt 1 "table" "t" troot "CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER);";
         let row i v = Btree.insert_in_table bt troot i (Bytes.of_string (Record.pack [ Null; Int (W32, v) ])) in
         List.iteri (fun i v -> if i < m then row (i + 1) v) vals;
         let iroot = Btree.new_node bt Index Leaf in
         schema bt 2 "index" "iv" iroot "CREATE INDEX iv ON t(v);";
         List.iter (function
           | Btree.Table_leaf { key; data } -> (match Record.unpack data 0 with [ _; Int (_, v) ] -> Btree.insert_in_index bt iroot v key | _ -> ())
           | Btree.Table_internal _ | Btree.Index_leaf _ | Btree.Index_internal _ -> ()) (snd (Btree.cells bt troot));
         List.iteri (fun i v -> if i >= m then (row (i + 1) v; Btree.insert_in_index bt iroot v (i + 1))) vals
     | _ -> prerr_endline "usage: btree_check OUT table KEYS | btree_check OUT index M VALS"; exit 2);
    Btree.close bt)
