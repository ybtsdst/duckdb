-- Converted from bc_timestamp.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/bc_timestamp.test
-- description: Test BC timestamps
-- group: [timestamp]


SELECT '1969-01-01 01:03:20.45432'::TIMESTAMP::VARCHAR;


SELECT '-1000-01-01 01:03:20.45432'::TIMESTAMP::VARCHAR;


SELECT '1000-01-01 (BC) 01:03:20.45432'::TIMESTAMP::VARCHAR;
