-- Converted from timestamp_try_cast.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/timestamp_try_cast.test
-- description: Test timestamp try cast
-- group: [timestamp]


PRAGMA enable_verification;

-- try cast on gibberish

select try_cast('' as timestamp);


select try_cast('    ' as timestamp);


select try_cast('1111' as timestamp);


select try_cast('  1111   ' as timestamp);


select try_cast('1111-' as timestamp);


select try_cast('1111-11' as timestamp);


select try_cast('1111-11-' as timestamp);


select try_cast('1111-111-1' as timestamp);


select try_cast('1111-11-111' as timestamp);


select try_cast('1111-11-11 11' as timestamp);


select try_cast('1111-11-11 11:11' as timestamp);


select try_cast('1111-11-11 11:11:999' as timestamp);


select try_cast('1111-11-11 11:11:11.AAA' as timestamp);


select try_cast('1111-11-11 11X11A11' as timestamp);


select try_cast('1111-11-11 11:11:11' as timestamp);

-- try_cast on the limits

select try_cast('290309-12-21 (BC) 12:59:59.999999' as timestamp);


select try_cast('294247-01-10 04:00:54.775807' as timestamp);


select try_cast('290309-12-22 (BC) 00:00:00' as timestamp);


select try_cast('294247-01-10 04:00:54.775806' as timestamp);


select try_cast('infinity' as timestamp);


select try_cast('-infinity' as timestamp);
