(* The .dbmf format: a program for the machine, the database it runs
 * on, and what it should produce -- chidb's course test cases, and
 * what .dbmrun runs.
 *
 *      # Test RESULTROW-001          comments, and blank lines, skipped
 *      NO DBFILE                     or USE file.cdb, or CREATE file.cdb
 *      %%
 *      Integer     42 1 _ _          instructions: opcode p1 p2 p3 p4,
 *      ResultRow    1 1 _ _          _ for 0 (or no p4); or SQL lines
 *      %%
 *      42                            the result rows, values by spaces
 *      %%
 *      R_1 integer 42                the registers expected at the end
 *
 * (tests/files/dbm-programs/register/resultrow-001.dbmf, shortened.) A
 * program is SQL if its first line starts with SELECT, INSERT, UPDATE,
 * DELETE or CREATE. *)

type db = No_dbfile | Use of string | Create of string

type program = Instructions of Dbm.row list | Sql of string list

(* a register's expected type, and its value when given *)
type expected =
  | Unspecified
  | Null
  | Integer of int option
  | String of string option
  | Binary

type t = {
  db : db;
  program : program;
  results : string list;           (* each row as chidb's check prints it *)
  registers : (int * expected) list;
}

(* Failure with the line for a malformed file *)
val parse : string -> t

(* chidb_tokenize: blank-separated; a token starting with a quote runs
 * to the next quote, both dropped *)
val tokenize : string -> string list

(* a row as chidb's check writes it: the values separated by one
 * space, texts in quotes, Unspecified registers left out *)
val show_row : Dbm.value list -> string
