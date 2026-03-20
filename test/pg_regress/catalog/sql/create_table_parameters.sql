-- Converted from create_table_parameters.test
-- DuckDB catalog/table test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/catalog/table/create_table_parameters.test
-- description: Issue #10008 - DuckDB SIGSEGV when creating table with DEFAULT ?
-- group: [table]
CREATE TABLE t0 ( c1 INT DEFAULT ? );

CREATE TABLE t0 ( c1 INT CHECK (?) );

