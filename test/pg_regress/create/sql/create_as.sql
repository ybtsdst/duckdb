-- Converted from create_as.test
-- DuckDB create test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/create/create_as.test
-- description: Test CREATE TABLE AS SELECT (CTAS) statements
-- group: [create]
PRAGMA enable_verification;

CREATE TABLE tbl1 AS SELECT 1;

SELECT * FROM tbl1;

CREATE TABLE tbl2 AS SELECT 2 AS f;

SELECT * FROM tbl2;

CREATE OR REPLACE TABLE tbl3 AS SELECT 3;

SELECT * FROM tbl3;

CREATE TABLE tbl1 AS SELECT 3;

CREATE OR REPLACE TABLE tbl1 AS SELECT 4;

SELECT * FROM tbl1;

CREATE OR REPLACE TABLE tbl1 AS SELECT 'hello' UNION ALL SELECT 'world';

SELECT * FROM tbl1;

CREATE OR REPLACE TABLE tbl1 AS SELECT 5 WHERE false;

SELECT * FROM tbl1;

CREATE TABLE tbl4 IF NOT EXISTS AS SELECT 4;

CREATE OR REPLACE TABLE tbl4 IF NOT EXISTS AS SELECT 4;

-- CREATE TABLE t(col1, col2) AS SELECT ...
CREATE TABLE tbl4(col1, col2) AS SELECT 1, 'hello';

SELECT * FROM tbl4;

CREATE OR REPLACE TABLE tbl4(col1, col2) AS SELECT 2, 'duck';

SELECT * FROM tbl4;

CREATE TABLE IF NOT EXISTS tbl5(col1, col2) AS SELECT 3, 'database';

SELECT * FROM tbl5;

-- define a column name need quote
CREATE OR REPLACE TABLE tbl5(col1, "col need ' quote") AS SELECT 3.5, 'quote';

SELECT * FROM tbl5;

-- colname and query mismatch
CREATE TABLE tbl6(col1) AS SELECT 4 ,'mismatch';

SELECT * FROM tbl6;

CREATE TABLE tbl7(col1, col2) AS SELECT 5;

-- WITH NO DATA / WITH DATA
CREATE TABLE tbl8 AS SELECT 42 WITH NO DATA;

SELECT COUNT(*) FROM tbl8;

CREATE TABLE tbl9 AS SELECT 42 WITH DATA;

SELECT COUNT(*) FROM tbl9;
