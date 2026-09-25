# A relational database, from scratch: a tutorial for `database/`

What a database does, and how chidb (a teaching version of SQLite)
does it: a file of pages, B-trees in the pages, rows packed into
records, a table of tables, a small machine with registers and
cursors that runs compiled SQL, the compiler from SQL to that
machine, indexes, and an optimizer that moves a condition down a
join. It is written for **a reader of mini-chidb's code, not a user of
SQL**, and explains the ideas in the order the code needs them,
bottom up, as the layers are built.

It is the specification of the program planned in
[`plan_db.md`](../plans/plan_db.md), written before the code, to be
checked against it as the earlier tutorials were. Every example below
was run on the fork's chidb (`~/github/chidb/chidb`) on 2026-09-24.
Companions:
[`notes_db_related_work.md`](../related-work/notes_db_related_work.md)
and the twin, chidb's C (`~/github/chidb/src`).

## 0. Where the code is, and a reading order

| module (`database/`) | what | section |
|---|---|---|
| `Pager` | the file as numbered pages; the header | §2 |
| `Record` | a row's values, packed | §3 |
| `Btree` | table and index B-trees: find, insert, split | §4 |
| `Schema` | the table of tables, on page 1 | §5 |
| `Cursor` | walking a B-tree in key order; seeking | §6 |
| `Dbm` | the machine: instructions, registers, cursors | §6 |
| `Lexer`, `Parser`, `Ast` | SQL to the relational algebra | §7 |
| `Codegen` | the algebra to a program | §8, §9 |
| `Optimizer` | pushing a selection down a join | §10 |
| `Dbmfile`, `Shell`, `CLI` | `.dbmf` programs; the shell | §11 |

Read §1 for the question, §2-§5 for the file, §6 for the machine,
§7-§10 for the compiler, and §11-§14 for the shell, how mini-chidb
differs from its twin, how it is tested, and the exercises.

## 1. What a database is

The demo that ships with chidb (`demos/library.sql`), shortened:

```
   CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT, author TEXT, year INTEGER);
   INSERT INTO books VALUES(1, "The Pragmatic Programmer", "Hunt & Thomas", 1999);
   INSERT INTO books VALUES(2, "Structure and Interpretation of Computer Programs", "Abelson & Sussman", 1985);
   INSERT INTO books VALUES(3, "The C Programming Language", "Kernighan & Ritchie", 1978);
   INSERT INTO books VALUES(4, "Design Patterns", "Gamma et al.", 1994);
   SELECT title FROM books WHERE year < 1990;
     Structure and Interpretation of Computer Programs
     The C Programming Language
   CREATE INDEX idxYear ON books(year);
   SELECT title FROM books WHERE year > 1985;
     Design Patterns
     The Pragmatic Programmer
```

Three things to notice. The data outlives the program: it is in a
file (`/tmp/library.cdb`), and the next run finds it. The question
is asked in SQL, which says *what* rows are wanted, not how to find
them. And the last answer comes out in a different order from the
table's (1994 before 1999): after `CREATE INDEX`, chidb answers the
same kind of question another way, by walking the index on `year` in
year order. How it chooses, and what "walking an index" is, is most
of this tutorial.

The layers, each using only the one below (chidb's are SQLite's):

```
   SQL text          SELECT title FROM books WHERE year > 1985
     | Lexer, Parser
   relational algebra   Project([title], Select(year > 1985, Table(books)))
     | Optimizer, Codegen
   a program          Integer 3 0; OpenRead 0 0; ... SeekGt ...; Next ...; Halt
     | Dbm (the machine)
   cursors, records   rows in key order, values unpacked
     | Btree
   pages              1,024 bytes each, numbered from 1
     | Pager
   the file
```

## 2. The file: pages

A database file is a sequence of **pages** of the same size, 1,024
bytes in chidb, numbered from 1. The pager reads and writes whole
pages; everything above it thinks in pages, never in file offsets.
Page 1 starts with a 100-byte **header**, SQLite's, with chidb's fixed
values. A database with one table of one row, as `xxd` shows it (only
the non-zero lines):

```
   00000000: 5351 4c69 7465 2066 6f72 6d61 7420 3300  SQLite format 3.
   00000010: 0400 0101 0040 2020 0000 0000 0000 0000  .....@  ........
   00000020: 0000 0000 0000 0000 0000 0000 0000 0001  ................
   00000030: 0000 4e20 0000 0000 0000 0001 0000 0000  ..N ............
   00000060: 0000 0000 0d00 6e00 0103 9e00 039e 0000  ......n.........
   ...                                                   (page 1's cells, at 0x39e)
   00000400: 0d00 0a00 0103 eb00 03eb 0000 0000 0000  ................  (page 2)
```

