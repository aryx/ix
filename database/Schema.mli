(* The schema: page 1's table of tables and indexes.
 *
 * One row per table and per index, as SQLite's sqlite_master has
 * them (checked, the tutorial's §5):
 *
 *      ("table", "t", "t", 2, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, n INTEGER);")
 *      ("index", "iv", "t", 5, "CREATE INDEX iv ON t(v);")
 *
 * A table's columns and an index's column are not stored anywhere
 * else: they come from parsing that SQL again, as chidb does. Names
 * of tables and columns are compared ignoring case. *)

type item = {
  kind : Btree.tree;
  name : string;
  table : string;       (* the table's own name, or the indexed table's *)
  root : int;
  sql : string;
  key : int;            (* its key in page 1 *)
}

(* the items in key order *)
val load : Btree.t -> item list

val find_table : item list -> string -> item option

(* an index on this table's column *)
val find_index_on : item list -> string -> string -> item option

(* a table's columns, from its CREATE TABLE *)
val columns : item -> Ast.column list

(* an index's column, from its CREATE INDEX *)
val index_column : item -> string option

(* one more than the largest key *)
val next_key : item list -> int
