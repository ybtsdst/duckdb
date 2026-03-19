-- Converted from test_create_table_parallelism.test
-- DuckDB catalog/table test suite

-- name: test/sql/catalog/table/test_create_table_parallelism.test
-- description: Test parallel table creation
-- group: [table]
CREATE TABLE test AS (SELECT string_agg(i::VARCHAR, '🦆 ') AS s, mod(i, 10000) xx FROM generate_series(0, 50000-1) AS gs(i) GROUP BY xx);

CREATE TABLE test2 AS (SELECT unnest(string_to_array(s, ' ')) FROM test);

SELECT count(*) FROM test2;

CREATE TABLE test3 AS (SELECT * FROM test ORDER BY xx);

SELECT count(*) FROM test3;

