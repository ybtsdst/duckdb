-- Converted from create_index_on_issue_13643.test
-- DuckDB create test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/create/create_index_on_issue_13643.test
-- description: Issue #13643 - USE not affecting tables referenced after the ON keyword in CREATE INDEX
-- group: [create]
CREATE SCHEMA db0;

USE db0;

CREATE TABLE t0 (a BIGINT PRIMARY KEY, b INT, c INT);

CREATE INDEX t0_idx ON t0 (b);

CREATE UNIQUE INDEX t0_uidx ON t0 (c);

CREATE UNIQUE INDEX t0_uidx2 ON db0.t0 (c);
