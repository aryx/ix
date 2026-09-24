# Plan: TinyDb, a relational database from scratch, for teaching (`database/`)

Companions:
[`notes_db.md`](../tutorials/notes_db.md), the tutorial: pages and the
file, B-trees, records, the schema table, a machine with registers
and cursors, compiling SQL to it, indexes, and pushing a selection
down a join. And
[`notes_db_related_work.md`](../related-work/notes_db_related_work.md):
from Codd's relational model and System R to SQLite, the B-tree and
its variants, query compilers and optimizers, and the teaching
databases. The twin is the author's fork of chidb
(`~/github/chidb`, Borja Sotomayor and Adam Shaw's teaching RDBMS
from the University of Chicago, with all four of its course
assignments and the optimizer implemented): 7,338 lines of C in
`src/libchidb`, 2,870 of hand-written C, flex and bison in
`src/libchisql` (the generated lexer and parser, 4,850 more, left
out), and 600 in the shell, `src/shell`. Principia lists it under
`database/chidb`, and the fork has a literate stub
(`docs/literate/Database.nw`, 361 lines). There is no xix twin.

The sixth ix program, after TinyMk, TinyRc, TinyEd, the toolchain
and the C compiler, planned the same way; the principles are in
[`../README.md`](../README.md). The author chose it ("let's do tiny
sqlite under database/ (and its TinyDatabase.ml more free form
later)"), over the 5i emulator and git.

## Context

A relational database answers questions about tables, asked in SQL,
over data too big to hold in memory and meant to outlive the program.
SQLite is the one most programs use: a library, one file per
database, no server. chidb is SQLite cut down to what a quarter of a
databases course can build: the same file format (a chidb file opens
in `sqlite3`; checked by chidb's own notes,
`docs/claude_notes/notes_sqlite.txt`), the same layers (a pager, B-trees
for tables and indexes, records, a register machine running compiled
SQL, a SQL front end), and a subset of each.

Why a database now:

- **A reference runs today, and it has a test corpus.** The `chidb`
  binary is built in the fork (`make check` green, 5 suites), and the
  course ships 131 `.dbmf` cases (`tests/files/dbm-programs/`): a
  database, a program (in the machine's language or in SQL), the
  expected result rows and registers. So the corpus method of the
  earlier programs carries over, with a corpus already written.
- **Three levels of output to compare, as for the compiler.** The
  shell's output (the rows), the compiled program (`EXPLAIN`, like
  `5c -S`'s listing), and the database file itself, byte for byte
  (like the linker's executables).
- **It teaches what the others did not.** The toolchain was about
  code; a database is about data structures on disk (pages, B-trees,
  records) and about a query compiler whose target is a machine of
  its own. The relational algebra is the compiler's intermediate
  representation, which is chidb's own point (the SIGCSE paper:
  "chidb's SQL compiler's internal representation is a direct
  encoding of the relational algebra").
- **principle 12 has a lot to do.** chidb is C with 37 opcodes as an
  enum and three ints plus a string per instruction, cells as a
  union over four page types, the parse tree as tagged unions, and
  codegen that patches jump targets into an array. Each is a
  variant in OCaml.

## Principles

Those of [`../README.md`](../README.md), and three of its own:

- **The program is the fork's C and the binary is `~/github/chidb/chidb`.**
  Where the C, the course's web pages (`docs/chidb-website/`) and the
  binary disagree, the binary wins, since the corpus is recorded
  from it.
- **The file is an output, compared byte for byte.** A database file
  written by TinyDb from the same statements is the same bytes as
  chidb's, free space included (see decision 2). A difference is a
  bug, unless it is one of the documented deliberate differences.
- **Three references in one: `sqlite3` checks the files.** Since the
  format is a subset of SQLite's, a file TinyDb writes must open in
  SQLite and give the same rows (Python's `sqlite3` module, which is
  installed, SQLite 3.45: it reads a chidb file's rows, the primary
  key from the rowid, checked) can do it. That checks the format
  against the real thing, not only against chidb.

## The interface: chidb's shell, unchanged

`tinydb [-c COMMAND] [-v] [-h] [DATABASE]`, the shell's prompt
(`chidb> `, printed even when the input is not a terminal, as chidb
does; the name kept, since the prompt is output), and:

| input | what | TinyDb |
|---|---|---|
| `CREATE TABLE t(c type [constraints], ...)` | a table; its first column the INTEGER PRIMARY KEY | kept |
| `CREATE [UNIQUE] INDEX i ON t(c)` | an index on an integer column, populated | kept |
| `INSERT INTO t VALUES(...)` | a row, and its entry in each index of `t` | kept |
| `SELECT cols FROM t [WHERE c op lit AND ...]` | a scan, or an index seek (one comparison, or a range `c > a AND c < b`) | kept |
| `SELECT ... FROM t1 NATURAL JOIN t2 [WHERE ...]` | two tables; each side scanned or seeked | kept |
| `EXPLAIN stmt` | the compiled program, not run | kept |
| `.open` `.headers` `.mode list\|column` `.explain` `.help` | shell commands | kept |
| `.parse "SQL"` `.opt "SQL"` | the parse tree; and after the optimizer | kept |
| `.dbmrun FILE` | run a `.dbmf` program | kept |
| the rest of the grammar: outer joins, `UNION`, `GROUP BY`, aggregates, `DELETE`, `CHECK`, foreign keys | parsed, printed by `.parse`, refused by the compiler ("SQL syntax error.") | kept as chidb has it (decision 5) |
| `-v` logging levels | chidb's `log_*` | through the Logs library, `-v` raising the level |

Nothing that runs is dropped; every limit of chidb's is kept, since
it is chidb's behaviour: 4-byte integers only, an index only on an
integer column and assumed unique, the first column the primary key,
a two-way join at most. The names: `tinydb`, and the directory
`database/`, principia's.

## Target layout

```
database/                  library ix_db + the tinydb executable
  Pager.ml(i)              the file as numbered pages of bytes; the
                           100-byte header (decision 2)
  Record.ml(i)             a row's values to bytes and back: NULL, 1-,
                           2-, 4-byte integers, text
  Btree.ml(i)              nodes and cells (a variant per page type),
                           find, insert, split (decision 2)
  Cursor.ml(i)             a snapshot of a B-tree, in key order, and its
                           seeks (decision 3)
  Ast.ml(i)                the SQL statement and the relational algebra
                           (SRA): variants; .parse's printer (decision 5)
  Lexer.mll, Parser.mly    chidb's grammar, in ocamllex and ocamlyacc
  Schema.ml(i)             the schema table on page 1, loaded, searched
  Dbm.ml(i)                the machine: instructions as a variant,
                           registers, cursors, the loop (decision 4)
  Codegen.ml(i)            statements to programs, with labels, not
                           patched addresses (decision 6)
  Optimizer.ml(i)          sigma-pushing, a function from SRA to SRA
  Dbmfile.ml(i)            the .dbmf format, for .dbmrun and the tests
  Shell.ml(i), CLI.ml(i), Main.ml
                           the commands, the output modes, the flags
database/tests/            Testo: the .mli examples, the laws, the
                           .dbmf corpus, the differential scripts
tiny/                      TinyDatabase.ml (see "Outside chidb")
```

**The size target**, set by module: Pager 60, Record 120, Btree 260,
Cursor 70, Ast 280 (with the printer), Lexer 80, Parser 260, Schema 60,
Dbm 380, Codegen 560, Optimizer 70, Dbmfile 140, Shell 220, CLI 60,
Main 10: about **2,600 lines of OCaml**, a quarter of chidb's C
counted as above. TinyRc came out 6% over its target and TinyMk 2.4
times; the Status will compare.

## Groundwork decisions

### 1. The layers are chidb's, and each is a module

Pager, B-tree, records, cursors, machine, compiler, parser: chidb's
layers are SQLite's, and they are the lesson (each knows only the one
below). So the modules follow them one for one, and the tutorial goes
bottom up. What changes is inside each: C's out-parameters and error
codes become results and one exception, its tagged unions variants.

### 2. Pages are bytes, as on disk; what is read from them is typed

The database file is the contract, byte for byte, and chidb's bytes
include what it leaves behind: `initEmptyNode` rewrites a page's
header but not its old cells, so a page split leaves the previous
cells in the free space of the page that keeps the upper half. A
B-tree kept as OCaml values and written out fresh would zero that
space: the same database, logically, but not the same file. So:

- a **page is a `Bytes.t`**, read, changed in place and written back in
  chidb's order (the pager reads a page past the end of the file as
  zeros, as `calloc` and a short `fread` do);
- what is **read from a page is a variant**: a node's kind is
  `Table | Index` times `Leaf | Internal`, and a cell is
  `Table_leaf of {key; data} | Table_internal of {key; child} |
  Index_leaf of {key; pkey} | Index_internal of {key; pkey; child}`,
  decoded by one function and encoded by one, so a cell's fields can't
  be read with the wrong page type (C's union allows it);
- the **algorithms** (find the position, insert into a non-full node,
  split the child and promote its median, clone a full root into a new
  page and split that) are chidb's, step for step, since the page
  numbers they allocate are in the file.

The road not taken, a B-tree as an immutable OCaml tree serialized on
each write, is shorter and is what `tiny/TinyDatabase.ml` will do,
without the file compatibility.

### 3. A cursor is a snapshot, as chidb's

chidb's cursor (`dbm-cursor.c`) reads the whole tree into sorted
arrays when it is opened, and moves along them: `O(n)` to open,
simple, and a snapshot (an insert through another cursor is not
seen). The textbook cursor is a stack of (page, cell) positions down
the tree. Since chidb's statements never read a table they are
writing, the two give the same results, and the snapshot is the
smaller: an array of entries, `Row of key * bytes | Entry of key *
pkey`, and an index. The stack cursor is named in the tutorial as
the real one.

### 4. The machine's instructions are a variant; `p1 p2 p3 p4` are their printing

chidb's instruction is an opcode and `int32 p1, p2, p3` and a `char
*p4`, whose meaning depends on the opcode: a register, a cursor, a
jump target, a column number, a constant. In TinyDb an instruction is
`Integer of int32 * reg | OpenRead of cursor * reg * int | Rewind of
cursor * label | Column of cursor * int * reg | Eq of reg * label * reg
| ...`, 37 constructors whose operands say what they are (`reg`,
`cursor`, `label` are distinct types), and `to_row`/`of_row` give the
`opcode p1 p2 p3 p4` form that `EXPLAIN` prints and `.dbmf` files are
written in. A register is `Unspecified | Null | Int of int32 | Text of
string | Record of bytes`, as chidb's five register types.

### 5. The grammar is chidb's whole grammar, in ocamlyacc

`sql.y` parses more than the compiler compiles: outer joins,
`UNION`, `GROUP BY`, aggregates, `DELETE`, column constraints. What
the compiler refuses prints "SQL syntax error.", the same message as a
real syntax error, so a smaller grammar would change only what
`.parse` prints for those statements. Kept anyway: the grammar is
declarative in ocamlyacc (the project's default for a grammar that
nests), the parse tree is the relational algebra the
tutorial is about, and `.parse` is how the corpus checks the front end
alone. The printer is `.parse`'s format, byte for byte (tabs,
`Project([a, t.b], ...)`, `int 3`, `char 'x'`: a one-character string
is a `char`, a chidb quirk kept).

### 6. Code generation emits labels; a pass resolves them

chidb's codegen emits into an array and patches forward jumps later
(`stmt->ops[addr].p2 = ...`), keeping the addresses to patch in
arrays. TinyDb's emits a list of instructions and `Label l` markers,
jumps naming labels, and one pass numbers the instructions and
replaces labels by addresses. The register and cursor numbering, and
the order of the instructions, are chidb's exactly, since `EXPLAIN`
prints them.

### 7. The optimizer is a function, as chidb's nearly is

`chidb_stmt_optimize` copies the statement and rebuilds the tree for
one shape (a selection over a natural join of two base tables): the
conjuncts touching only one side move down next to it. That is
already a function from a tree to a tree; in OCaml it is one match.

## Outside chidb: TinyDatabase.ml

The free variant, in one file, later: the same layers without the
compatibility. Candidates, to choose by size when it is written: a
B-tree as an immutable tree (no split in place), a file that is the
tree marshalled, SQL as a small hand-written parser (the grammar that
runs, not chidb's whole one), the machine kept (it is the lesson) or
replaced by an interpreter over the relational algebra (the road the
tutorial compares). Checked by running the same SQL sessions and
comparing rows (not files) with TinyDb.

## The modules, with their references

Each module's `.mli` cites what it implements (principle "References
in the code"), checked, not from memory:

- `Btree.mli`: Bayer and McCreight's B-trees; SQLite's file format
  (the page and cell layout chidb keeps); chidb's own file format page
  (`docs/chidb-website/`).
- `Record.mli`: SQLite's record format, and where chidb's differs (4-byte
  varints, only four types).
- `Dbm.mli`: SQLite's VDBE, which the machine is modeled on (chidb's
  notes: 37 opcodes against about 180).
- `Codegen.mli`, `Optimizer.mli`: Selinger et al.'s access path
  selection, as the road not taken (chidb chooses by shape, not cost).
- `Ast.mli`: Codd's relational algebra; the SIGCSE paper's point that
  the compiler's IR is the algebra.

## Tests (what the program is for)

- **The `.dbmf` corpus**, 131 cases: a runner reads a case, opens (a
  copy of) its database, runs its program or SQL, and compares rows and
  registers. The same runner runs over chidb's shell (`.dbmrun`) to
  check the runner.
- **Differential scripts**: SQL sessions (the demos, the corpus's SQL,
  and scripts written for each statement shape and each quirk) run by
  `chidb` and by `tinydb`; stdout compared exactly, then the database
  files with `cmp`. EXPLAIN'd versions of every SELECT shape compare
  the programs.
- **A fuzzer** (the lesson of editor/ and linker/): random schemas,
  random inserts (enough to split pages, and roots, several times),
  random selects of every supported shape with random indexes; rows,
  programs and files compared. The seed first on the command line, as
  the other fuzzers.
- **SQLite as a third check**: every file the differential scripts
  produce is read by Python's `sqlite3`, and its rows compared.
- **Laws**: a B-tree's keys in order, every leaf at the same depth,
  every key found after insert; an index's entries equal to its table's
  (column, key) pairs; `EXPLAIN` then run = run.
- **The .mli examples**, checked in Testo, as for the other programs.

## Phasing

1. The documents (this plan, the tutorial, the related-work note).
2. Pager, Record, Btree, Cursor: read chidb's corpus databases and
   print their rows; then insert, and compare files with chidb's.
3. The machine and `.dbmf`: the non-SQL corpus cases (cursor, flow,
   register, record, insert, index, create).
4. Lexer, Parser, Ast and `.parse`: every corpus and demo statement
   parsed and printed as chidb prints it.
5. Schema, Codegen, the shell: CREATE, INSERT, single-table SELECT;
   then indexes, then NATURAL JOIN; `EXPLAIN` compared at each step;
   the SQL corpus cases.
6. The optimizer and `.opt`.
7. The fuzzer and the SQLite check.
8. `tiny/TinyDatabase.ml`.

## Status

2026-09-24, phases 1 to 7 done in a day; phase 8 (TinyDatabase.ml) to
do.

**Size**: 2,394 lines of `.ml`, `.mll` and `.mly` against the target's
2,600 (8% under; chidb's C about 10,800):

| module | target | actual |
|---|---|---|
| Pager, Record, Btree, Cursor | 510 | 465 |
| Ast, Lexer, Parser, Sql | 620 | 714 |
| Schema, Dbm, Dbmfile | 580 | 416 |
| Codegen, Optimizer | 630 | 502 |
| Shell, CLI, Main | 290 | 297 |

The parser went over: chidb's whole grammar, rule for rule, is 389
lines (decision 5 kept it); the machine and codegen came under, the
variants doing what C's tables and patches did.

**Checked against chidb**, all identical: the course's 131 `.dbmf`
cases (`database/tests/Test.exe`); the B-tree layer alone, byte for
byte, up to 3,000 shuffled rows and a 6,000-entry index
(`btree_differential.sh`); six SQL sessions over every statement
shape, WHERE and index form, the commands and their errors, and
`.parse` over the whole grammar, compared on stdout, stderr and the
file, with SQLite reading every table (`differential.sh`); 160 random
sessions (`fuzz.py`, seeds 1 to 4). `make test` runs the corpus,
`make test-chidb` the rest.

**What the design got wrong, and the tests found**:
- the plan had pages as bytes for the free space; a subtler reason
  showed in the code: whether a child is "full" counts the new leaf
  cell at the child's page type's size (8 bytes against a table's
  internal node), which changes where internal nodes split;
- chidb's lexer keeps being inside a comment from one statement to the
  next (flex's start condition is never reset): kept, as the lexer's
  global state;
- the schema's stored SQL needs the `;` the parser adds;
- chidb crashes or prints garbage in five places
  ([`../plan_bugs_chidb.md`](../plan_bugs_chidb.md)); TinyDb's
  deliberate differences are those;
- the fuzzer found a miscompilation in OCaml's arm64 native code
  (4.11 to 5.3), a stale derived pointer after a minor GC
  ([`../plan_bugs_ocaml.md`](../plan_bugs_ocaml.md)), worked around in
  `Record.types`.

**Left**: `tiny/TinyDatabase.ml`; `.dbmrun` and `-c` are not in the
differential corpus yet; the tutorial is to be checked against the
code, as the earlier ones were.

## Verification

`dune build`, `database/tests/Test.exe` (the corpus and the laws),
`database/tests/differential.sh` (against `~/github/chidb/chidb`),
`database/tests/fuzz.py SEED COUNT`.

## Out of scope

What chidb does not do, since TinyDb is its twin: transactions and a
journal, overflow pages (a row larger than a page), deletes, updates,
joins of three tables, a cost-based optimizer, types other than
4-byte integers and text. The plan of the fork
(`docs/claude_notes/plan_sqlite_extensions.md`) lists them; the
related-work note says where SQLite does each.

## Related work

In [`notes_db_related_work.md`](../related-work/notes_db_related_work.md).
