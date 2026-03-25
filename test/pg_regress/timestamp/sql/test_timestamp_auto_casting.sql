-- Converted from test_timestamp_auto_casting.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/test_timestamp_auto_casting.test
-- description: Test auto-casting of timestamps
-- group: [timestamp]


PRAGMA enable_verification;


CREATE TABLE timestamps(ts_SEC TIMESTAMP_S, ts_MS TIMESTAMP_MS, ts TIMESTAMP, ts_NS TIMESTAMP_NS);

-- FIXME - we don't actually support nanosecond precision in string parsing

INSERT INTO timestamps VALUES ('2000-01-01 01:12:23', '2000-01-01 01:12:23.123', '2000-01-01 01:12:23.123456', '2000-01-01 01:12:23.123457');

-- All of these timestamps are different

SELECT
	ts_SEC=ts_MS,
	ts_SEC=ts,
	ts_SEC=ts_NS,
	ts_MS=ts,
	ts_MS=ts_NS,
	ts=ts_NS,
	ts_MS=ts_SEC,
	ts=ts_SEC,
	ts_SEC=ts_NS,
	ts=ts_MS,
	ts_NS=ts_MS,
	ts_NS=ts,
FROM timestamps;

-- we always prefer the timestamp with the highest precision when auto-casting

SELECT typeof([TIMESTAMP '2000-01-01 01:12:23.123456', TIMESTAMP_NS '2000-01-01 01:12:23.123456']);


SELECT typeof([TIMESTAMP_NS '2000-01-01 01:12:23.123456', TIMESTAMP '2000-01-01 01:12:23.123456']);
