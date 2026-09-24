(* The database machine: what SQL is compiled to (chidb's DBM, after
 * SQLite's VDBE).
 *
 * Numbered registers hold values, numbered cursors walk B-trees, and a
 * program is a list of instructions run from the first until the end
 * or Halt, each jumping or going to the next. SELECT name FROM t
 * WHERE n > 100, as EXPLAIN prints it (checked on chidb):
 *
 *      0  Integer     2  0  0      r0 := 2               t's root page
 *      1  OpenRead    0  0  3      cursor 0 on it, 3 columns
 *      2  Integer   100  1  0      r1 := 100
 *      3  Rewind      0  9  0      to the first row; if none, go to 9
 *      4  Column      0  2  2      r2 := its column 2
 *      5  Le          1  8  2      if r2 <= r1, go to 8   (the WHERE, negated)
 *      6  Column      0  1  3      r3 := its column 1
 *      7  ResultRow   3  1  0      a row of 1 register from r3
 *      8  Next        0  4  0      the next row; if there is one, go to 4
 *      9  Close       0  0  0
 *     10  Halt        0  0  0
 *
 * ResultRow hands a row to the caller and the machine resumes after
 * it. The comparisons jump when the register named third compares so
 * with the one named first: [Le] jumps if r2 <= r1.
 *
 * References: SQLite's VDBE ("The SQLite Bytecode Engine",
 * sqlite.org), which chidb's machine is a subset of: 37 opcodes to
 * about 180 (checked, chidb's docs/claude_notes/notes_sqlite.txt);
 * chidb's assignment_dbm page (docs/chidb-website/chidb/), the
 * opcodes' specification. *)

(* a register's, a cursor's number *)
type reg = R of int [@@unboxed]
type cursor = C of int [@@unboxed]

(* old: chidb's register, a type tag and a union; its REG_UNSPECIFIED
 * is a register never written *)
type value =
  | Unspecified
  | Null
  | Int of int              (* a 32-bit signed integer *)
  | Text of string
  | Record of string        (* a packed record, as MakeRecord makes it *)

type cmp = Eq | Ne | Lt | Le | Gt | Ge
type order = Lt | Le | Gt | Ge

(* an instruction; ['j] is where a jump goes: a label while compiling,
 * an address once resolved *)
(* old: chidb's chidb_dbm_op_t, an opcode and int32 p1, p2, p3 and a
 * char *p4, whose meaning each opcode's handler knew; a register was a
 * jump target or a cursor as the handler read it *)
type 'j instr =
  | Noop
  | Open_read of cursor * reg * int            (* the root page's register; the number of columns *)
  | Open_write of cursor * reg * int
  | Close of cursor
  | Rewind of cursor * 'j                       (* jumps if empty *)
  | Next of cursor * 'j                         (* jumps if moved *)
  | Prev of cursor * 'j
  | Seek of Cursor.seek * cursor * 'j * reg     (* jumps if none qualifies *)
  | Column of cursor * int * reg
  | Key of cursor * reg
  | Integer of int * reg
  | String of int * reg * string                (* its length, as chidb writes it *)
  | Null of reg
  | Result_row of reg * int
  | Make_record of reg * int * reg
  | Insert of cursor * reg * reg                (* the record's register, the key's *)
  | Cmp of cmp * reg * 'j * reg
  | Idx_cmp of order * cursor * 'j * reg        (* jumps if the index entry's value compares so *)
  | Idx_pkey of cursor * reg
  | Idx_insert of cursor * reg * reg            (* the value's register, the primary key's *)
  | Create of Btree.tree * reg                  (* CreateTable, CreateIndex *)
  | Copy of reg * reg
  | Scopy of reg * reg
  | Halt

(* the instruction with its jump target changed *)
val map_jump : ('a -> 'b) -> 'a instr -> 'b instr

(* an instruction as EXPLAIN prints it and .dbmf files write it *)
type row = { opcode : string; p1 : int; p2 : int; p3 : int; p4 : string option }

val to_row : int instr -> row

(* Invalid_argument for an unknown opcode or a String without its p4 *)
val of_row : row -> int instr

(* an Insert or IdxInsert of a key already there (CHIDB_ECONSTRAINT) *)
exception Constraint

type t
type step = Row | Done

val create : Btree.t -> int instr array -> t

(* runs until a ResultRow (Row) or the end (Done) *)
val step : t -> step

(* the last ResultRow's registers *)
val result_row : t -> value list

(* the registers written, with their numbers *)
val registers : t -> (int * value) list

(* how many registers the machine has (at least 10, and one past the
 * highest written, as chidb's array), and one of them *)
val n_registers : t -> int
val register : t -> int -> value

(* a value as .dbmrun prints it: NULL, 42, "text", (n bytes); none for
 * Unspecified *)
val show_value : value -> string
