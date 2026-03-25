-- Converted from test_timestamp_ms.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/test_timestamp_ms.test
-- description: Test milliseconds with timestamp
-- group: [timestamp]


SELECT CAST('2001-04-20 14:42:11.123' AS TIMESTAMP) a, CAST('2001-04-20 14:42:11.0' AS TIMESTAMP) b;

-- many ms

SELECT TIMESTAMP '2001-04-20 14:42:11.12300000000000000000';
