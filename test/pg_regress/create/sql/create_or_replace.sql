-- Converted from create_or_replace.test
-- DuckDB create test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/create/create_or_replace.test
-- description: Test CREATE OR REPLACE TABLE
-- group: [create]
PRAGMA enable_verification;

CREATE TABLE integers(i INTEGER);

CREATE OR REPLACE TABLE integers(i INTEGER, j INTEGER);

CREATE VIEW integers2 AS SELECT 42;

CREATE OR REPLACE TABLE integers2(i INTEGER);

CREATE TABLE IF NOT EXISTS integers(i INTEGER);

INSERT INTO integers VALUES (1, 2);

CREATE OR REPLACE TABLE IF NOT EXISTS integers(i INTEGER);