`0400` at offset 16 is the page size, 1,024. chidb refuses a file
whose header differs from these values anywhere it checks (its three
corrupt-header test files each change one field: the magic string, a
byte at offset 60, the 4-byte value at 48), and a new file gets
exactly this header. The file is 2,048 bytes: two pages, page 1 for
the schema (§5) and page 2 for the table.

## 3. Records: a row as bytes

A row is packed into a **record**: a header saying each field's type,
then the fields. The row `(1, "ab", 300)` of `t(id INTEGER PRIMARY
KEY, name TEXT, n INTEGER)` is, at the end of page 2:

```
   07                header size: 7 bytes
   00                field 0: NULL (the primary key is stored elsewhere, §4)
   80 80 80 11       field 1: text of length (17-13)/2 = 2
   04                field 2: a 4-byte integer
   61 62             "ab"
   00 00 01 2c       300
```

The types are SQLite's serial types, cut to four: 0 NULL, 1, 2 and 4
for 1-, 2- and 4-byte integers, and `2n+13` for a text of `n` bytes.
Two chidb specifics: a text's type is written as a **varint of four
bytes always** (`80 80 80 11`, seven bits per byte, the high bit
saying "more follows"), where SQLite uses as few bytes as the value
needs; and the integers chidb's machine *writes* are always 4 bytes
(its record module packs and reads all three sizes, which its unit
tests exercise, but no test database has a 1- or 2-byte integer:
checked, their rows use only NULL, 4-byte integers and text). The primary key's
field is NULL because its value is the row's **key** in the B-tree,
not stored twice (SQLite does the same with an INTEGER PRIMARY KEY,
which is why SQLite reads these files: checked, SQLite 3.45 gives
`(1, 'ab', 300)`).

## 4. B-trees: tables and indexes

A table is a **B-tree** keyed by the primary key: its leaves hold the
rows, in key order, and its internal nodes hold keys and the pages of
their children, so that finding a key reads one page per level.
Each node is one page, laid out as:

```
   header      type (0x0D table leaf, 0x05 table internal, 0x0A index leaf,
               0x02 index internal), where free space starts, the number
               of cells, where the cells start, (internal) the right child
   cell offsets   2 bytes per cell, in key order          --> grows down
   free space
   cells       packed from the end of the page             <-- grows up
```

A cell is, by page type: a table leaf's `(size, key, record)`, a table
internal node's `(child, key)` -- the child holds the keys `<= key` --,
an index leaf's `(indexed value, primary key)`, an index internal
node's the same with a child. An **index** is a B-tree whose keys are
the indexed column's values and whose "rows" are the primary keys
where they occur: to find `year = 1994`, find 1994 in the index, get
its primary key 4, find 4 in the table.

**Inserting** walks down to the leaf where the key belongs and puts
the cell there. When a node is full it is **split**: its lower half
goes to a new page, and its median key is promoted into the parent,
pointing to that new page. chidb splits *on the way down* (a full
child is split before descending into it), so there is always room in
the parent for the promoted key. And the root never moves (its page
number is recorded in the schema): a full root is copied to a new
page, becomes an internal node with that page as its only child, and
the copy is split. With rows of about 50 bytes, 20 fit in the
table's root, page 2; the 21st splits it:

```
   20 rows:   page 2: leaf [1 .. 20]

   21 rows:   page 2: internal [(4, 11)] right = 3       the root, same page
              page 4: leaf [1 .. 11]                     new: the lower half, median 11 included
              page 3: leaf [12 .. 21]                    the root's copy, keeping the upper half

   32 rows:   page 2: internal [(4, 11), (5, 22)] right = 3
              page 4: leaf [1 .. 11]
              page 5: leaf [12 .. 22]                    page 3's lower half, split off
              page 3: leaf [23 .. 32]
```

(Checked on chidb, inserting `(i, "name number i padded to be
longer")`.) A split leaves the old cells' bytes where they were in
the page that keeps the upper half: they are in its free space now,
unreferenced. mini-chidb writes the same bytes, so that its files are
chidb's byte for byte (the plan, decision 2).

## 5. The schema: a table of tables

Where is table `t`? Page 1 is itself a table B-tree, the **schema
table**, with one row per table and per index: its type, its name,
the table it belongs to, its root page, and the SQL that created it.
The one-row database of §2 has, in page 1:

```
   ("table", "t", "t", 2, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, n INTEGER);")
```

The columns of a table are not stored anywhere else: to know them,
chidb parses that CREATE TABLE again. An index's column, likewise,
from its CREATE INDEX. SQLite's schema table (`sqlite_master`) has
the same five columns, which is the other reason SQLite reads chidb's
files.

