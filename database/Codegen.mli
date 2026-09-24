(* The compiler: a statement to a program for the machine (chidb's
 * codegen.c).
 *
 * Each statement shape has its program, with chidb's registers,
 * cursors and order of instructions, since EXPLAIN prints them:
 *
 *   - CREATE TABLE, CREATE INDEX: a row into the schema table (and, for
 *     an index, a scan of its table filling it);
 *   - INSERT: the row's record into its table, then (value, primary
 *     key) into each of the table's indexes;
 *   - SELECT from one table: a scan, each conjunct of the WHERE a jump
 *     over the row when false (col > v: "if col <= v, skip"); or, when
 *     the WHERE is one comparison, or a range c > a AND c < b, on an
 *     indexed column, a seek in the index and a walk from there;
 *   - SELECT from a NATURAL JOIN of two tables: nested loops, each side
 *     scanned or seeked as a single table would be, the pairs kept
 *     that agree on the shared columns.
 *
 * The WHERE must be conjuncts `column OP literal` (OP = < <= = >= >,
 * either way round), the literal of the column's type; anything else
 * is refused (Invalid, which the shell prints as "SQL syntax error.").
 * The choice between a scan and a seek is by the WHERE's shape, not by
 * a cost.
 *
 * A jump names a label, placed where chidb patches an address, and one
 * pass numbers the instructions and resolves the labels.
 *
 * References: P. G. Selinger et al., "Access Path Selection in a
 * Relational Database Management System" (SIGMOD, 1979; from memory),
 * choosing a scan or an index by estimated cost: the road not taken;
 * chidb's assignment_codegen and assignment_opt pages
 * (docs/chidb-website/chidb/, checked), the specification. *)

type program = {
  code : int Dbm.instr array;
  columns : string list;      (* the result's column names *)
  schema_change : bool;       (* a CREATE: the schema is to be read again *)
}

(* a statement chidb's compiler refuses (CHIDB_EINVALIDSQL) *)
exception Invalid

val compile : Schema.item list -> Ast.t -> program
