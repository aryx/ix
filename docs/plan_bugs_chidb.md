# Bugs found in chidb

What TinyDb's differential tests found in the author's chidb fork
(`~/github/chidb`, the binary `chidb`), for the author to decide. Each
is a deliberate difference in TinyDb, which does not crash there;
checked on 2026-09-24.

| input | chidb | why | TinyDb |
|---|---|---|---|
| a line `;` (or only empty statements) | segmentation fault | `sql_line`'s empty rule leaves `__stmt->type` uninitialized, and codegen switches on it | `SQL syntax error.` |
| `INSERT INTO t (a) VALUES(1, 2)` (more values than columns named, or fewer) | segmentation fault | `Insert_make` prints its error and returns NULL, which the parser stores and codegen dereferences | the error line, then `SQL syntax error.` |
| `.parse "SELECT a FROM t WHERE a IN (SELECT b FROM u);"` | prints `[%s (unknown type)]` | the `IN '(' select ')'` rule warns and leaves `$$` unset | prints `[]` after the same warning |
| `SELECT * FROM t NATURAL JOIN u` where a shared column is TEXT in one table and INTEGER in the other | segmentation fault | the natural-join check `Ne` compares an integer register with a text one; `reg_compare` takes the first's type and calls `strcmp` on the integer | the statement stops, printing nothing (a debug trace with `IX_LOG=debug`) |
| `INSERT` of a text into a TEXT primary key (or a first column that is TEXT when no column is the key) | uses the text's pointer as the key | codegen reads `val.ival` of a text literal | `SQL syntax error.` |

Not bugs but chidb's behaviour, kept in TinyDb (see
`database/tests/corpus/errors.sql`): after a line `-- comment`, the
lexer stays in the comment for the following statements (flex's start
condition is global and never reset), so they are syntax errors until
a statement containing a newline.
