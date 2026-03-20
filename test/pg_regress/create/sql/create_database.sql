-- Converted from create_database.test
-- DuckDB create test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/create/create_database.test
-- description: The binder error from the feature not yet being supported in DuckDB
-- group: [create]
CREATE DATABASE mydb;

CREATE DATABASE mydb FROM './path';

DROP DATABASE mydb;