## 6. The machine: registers, cursors, a program

SQL is not run directly. It is compiled to a program for a small
**machine** (chidb's DBM, after SQLite's VDBE), with numbered
**registers** holding values (NULL, a 4-byte integer, a text, a packed
record) and numbered **cursors**, each open on a B-tree and positioned
on one of its entries. An instruction is an opcode and up to four
operands, `p1 p2 p3 p4`, whose meaning depends on the opcode.
`SELECT name FROM t WHERE n > 100`, as `EXPLAIN` prints it:

```
   addr  opcode     p1   p2   p3        what
      0  Integer     2    0    0        r0 := 2              (t's root page)
      1  OpenRead    0    0    3        cursor 0 := t, from r0, 3 columns
      2  Integer   100    1    0        r1 := 100
      3  Rewind      0    9    0        cursor 0 to its first row; if none, go to 9
      4  Column      0    2    2        r2 := column 2 (n) of cursor 0's row
      5  Le          1    8    2        if r2 <= r1, go to 8  (the WHERE, negated)
      6  Column      0    1    3        r3 := column 1 (name)
      7  ResultRow   3    1    0        a row: 1 register from r3
      8  Next        0    4    0        cursor 0 to its next row; if there is one, go to 4
      9  Close       0    0    0
     10  Halt        0    0    0
```

This is a loop over the table, in key order, with the condition
compiled as a jump *over* the row when it is false: `n > 100` becomes
"if `n <= 100`, skip". `ResultRow` hands a row to the caller and the
machine resumes after it. The machine is a loop: fetch the
instruction at `pc`, do it, and go to `pc + 1` unless it jumped.

**A cursor**, in chidb, is a snapshot: opening it reads the whole
B-tree into an array in key order, and moving it moves along the
array. The textbook cursor instead keeps a stack of (page, cell)
positions from the root, and moves in place; the snapshot is simpler
and, since a statement never reads a table it is changing, gives the
same results.

## 7. SQL to the relational algebra

