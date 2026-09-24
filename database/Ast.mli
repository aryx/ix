(* SQL's statements, and the relational algebra a SELECT is (chidb's
 * chisql: its SRA, "sugared relational algebra").
 *
 * The parser builds a SELECT as operators on tables: Table(t),
 * Select(condition, r) -- sigma, SQL's WHERE --, Project(columns, r) --
 * pi --, the joins. .parse prints the tree as chidb does (checked):
 *
 *      SELECT a, t.b FROM t NATURAL JOIN u WHERE a = 3 AND b > 'x';
 *
 *      Project([a, t.b],
 *      	Select(a = int 3 and b > char 'x',
 *      		NaturalJoin(
 *      			Table(t),
 *      			Table(u)
 *      		)
 *      	)
 *      )
 *
 * (a one-character string is a char literal, chidb's grammar's
 * quirk). The grammar is chidb's whole grammar, outer joins, UNION,
 * GROUP BY, aggregates and DELETE included; the compiler compiles a
 * part of it (Codegen).
 *
 * References: E. F. Codd, "A Relational Model of Data for Large
 * Shared Data Banks" (CACM, 1970; from memory), the algebra; B.
 * Sotomayor and A. Shaw, "chidb: Building a Simple Relational Database
 * System from Scratch" (SIGCSE '16; checked), whose point is that
 * "chidb's SQL compiler's internal representation is a direct encoding
 * of the relational algebra". *)

(* a column's declared type; VARCHAR is Text, BYTE and INTEGER Int *)
type data_type = Int | Double | Char | Text

type literal = L_int of int | L_double of float | L_char of char | L_text of string

(* [column] is "*" for all the columns *)
type column_ref = { table : string option; column : string }

type func = Count | Sum | Avg | Min | Max
type binop = Plus | Minus | Multiply | Divide | Concat

(* old: chisql's Expression_t, a tag, a union of a term, a binary and
 * a unary expression, and an alias and a next pointer in every node *)
type expr = { e : expr_kind; alias : string option }

and expr_kind =
  | Literal of literal
  | Null
  | Column of column_ref
  | Func of func * expr
  | Binop of binop * expr * expr
  | Neg of expr

(* != is Not (Cmp (Eq, ...)), printed back as != *)
type cmp = Eq | Lt | Gt | Leq | Geq

type cond =
  | Cmp of cmp * expr * expr
  | And of cond * cond
  | Or of cond * cond
  | Not of cond
  | In of expr * literal list

(* a FOREIGN KEY's column in its table, the table, the column there *)
type fkey = { own : string option; table : string; column : string option }

type constr =
  | Not_null
  | Unique
  | Primary_key
  | Foreign_key of fkey
  | Default of literal
  | Auto_increment
  | Check of cond
  | Size of int

type column = { name : string; typ : data_type; constraints : constr list }
type table = { name : string; columns : column list }
type index = { name : string; table : string; column : string; unique : bool }

type table_ref = { name : string; alias : string option }
type order = Asc | Desc
type join_cond = On of cond | Using of string list
type outer = Left | Right | Full
type set_op = Union | Except | Intersect

type sra =
  | Table of table_ref
  | Project of project
  | Select of cond * sra
  | Natural_join of sra * sra
  | Join of sra * sra * join_cond option
  | Outer_join of outer * sra * sra * join_cond option
  | Set_op of set_op * sra * sra

and project = {
  exprs : expr list;
  sra : sra;
  distinct : bool;
  order_by : (expr * order) option;
  group_by : expr option;
}

type stmt =
  | Create_table of table
  | Create_index of index
  | Select_stmt of sra
  | Insert of { table : string; columns : string list option; values : literal list }
  | Delete of { table : string; where : cond }

(* a statement; [text] is the SQL as parsed, ; added if missing *)
type t = { stmt : stmt; explain : bool; text : string }

(* the lexer's line count, global and never reset, as flex's yylineno:
 * the parser's messages give it *)
val line : int ref

(* chidb's list appends (Constraint_append, KeyDec_append): the first
 * element and the new one, whatever else was between (a quirk kept,
 * since which constraints survive it is visible: "NOT NULL PRIMARY KEY
 * UNIQUE" keeps Unique and Not_null) *)
val chidb_append : 'a list -> 'a -> 'a list

(* what .parse prints, the final newline included *)
val show : t -> string
val show_sra : sra -> string
val show_cond : cond -> string
val show_expr : expr -> string
