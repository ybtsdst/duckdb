-- Converted from test_create_table_parallelism.test
-- DuckDB catalog/table test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/catalog/table/test_create_table_parallelism.test
-- description: Test parallel table creation
-- group: [table]
PRAGMA enable_verification;

PRAGMA threads=4;

PRAGMA verify_parallelism;

CREATE TABLE test AS (SELECT string_agg(range::VARCHAR, '🦆 ') AS s, mod(range, 10000) xx FROM range(50000) GROUP BY xx);

CREATE TABLE test2 AS (SELECT unnest(string_split(s, ' ')) FROM test);

SELECT count(*) FROM test2;

CREATE TABLE test3 AS (SELECT * FROM test ORDER BY xx);

SELECT count(*) FROM test3;

