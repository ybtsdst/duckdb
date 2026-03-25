-- Converted from test_infinite_time.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/test_infinite_time.test
-- description: Extract timestamp function
-- group: [timestamp]


PRAGMA enable_verification;

--
-- Special date and time values from
-- https://www.postgresql.org/docs/14/datatype-datetime.html#DATATYPE-DATETIME-SPECIAL-TABLE
--

-- Case insensitivity


-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'infinity'::TIMESTAMP, '-infinity'::TIMESTAMP;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'Infinity'::TIMESTAMP, '-Infinity'::TIMESTAMP;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'INFINITY'::TIMESTAMP, '-INFINITY'::TIMESTAMP;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'inFinIty'::TIMESTAMP, '-inFinIty'::TIMESTAMP;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'inf'::TIMESTAMP, '-inf'::TIMESTAMP;


-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'infinity'::TIMESTAMPTZ, '-infinity'::TIMESTAMPTZ;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'Infinity'::TIMESTAMPTZ, '-Infinity'::TIMESTAMPTZ;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'INFINITY'::TIMESTAMPTZ, '-INFINITY'::TIMESTAMPTZ;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'inFinIty'::TIMESTAMPTZ, '-inFinIty'::TIMESTAMPTZ;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'inf'::TIMESTAMPTZ, '-inf'::TIMESTAMPTZ;


-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'infinity'::DATE, '-infinity'::DATE;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'Infinity'::DATE, '-Infinity'::DATE;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'INFINITY'::DATE, '-INFINITY'::DATE;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'inFinIty'::DATE, '-inFinIty'::DATE;

-- PG displays numeric infinities in Titlecase but temporal infinities in lowercase

SELECT 'inf'::DATE, '-inf'::DATE;

-- No trailing non-spaces!



SELECT 'infinity 00:00:00'::TIMESTAMP;


SELECT '-infinity 00:00:00'::TIMESTAMP;


SELECT 'epoch 00:00:00'::TIMESTAMP;



SELECT 'infinity 00:00:00'::TIMESTAMPTZ;


SELECT '-infinity 00:00:00'::TIMESTAMPTZ;


SELECT 'epoch 00:00:00'::TIMESTAMPTZ;



SELECT 'infinity 00:00:00'::DATE;


SELECT '-infinity 00:00:00'::DATE;


SELECT 'epoch 00:00:00'::DATE;

-- Table insertion

CREATE TABLE specials (ts TIMESTAMP, tstz TIMESTAMPTZ, dt DATE);


INSERT INTO specials VALUES
	('infinity'::TIMESTAMP, 'infinity'::TIMESTAMPTZ, 'infinity'::DATE),
	('-infinity'::TIMESTAMP, '-infinity'::TIMESTAMPTZ, '-infinity'::DATE),
	('epoch'::TIMESTAMP, 'epoch'::TIMESTAMPTZ, 'epoch'::DATE),;


SELECT * FROM specials;


CREATE TABLE abbreviations (ts TIMESTAMP, tstz TIMESTAMPTZ, dt DATE);


INSERT INTO abbreviations VALUES
	('inf'::TIMESTAMP, 'inf'::TIMESTAMPTZ, 'inf'::DATE),
	('-inf'::TIMESTAMP, '-inf'::TIMESTAMPTZ, '-inf'::DATE),;


SELECT * FROM abbreviations;

--
-- Comparisons
--

-- TIMESTAMP

SELECT lhs.ts, rhs.ts,
	lhs.ts < rhs.ts, lhs.ts <= rhs.ts,
	lhs.ts = rhs.ts, lhs.ts <> rhs.ts,
	lhs.ts >= rhs.ts, lhs.ts > rhs.ts,
FROM specials lhs, specials rhs
ORDER BY 1, 2;

-- TIMESTAMPTZ

SELECT lhs.tstz, rhs.tstz,
	lhs.tstz < rhs.tstz, lhs.tstz <= rhs.tstz,
	lhs.tstz = rhs.tstz, lhs.tstz <> rhs.tstz,
	lhs.tstz >= rhs.tstz, lhs.tstz > rhs.tstz,
FROM specials lhs, specials rhs
ORDER BY 1, 2;

-- DATE

