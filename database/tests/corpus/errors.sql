SELECT * FROM t;
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE T(x INTEGER PRIMARY KEY);
INSERT INTO t VALUES(1, "a");
INSERT INTO t VALUES(1, "b");
INSERT INTO t VALUES(2);
INSERT INTO t VALUES(2, "b", 3);
INSERT INTO t VALUES("x", "b");
INSERT INTO t VALUES(2, 5);
INSERT INTO t VALUES(2, 2.5);
INSERT INTO nosuch VALUES(1);
INSERT INTO t (id, name) VALUES(3, "c");
SELECT * FROM t;
SELEC x;
SELECT FROM t;
SELECT a FROM t WHERE a = 1 b;
SELECT * FROM t WHERE id = 1; SELECT name FROM t;
SELECT id FROM t; INSERT INTO t VALUES(4, "d");
SELECT * FROM t;
DELETE FROM t WHERE id = 1;
SELECT COUNT(*) FROM t;
SELECT id + 1 FROM t;
SELECT DISTINCT id FROM t;
SELECT id FROM t ORDER BY id;
SELECT * FROM t UNION SELECT * FROM t;
SELECT * FROM t LEFT JOIN t;
SELECT * FROM t, t;
.nosuch
.
.op
.openx
.headers
.headers maybe
.headers on off
.mode
.mode rows
.explain
.explain maybe
.parse
.opt
.dbmrun
.dbmrun /nonexistent.dbmf
.help
.open /nonexistent/dir/db.cdb
-- a comment
/* another */ SELECT id FROM t;
SELECT id FROM t -- trailing
SELECT id /* unclosed