The parser turns SQL into a tree of **relational algebra**, Codd's
operators on tables: `Table(t)`, `Select(condition, r)` (the rows of
`r` for which the condition holds -- σ, which SQL calls WHERE),
`Project(columns, r)` (π, SQL's column list), `NaturalJoin(r1, r2)`
(⋈). chidb's `.parse` shows it:

```
   chidb> .parse "SELECT a, t.b FROM t NATURAL JOIN u WHERE a = 3 AND b > 'x';"
   Project([a, t.b],
   	Select(a = int 3 and b > char 'x',
   		NaturalJoin(
   			Table(t),
   			Table(u)
   		)
   	)
   )
```

(`char 'x'`: a one-character string literal is a `char`, a quirk of
chidb's grammar.) The grammar accepts more than the compiler
compiles -- outer joins, UNION, GROUP BY, aggregates --; those are
parsed and printed, and refused later.

## 8. Compiling: CREATE, INSERT, SELECT

Each statement shape has its program. **CREATE TABLE** inserts a row
into the schema table: open page 1 for writing, allocate the new
table's root (`CreateTable` puts its page number in a register), build
the five-column record (`MakeRecord`), insert it with the next free
key. **INSERT** builds the row's record (NULL for the primary key),
inserts it with the primary key as its key, and then, for each index
on the table, inserts `(indexed value, primary key)` into the index:

```
   INSERT INTO t VALUES(2, "cd", 5):
      0  Integer     2  0  0      r0 := t's root
      1  OpenWrite   0  0  3
      2  Integer     2  1  0      r1 := the key, 2
      3  Null        0  2  0      r2 := NULL        (the primary key's field)
      4  String      2  3  0  cd  r3 := "cd"
      5  Integer     5  4  0      r4 := 5
      6  MakeRecord  2  3  5      r5 := the record of r2..r4
      7  Insert      0  5  1      insert r5 at key r1
      8  Close       0  0  0
      9  Halt        0  0  0
```

**SELECT** from one table is the scan of §6, one `Column` (or `Key`,
for the primary key) per output column, and one negated comparison
per conjunct of the WHERE, which must be `column OP literal` ANDed
together.

## 9. Indexes and joins

With an index on the WHERE's column, a **seek** replaces the scan.
`SELECT title FROM books WHERE year = 1994`, with `idxYear`:

```
      0  Integer     3  0  0      r0 := the index's root
      1  OpenRead    0  0  0      cursor 0: the index
      2  Integer     2  1  0
      3  OpenRead    1  1  4      cursor 1: the table
      4  Integer  1994  2  0
      5  Seek        0 10  2      the index to 1994; if absent, go to 10
      6  IdxPKey     0  3  0      r3 := its primary key
      7  Seek        1 10  3      the table to that key
      8  Column      1  1  4
      9  ResultRow   4  1  0
     10  Close ...
```

No loop: chidb's indexes are unique, so there is one match at most.
For `year > 1985` it seeks the first entry greater (`SeekGt`) and
walks forward with `Next` -- which is why §1's answer came out in
year order. Which access to use is decided by the **shape** of the
WHERE (one comparison on an indexed column, or a range `c > a AND c <
b` on one), not by an estimate of the cost, as a real optimizer
would.

A **NATURAL JOIN** of two tables is a pair of nested loops, the
inner table scanned once per row of the outer, keeping the pairs that
agree on the columns the two tables share:

```
   SELECT title, name FROM courses NATURAL JOIN departments   (shared column: id)
      4  Rewind   0 14      the outer loop, over courses
      5  Rewind   1 13      the inner loop, over departments
      6  Column   0  2  2   r2 := courses.id
      7  Key      1  3      r3 := departments.id (its primary key)
      8  Ne       2 12  3   if they differ, next inner row
      9  Column   0  1  4
     10  Column   1  1  5
     11  ResultRow 4  2
     12  Next     1  6
     13  Next     0  5
```

## 10. The optimizer: pushing a selection down

In `Select(courses.code > 150, NaturalJoin(courses, departments))`,
the condition is checked for every *pair* of rows, though it only
looks at `courses`. Moving it next to its table checks it once per
row of `courses`, before the inner loop runs at all -- and, if `code`
is indexed, turns that side into an index seek. chidb's `.opt` shows
the tree before and after:

```
   Project([title],                        Project([title],
   	Select(courses.code > int 150,          	NaturalJoin(
   		NaturalJoin(                        		Select(courses.code > int 150,
   			Table(courses),                     			Table(courses)
   			Table(departments)                  		),
   		)                                   		Table(departments)
   	)                                       	)
   )                                       )
```

This is **σ-pushing**, the first rule of every query optimizer: a
selection commutes with a join when it mentions one side only. chidb
splits the WHERE into its conjuncts and pushes each one that touches
a single table; the rest stays on top. It is a function from a tree
to a tree.

## 11. The shell

`mini-chidb [file]` reads lines: a line starting with `.` is a shell
command (`.open`, `.headers on`, `.mode column`, `.explain on`,
`.parse`, `.opt`, `.dbmrun`, `.help`), anything else is SQL. Rows are
printed separated by `|` (`.mode list`) or in 10-character columns
(`.mode column`, and `.explain on`, which truncates to 10: `CreateTable`
prints as `CreateTabl`). The prompt `chidb> ` is printed even when the
input is a file, as chidb does. `.dbmrun` runs a program written in
the machine's language directly, the format of the course's test
cases (`.dbmf`).

## 12. Compared with chidb and SQLite

mini-chidb is chidb's twin: the same files, the same programs, the same
output. Inside, C's unions and integer codes are OCaml variants: an
instruction is `Integer of int32 * reg | Column of cursor * int * reg |
...`, a cell is one of four constructors, a register's value is
`Null | Int | Text | Record`, and codegen emits labels resolved by a
pass instead of patching addresses. SQLite is what chidb is cut from:
the same file format and layers, with transactions and a journal,
overflow pages, every SQL statement, a cost-based optimizer, and a
VDBE of about 180 opcodes to chidb's 37 (chidb's notes).

## 13. How it is tested

Against chidb, three ways: the rows the shell prints, the programs
`EXPLAIN` prints, and the database files, byte for byte. The course's
131 `.dbmf` cases are the corpus; a fuzzer generates schemas, inserts
enough to split pages, and queries of every supported shape. And
SQLite reads every file mini-chidb writes, and must give the same rows.

## 14. Exercises

1. Replace the snapshot cursor by a stack of (page, cell) positions,
   and measure a scan of a large table.
2. Add `DELETE`: removing a cell is easy; merging an underfull node is
   the B-tree's other half.
3. Choose between the scan and the seek by an estimated cost (the
   number of rows, the selectivity of the condition), as System R
   did; find a query where chidb's rule chooses wrong.
4. Add overflow pages, so that a row can be larger than a page.

## Glossary

- **page**: the unit of the file, 1,024 bytes, numbered from 1.
- **cell**: an entry in a B-tree node: a row, a key and a child, or
  an index entry.
- **record**: a row's values packed as bytes, a header of types then
  the values.
- **schema table**: page 1's B-tree, one row per table and index.
- **cursor**: a position in a B-tree, moved in key order.
- **register**: a numbered value of the machine.
- **σ, π, ⋈**: selection (WHERE), projection (the column list),
  natural join.