SELECT lhs.dt, rhs.dt,
	lhs.dt < rhs.dt, lhs.dt <= rhs.dt,
	lhs.dt = rhs.dt, lhs.dt <> rhs.dt,
	lhs.dt >= rhs.dt, lhs.dt > rhs.dt,
FROM specials lhs, specials rhs
ORDER BY 1, 2;

--
-- Aggregates
--

SELECT MIN(ts), MAX(ts), MIN(tstz), MAX(tstz), MIN(dt), MAX(dt)
FROM specials;


SELECT MEDIAN(ts), MEDIAN(tstz), MEDIAN(dt)
FROM specials;


SELECT MODE(ts), MODE(tstz), MODE(dt)
FROM specials;


SELECT APPROX_COUNT_DISTINCT(ts), APPROX_COUNT_DISTINCT(tstz), APPROX_COUNT_DISTINCT(dt)
FROM specials;


SELECT ARBITRARY(ts), FIRST(ts), LAST(ts)
FROM specials;


SELECT ARBITRARY(tstz), FIRST(tstz), LAST(tstz)
FROM specials;


SELECT ARBITRARY(dt), FIRST(dt), LAST(dt)
FROM specials;




SELECT ARG_MIN(ts, ts), ARG_MAX(ts, ts) FROM specials;


SELECT ARG_MIN(ts, tstz), ARG_MAX(ts, tstz) FROM specials;


SELECT ARG_MIN(ts, dt), ARG_MAX(ts, dt) FROM specials;



SELECT ARG_MIN(tstz, ts), ARG_MAX(tstz, ts) FROM specials;


SELECT ARG_MIN(tstz, tstz), ARG_MAX(tstz, tstz) FROM specials;


SELECT ARG_MIN(tstz, dt), ARG_MAX(tstz, dt) FROM specials;



SELECT ARG_MIN(dt, ts), ARG_MAX(dt, ts) FROM specials;


SELECT ARG_MIN(dt, tstz), ARG_MAX(dt, tstz) FROM specials;


SELECT ARG_MIN(dt, dt), ARG_MAX(dt, dt) FROM specials;


SELECT HISTOGRAM(ts), HISTOGRAM(tstz), HISTOGRAM(dt)
FROM specials;


SELECT QUANTILE_DISC(ts, 0.32), QUANTILE_DISC(tstz, 0.32), QUANTILE_DISC(dt, 0.32)
FROM specials;


SELECT QUANTILE_DISC(ts, [0.0, 0.5, 1.0]), QUANTILE_DISC(tstz, [0.0, 0.5, 1.0]), QUANTILE_DISC(dt, [0.0, 0.5, 1.0])
FROM specials;


SELECT QUANTILE_CONT(ts, 0.25), QUANTILE_CONT(tstz, 0.25), QUANTILE_CONT(dt, 0.25)
FROM specials;


SELECT QUANTILE_CONT(ts, [0.25, 0.5, 0.75]), QUANTILE_CONT(tstz, [0.25, 0.5, 0.75]), QUANTILE_CONT(dt, [0.25, 0.5, 0.75])
FROM specials;


SELECT MAD(ts), MAD(tstz), MAD(dt)
FROM specials;

-- Treated as physical type

SELECT ENTROPY(ts), ENTROPY(tstz), ENTROPY(dt) FROM specials;

--
-- Arithmetic
--




SELECT 'infinity'::TIMESTAMP + INTERVAL (1) microsecond;


SELECT '-infinity'::TIMESTAMP + INTERVAL (1) microsecond;


SELECT 'infinity'::TIMESTAMP - INTERVAL (1) microsecond;


SELECT '-infinity'::TIMESTAMP - INTERVAL (1) microsecond;


SELECT 'infinity'::TIMESTAMP + INTERVAL (1) second;


SELECT '-infinity'::TIMESTAMP + INTERVAL (1) second;


SELECT 'infinity'::TIMESTAMP - INTERVAL (1) second;


SELECT '-infinity'::TIMESTAMP - INTERVAL (1) second;


SELECT 'infinity'::TIMESTAMP + INTERVAL (1) minute;


SELECT '-infinity'::TIMESTAMP + INTERVAL (1) minute;


SELECT 'infinity'::TIMESTAMP - INTERVAL (1) minute;


