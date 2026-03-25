-- Converted from test_timestamp_tz.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/test_timestamp_tz.test
-- description: Test TIMESTAMP WITH TIME ZONE common operations
-- group: [timestamp]


PRAGMA enable_verification;

-- Cast from string

select timestamptz '2021-11-15 02:30:00';

-- Cast from TIMESTAMP

select '2021-11-15 02:30:00'::TIMESTAMP::TIMESTAMPTZ;

-- No casting to DATE or TIME



SELECT '2021-04-29 10:50:09-05'::TIMESTAMPTZ::DATE;


SELECT '2021-04-29 10:50:09-05'::TIMESTAMPTZ::TIME;

-- 19th century offset with seconds resolution

SELECT '1880-05-15T12:00:00+00:50:20'::TIMESTAMPTZ;
