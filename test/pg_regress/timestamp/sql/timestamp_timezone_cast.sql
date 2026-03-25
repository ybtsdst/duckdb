-- Converted from timestamp_timezone_cast.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/timestamp_timezone_cast.test
-- description: Test timestamp with timezones cast
-- group: [timestamp]


PRAGMA enable_verification;

-- we can cast timestamps with UTC in them

SELECT TIMESTAMP '2021-05-25 04:55:03.382494 UTC';


SELECT TIMESTAMP '2021-05-25 04:55:03.382494 utc';


SELECT TIMESTAMP '2021-05-25 04:55:03.382494 uTc';


SELECT TIMESTAMP '2021-05-25 04:55:03.382494 EST';


-- FIXME: we should be able to make this work

SELECT TIMESTAMP '2021-05-25 04:55:03.382494 EST';


set Calendar='gregorian';


SET TimeZone='UTC';


SELECT TIMESTAMPTZ '2021-05-25 04:55:03.382494 EST';


set TimeZone='America/Phoenix';


SELECT
  DATE_DIFF(
  	'HOUR',  
  	TIMESTAMP '2010-07-07 10:20:00' AT TIME ZONE 'Asia/Bangkok', 
  	TIMESTAMP '2010-07-07 10:20:00+00') AS hours;
