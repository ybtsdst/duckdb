-- Converted from alternative_timestamp_casts.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/alternative_timestamp_casts.test
-- description: Test timestamp casts
-- group: [timestamp]


PRAGMA enable_verification;


SELECT DATE '1992-01-01'::TIMESTAMP_MS;


SELECT DATE '1992-01-01'::TIMESTAMP_S;


SELECT DATE '1992-01-01'::TIMESTAMP_NS;


select '2023-12-08 08:51:39.123456'::TIMESTAMP_MS::TIME;


select '2023-12-08 08:51:39.123456'::TIMESTAMP_S::TIME;


select '2023-12-08 08:51:39.123456'::TIMESTAMP_NS::TIME;

-- Rounding

select '2024-05-10 11:06:33.446'::TIMESTAMP_S;


select '2024-05-10 11:06:33.846'::TIMESTAMP_S;


select '2024-05-10 11:06:33.123446'::TIMESTAMP_MS;


select '2024-05-10 11:06:33.123846'::TIMESTAMP_MS;

-- Rounding

CREATE TABLE issue11995 (t TIMESTAMP);


INSERT INTO issue11995 VALUES 
	('2024-05-10 11:06:33.446'), 
	('2024-05-10 11:06:33.846'),
	('2024-05-10 11:06:33.123446'),
	('2024-05-10 11:06:33.523846');


SELECT t, t::TIMESTAMP_MS, t::TIMESTAMP_S
FROM issue11995;

-- Negative rounding

select '1900-01-01 03:08:47'::TIMESTAMP::TIMESTAMP_MS;