SELECT '-infinity'::TIMESTAMP - INTERVAL (1) minute;


SELECT 'infinity'::TIMESTAMP + INTERVAL (1) hour;


SELECT '-infinity'::TIMESTAMP + INTERVAL (1) hour;


SELECT 'infinity'::TIMESTAMP - INTERVAL (1) hour;


SELECT '-infinity'::TIMESTAMP - INTERVAL (1) hour;


SELECT 'infinity'::TIMESTAMP + INTERVAL (1) day;


SELECT '-infinity'::TIMESTAMP + INTERVAL (1) day;


SELECT 'infinity'::TIMESTAMP - INTERVAL (1) day;


SELECT '-infinity'::TIMESTAMP - INTERVAL (1) day;


SELECT 'infinity'::TIMESTAMP + INTERVAL (1) month;


SELECT '-infinity'::TIMESTAMP + INTERVAL (1) month;


SELECT 'infinity'::TIMESTAMP - INTERVAL (1) month;


SELECT '-infinity'::TIMESTAMP - INTERVAL (1) month;


SELECT 'infinity'::TIMESTAMP + INTERVAL (1) year;


SELECT '-infinity'::TIMESTAMP + INTERVAL (1) year;


SELECT 'infinity'::TIMESTAMP - INTERVAL (1) year;


SELECT '-infinity'::TIMESTAMP - INTERVAL (1) year;



SELECT 'infinity'::DATE + INTERVAL (1) microsecond;


SELECT '-infinity'::DATE + INTERVAL (1) microsecond;


SELECT 'infinity'::DATE - INTERVAL (1) microsecond;


SELECT '-infinity'::DATE - INTERVAL (1) microsecond;


SELECT 'infinity'::DATE + INTERVAL (1) second;


SELECT '-infinity'::DATE + INTERVAL (1) second;


SELECT 'infinity'::DATE - INTERVAL (1) second;


SELECT '-infinity'::DATE - INTERVAL (1) second;


SELECT 'infinity'::DATE + INTERVAL (1) minute;


SELECT '-infinity'::DATE + INTERVAL (1) minute;


SELECT 'infinity'::DATE - INTERVAL (1) minute;


SELECT '-infinity'::DATE - INTERVAL (1) minute;


SELECT 'infinity'::DATE + INTERVAL (1) hour;


SELECT '-infinity'::DATE + INTERVAL (1) hour;


SELECT 'infinity'::DATE - INTERVAL (1) hour;


SELECT '-infinity'::DATE - INTERVAL (1) hour;


SELECT 'infinity'::DATE + INTERVAL (1) day;


SELECT '-infinity'::DATE + INTERVAL (1) day;


SELECT 'infinity'::DATE - INTERVAL (1) day;


SELECT '-infinity'::DATE - INTERVAL (1) day;


SELECT 'infinity'::DATE + INTERVAL (1) month;


SELECT '-infinity'::DATE + INTERVAL (1) month;


SELECT 'infinity'::DATE - INTERVAL (1) month;


SELECT '-infinity'::DATE - INTERVAL (1) month;


SELECT 'infinity'::DATE + INTERVAL (1) year;


SELECT '-infinity'::DATE + INTERVAL (1) year;


SELECT 'infinity'::DATE - INTERVAL (1) year;


SELECT '-infinity'::DATE - INTERVAL (1) year;


SELECT dt + 1, dt - 1 FROM specials;


SELECT dt + '12:34:56'::TIME FROM specials;

-- Is(Infinite)


SELECT isfinite(ts), isfinite(tstz), isfinite(dt)
FROM specials;


SELECT isinf(ts), isinf(tstz), isinf(dt)
FROM specials;

-- Casts


select ts::VARCHAR, tstz::VARCHAR, dt::VARCHAR FROM specials;


select ts::TIME, tstz::TIME, dt::TIME FROM specials;


select 'infinity'::TIME;

-- infinite subtract

select
  subtract(
    cast('infinity' as timestamp), timestamp '1970-01-01');


select
  subtract(
    timestamp '1970-01-01',
    cast('-infinity' as timestamp));


SELECT 'e'::TIMESTAMP;


SELECT 'e'::DATE;


SELECT 'i'::TIMESTAMP;


SELECT 'i'::DATE;
