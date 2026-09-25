# Related work: relational databases, from the model to the teaching systems

Where mini-chidb ([`plan_db.md`](../plans/plan_db.md),
[`notes_db.md`](../tutorials/notes_db.md)) sits among the real
systems. What was checked here is said so, with where; the rest is
**from memory**, marked, to check before it is quoted in a `.mli`
(the README's "References in the code": checked, not quoted from
memory).

## The relational model

- **Codd (1970)**, "A Relational Model of Data for Large Shared Data
  Banks" (CACM; from memory): data as relations, sets of tuples,
  queried by operators independent of how the data is stored. The
  operators mini-chidb's parse tree is made of -- selection σ, projection
  π, join ⋈ -- are the algebra that followed from it. chidb's point
  is to make that algebra the compiler's intermediate representation
  (checked, in the SIGCSE paper below: "a direct encoding of the
  relational algebra").
- **SQL**, from IBM's System R (SEQUEL; from memory), is what won:
  a declarative language whose meaning is the algebra, compiled by the
  system into a plan. mini-chidb's grammar is chidb's subset.

## The systems

- **System R** (IBM San Jose, 1970s; from memory): the first SQL
  system, with a compiler from SQL to access plans and the first
  cost-based optimizer. **Selinger et al. (1979)**, "Access Path
  Selection in a Relational Database Management System" (SIGMOD;
  from memory), chose among scans and index seeks by estimated cost
  and ordered joins by dynamic programming. chidb, and mini-chidb, choose
  by the *shape* of the WHERE instead (the tutorial's §9): the road
  not taken, and an exercise.
- **Ingres** (Stonebraker, Berkeley, 1970s; from memory), System R's
  contemporary, with its own query language, QUEL, and query
  decomposition; the ancestor of Postgres.
- **SQLite** (D. Richard Hipp; checked as the chidb paper cites it:
  "D. R. Hipp. SQLite (http://www.sqlite.org), 2015"): a library
  rather than a server, one file per database, SQL compiled to
  bytecode for a virtual machine (the VDBE). chidb is "its direct
  descendant", and its authors note that "SQLite has no publications
  in the academic record, so we are unable to provide a paper
  citation" (checked, the paper's acknowledgments). What chidb keeps
  of it: the file format as a subset (checked: a chidb file opens in
  SQLite 3.45, primary key and all), the B-tree layer over a pager,
  the schema table's five columns, the prepare/step/finalize API, and
  a bytecode machine of 37 opcodes to the VDBE's about 180 (chidb's
  notes, `docs/claude_notes/notes_sqlite.txt`). What it leaves out:
  transactions and the rollback journal, overflow pages, varints of
  variable length, every type but 4-byte integers and text, deletion,
  a cost-based planner.
- **The Volcano iterator model** (Graefe, 1990s; from memory):
  operators as iterators with open/next/close, pulled from the top,
  the design of most databases' executors. chidb's machine is the
  other design, SQLite's: the plan compiled to one flat program with
  jumps. The tutorial's exercise to interpret the algebra directly is
  the iterator road.

## Pipelines instead of SELECT

What `tiny/TinyDatabase.ml` takes instead of SQL, all from memory:

- **QUEL** (Ingres, above) and **Datalog** show that SQL's syntax was
  never the only one; what stayed was the algebra underneath.
- **Pipe syntax**: Unix pipes (McIlroy), then query languages built as
  a chain of stages, each taking the previous one's table: Splunk's
  SPL, Microsoft's Kusto (KQL), PRQL (2022), and Google's pipe syntax
  for SQL (Shute et al., "SQL Has Problems. We Can Fix Them: Pipe
  Syntax In SQL", VLDB 2024), which argues that SQL's fixed clause order
  is its main usability defect. In all of them a query is the
  algebra's operators in the order they run.

## Copy-on-write trees

- **Rodeh (2008)**, "B-trees, Shadowing, and Clones" (ACM Transactions
  on Storage; from memory): B-trees that never change a node in place,
  a change copying the path to the root; the design of btrfs.
- **LMDB** (Howard Chu, 2011; from memory) and before it
  **System R's shadow pages** (Lorie, 1977; from memory): a commit is
  the switch to a new root, so a crash leaves the old one whole and
  there is no log to replay. LMDB reuses freed pages; TinyDatabase.ml,
  like an append-only log, does not.

## B-trees

- **Bayer and McCreight (1972)**, "Organization and Maintenance of
  Large Ordered Indices" (Acta Informatica; from memory): the B-tree,
  a balanced tree of pages with between `d` and `2d` keys each, so that
  a search reads one page per level of a tree of logarithmic height.
- **Comer (1979)**, "The Ubiquitous B-Tree" (ACM Computing Surveys;
  from memory): the survey, and the B+-tree variant where the leaves
  hold the data and the internal nodes only keys -- which is what a
  table B-tree is in SQLite and chidb (an index B-tree keeps entries
  in its internal nodes too, as the plain B-tree does).
- chidb's own insertion is the textbook's "split on the way down"
  (a full child is split before descending into it), with SQLite's
  convention that the root keeps its page (checked in its code and on
  its files: the tutorial's §4).

## Teaching databases

All checked, from the chidb paper's references (Sotomayor and Shaw,
"chidb: Building a Simple Relational Database System from Scratch",
SIGCSE '16, Memphis, DOI 10.1145/2839509.2844638):

- **chidb** itself: "a quarter-long C programming project where
  students have to implement a relational database management system
  (RDBMS) largely from scratch, from the file-based B-trees all the way
  up to the SQL compiler", run five times in the University of
  Chicago's undergraduate databases course. Four assignments: the
  B-tree, the database machine, the code generator, the optimizer.
  The fork mini-chidb twins has all four, the optimizer's σ-pushing
  included, and extensions (range seeks, both sides of a join seeked).
- **SimpleDB** (Sciore, SIGCSE 2007, and the book *Database Design and
  Implementation*, Wiley 2008): a Java multiuser system for teaching
  internals.
- **Minibase** (Ramakrishnan, 1996), the companion of his textbook.
- **MinSQL** (Swart, PPPJ '03): a componentized database for the
  classroom.
- **Ailamaki and Hellerstein (2003)**, "Exposing undergraduate
  students to database system internals" (SIGMOD Record).

Not in the paper, from memory: CMU's BusTub (15-445), MIT's
6.830 SimpleDB (a different one, also Java), and the many "let's
build a SQLite clone" tutorials, which stop, as a rule, before the
optimizer.

## Where mini-chidb sits

mini-chidb is a twin, not a new design: chidb's layers, file and programs,
byte for byte. What it adds is the OCaml representation (instructions,
cells, registers and the algebra as variants; labels instead of
patched jumps; the optimizer as a function) and the tests: chidb's
131 cases, the differential scripts, a fuzzer, and SQLite reading
every file. The free variant, `tiny/TinyDatabase.ml`, is where the
roads not taken go: a copy-on-write B-tree (atomic statements by one
header write), iterators over the algebra instead of the machine, and
the algebra itself as the query language, a pipeline.
