-- Converted from utc_offset.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/utc_offset.test
-- description: Test UTC offset in timestamptz parsing
-- group: [timestamp]



PRAGMA enable_verification;


set Calendar='gregorian';


set TimeZone='UTC';

-- Offset parsing for plain  timestamps drops the offset instead of subtracting it

SELECT '2025-01-01T08:00:00+08'::TIMESTAMP AS c;


SELECT '2025-01-01T08:00:00+08'::TIMESTAMPTZ AS c;


select timestamptz '2020-12-31 21:25:58.745232';


select timestamptz '2020-12-31 21:25:58.745232';


select timestamptz '2020-12-31 21:25:58.745232+00';


select timestamptz '2020-12-31 21:25:58.745232+0000';


select timestamptz '2020-12-31 21:25:58.745232+02';


select timestamptz '2020-12-31 21:25:58.745232-02';


select timestamptz '2020-12-31 21:25:58.745232+0215';


select timestamptz '2020-12-31 21:25:58.745232+02:15';


select timestamptz '2020-12-31 21:25:58.745232-0215';


select timestamptz '2020-12-31 21:25:58+02:15';
