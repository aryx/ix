CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, n INTEGER);
INSERT INTO t VALUES(1, "one", 100);
INSERT INTO t VALUES(3, "three", 300);
INSERT INTO t VALUES(2, 'two', 200);
INSERT INTO t VALUES(5, "x", -7);
SELECT * FROM t;
SELECT name FROM t;
SELECT n, id, name FROM t;
SELECT t.name, id FROM t;
select NAME from T;
.headers on
SELECT * FROM t;
.mode column
SELECT * FROM t;
.headers off
SELECT name, n FROM t;
.mode list
SELECT id FROM t
