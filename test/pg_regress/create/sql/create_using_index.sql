-- Converted from create_using_index.test
-- DuckDB create test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/create/create_using_index.test
-- description: Issue #9739 - DuckDB SIGSEGV when creating TABLE CONSTRAINT with non-existing INDEX
-- group: [create]
CREATE TABLE t0 (i INT, CONSTRAINT any_constraint UNIQUE USING INDEX any_non_existed_index);
