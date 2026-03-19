-- Converted from create_table_as_error.test
-- DuckDB create test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/create/create_table_as_error.test
-- description: Test incorrect usage of CREATE TABLE AS
-- group: [create]
PRAGMA enable_verification;

CREATE TABLE tbl AS EXECUTE tbl;
