-- Converted from timestamp_limits.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/timestamp_limits.test
-- description: Test timestamp limits
-- group: [timestamp]


PRAGMA enable_verification;


select timestamp '1970-01-01';

-- timestamp micros
-- min date for timestamp micros is 290309-12-22 (BC) 00:00:00

select '290309-12-22 (BC) 00:00:00'::timestamp;


select '290309-12-21 (BC) 12:59:59.999999'::timestamp;


select '290309-12-22 (BC) 00:00:00'::timestamp + interval (1) day;


select '290309-12-22 (BC) 00:00:00'::timestamp - interval (1) microsecond;


select '290309-12-22 (BC) 00:00:00'::timestamp - interval (1) second;


select '290309-12-22 (BC) 00:00:00'::timestamp - interval (1) day;


select '290309-12-22 (BC) 00:00:00'::timestamp - interval (1) month;


select '290309-12-22 (BC) 00:00:00'::timestamp - interval (1) year;

-- max date for timestamp micros is 294247-01-10 04:00:54.775806

select timestamp '294247-01-10 04:00:54.775806';


select timestamp '294247-01-10 04:00:54.775807';


select timestamp '294247-01-10 04:00:54.775808';


select timestamp '294247-01-10 04:00:54.775806' + interval (1) microsecond;


select timestamp '294247-01-10 04:00:54.775806' + interval (1) second;


select timestamp '294247-01-10 04:00:54.775806' + interval (1) hour;


select timestamp '294247-01-10 04:00:54.775806' + interval (1) day;


select timestamp '294247-01-10 04:00:54.775806' + interval (1) month;


select timestamp '294247-01-10 04:00:54.775806' + interval (1) year;

-- functions on limits

select epoch(timestamp '294247-01-10 04:00:54.775806'), epoch(timestamp '290309-12-22 (BC) 00:00:00');


select year(timestamp '294247-01-10 04:00:54.775806'), year(timestamp '290309-12-22 (BC) 00:00:00');


select decade(timestamp '294247-01-10 04:00:54.775806'), decade(timestamp '290309-12-22 (BC) 00:00:00');


select monthname(timestamp '294247-01-10 04:00:54.775806'), monthname(timestamp '290309-12-22 (BC) 00:00:00');


select age(timestamp '294247-01-10 04:00:54.775806', '290309-12-22 (BC) 00:00:00'::timestamp);
