-- Converted from create_table_with_arraybounds.test
-- DuckDB create test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/create/create_table_with_arraybounds.test
-- group: [create]

-- Create a table with an ENUM[] type
create table T (
	vis enum ('hide', 'visible')[]
);

select column_type from (describe T);

attach ':memory:' as db2;

create schema schema2;

create schema db2.schema3;

create type schema2.foo as VARCHAR;

create type db2.schema3.bar as BOOL;

-- Create a table with a USER[] type qualified with a schema
create table B (
	vis schema2.foo[]
);

-- Create a table with a USER[] type qualified with a schema and a catalog
create table B (
	vis db2.schema3.bar[]
);
