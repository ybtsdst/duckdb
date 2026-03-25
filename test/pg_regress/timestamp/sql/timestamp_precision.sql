-- Converted from timestamp_precision.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/timestamp_precision.test
-- description: Test timestamp precision
-- group: [timestamp]


PRAGMA enable_verification;


CREATE TABLE ts_precision(
	sec TIMESTAMP(0),
	msec TIMESTAMP(3),
	micros TIMESTAMP(6),
	nanos TIMESTAMP (9)
);


INSERT INTO ts_precision VALUES ('2020-01-01 01:23:45.123456789', '2020-01-01 01:23:45.123456789', '2020-01-01 01:23:45.123456789', '2020-01-01 01:23:45.123456789');


SELECT sec::VARCHAR, msec::VARCHAR, micros::VARCHAR, nanos::VARCHAR FROM ts_precision;


SELECT EXTRACT(microseconds FROM sec), EXTRACT(microseconds FROM msec), EXTRACT(microseconds FROM micros), EXTRACT(microseconds FROM nanos) FROM ts_precision;

-- we only support precisions 0, 3, 6, and 9
-- any other precision is rounded up (e.g. 1/2 -> 3, 4/5 -> 6, 7/8 -> 9)


SELECT '2020-01-01 01:23:45.123456789'::TIMESTAMP(1);


SELECT '2020-01-01 01:23:45.123456789'::TIMESTAMP(2);



SELECT '2020-01-01 01:23:45.123456789'::TIMESTAMP(4);


SELECT '2020-01-01 01:23:45.123456789'::TIMESTAMP(5);

-- FIXME: nano seconds rendering


SELECT '2020-01-01 01:23:45.123456789'::TIMESTAMP(7);


SELECT '2020-01-01 01:23:45.123456789'::TIMESTAMP(8);

-- unsupported: precision too high

CREATE TABLE ts_precision(sec TIMESTAMP(10));


CREATE TABLE ts_precision(sec TIMESTAMP(99999));

-- timestamp only supports a single modifier

CREATE TABLE ts_precision(sec TIMESTAMP(1, 1));

-- Handle infinite values

SELECT TIMESTAMP_NS '2262-04-11 23:47:16.854775807';
