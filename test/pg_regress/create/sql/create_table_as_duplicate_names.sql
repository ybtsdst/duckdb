-- Converted from create_table_as_duplicate_names.test
-- DuckDB create test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/create/create_table_as_duplicate_names.test
-- description: Test CREATE TABLE AS with duplicate column names
-- group: [create]
PRAGMA enable_verification;

SELECT * FROM range(5) tbl1(i) JOIN range(5) tbl2(i) ON tbl1.i=tbl2.i ORDER BY 1, 2;

SELECT i, i FROM range(5) tbl(i);

SELECT * FROM (SELECT i, i FROM range(5) tbl(i)) tbl;

SELECT * FROM (SELECT i, i, i, i FROM range(5) tbl(i)) tbl;

CREATE TABLE t1 AS SELECT i, i FROM range(5) tbl(i);

SELECT * FROM t1;

CREATE TABLE t2 AS SELECT i, i, i, i FROM range(5) tbl(i);

SELECT * FROM (SELECT i, i, i, i FROM range(5) tbl(i)) tbl;

SELECT * FROM (SELECT * FROM range(5) tbl1(i) JOIN range(5) tbl2(i) ON tbl1.i=tbl2.i) tbl ORDER BY 1, 2;

CREATE TABLE t3 AS SELECT tbl1.i, tbl2.i FROM range(5) tbl1(i) JOIN range(5) tbl2(i) ON tbl1.i=tbl2.i;

SELECT * FROM t3 ORDER BY 1, 2;

CREATE TABLE t4 AS SELECT * FROM range(5) tbl1(i) JOIN range(5) tbl2(i) ON tbl1.i=tbl2.i;

SELECT * FROM t4 ORDER BY 1, 2;
