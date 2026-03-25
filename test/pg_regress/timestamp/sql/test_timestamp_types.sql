-- Converted from test_timestamp_types.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/test_timestamp_types.test
-- description: Test TIMESTAMP types
-- group: [timestamp]


PRAGMA enable_verification;


CREATE TABLE IF NOT EXISTS timestamp (sec TIMESTAMP_S, milli TIMESTAMP_MS,micro TIMESTAMP_US, nano TIMESTAMP_NS );


INSERT INTO timestamp VALUES ('2008-01-01 00:00:01','2008-01-01 00:00:01.594','2008-01-01 00:00:01.88926','2008-01-01 00:00:01.889268321' );


SELECT * from timestamp;

-- Apply Year Function

SELECT YEAR(sec),YEAR(milli),YEAR(nano) from timestamp;

-- Do some conversions

SELECT nano::TIMESTAMP, milli::TIMESTAMP,sec::TIMESTAMP from timestamp;


SELECT micro::TIMESTAMP_S, micro::TIMESTAMP_MS,micro::TIMESTAMP_NS from timestamp;



INSERT INTO timestamp VALUES ('2008-01-01 00:00:51','2008-01-01 00:00:01.894','2008-01-01 00:00:01.99926','2008-01-01 00:00:01.999268321' );


INSERT INTO timestamp VALUES ('2008-01-01 00:00:11','2008-01-01 00:00:01.794','2008-01-01 00:00:01.98926','2008-01-01 00:00:01.899268321' );


-- Overflow from US to NS

select '90000-01-19 03:14:07.999999'::TIMESTAMP_US::TIMESTAMP_NS;


SELECT s::TIMESTAMP_NS
FROM VALUES 
	('2024-06-04 10:17:10.987654321'),
	('2024-06-04 10:17:10.98765432'),
	('2024-06-04 10:17:10.9876543'),
	('2024-06-04 10:17:10.9876543'),
	('2024-06-04 10:17:10.987654'),
	('2024-06-04 10:17:10.98765'),
	('2024-06-04 10:17:10.9876'),
	('2024-06-04 10:17:10.987'),
	('2024-06-04 10:17:10.98'),
	('2024-06-04 10:17:10.9'),
	('2024-06-04 10:17:10')
AS tbl(s);


SELECT TIMESTAMP_NS '2262-04-11 23:47:16.854775808';

-- Negative timestamp_ns

select '1969-01-01T23:59:59.9999999'::timestamp_ns;

-- Zero µs witn non-zero ns

SELECT '1970-01-01 00:00:00.000000123'::TIMESTAMP_NS;

-- TIME conversions are now supported

select sec::TIME from timestamp;


select milli::TIME from timestamp;


select nano::TIME from timestamp;

-- Direct timestamp promotions



SELECT sec, sec 
FROM timestamp 
WHERE sec = sec;


SELECT sec, milli 
FROM timestamp 
WHERE sec = milli;


SELECT sec, micro 
FROM timestamp 
WHERE sec = micro;


SELECT sec, nano 
FROM timestamp 
WHERE sec = nano;



SELECT milli, sec 
FROM timestamp 
WHERE milli = sec;


SELECT milli, milli 
FROM timestamp 
WHERE milli = milli;


SELECT milli, micro 
FROM timestamp 
WHERE milli = micro;


SELECT milli, nano 
FROM timestamp 
WHERE milli = nano;



SELECT micro, sec 
FROM timestamp 
WHERE micro = sec;


SELECT micro, milli 
FROM timestamp 
WHERE micro = milli;


SELECT micro, micro 
FROM timestamp 
WHERE micro = micro;


SELECT micro, nano 
FROM timestamp 
WHERE micro = nano;



SELECT nano, sec 
FROM timestamp 
WHERE nano = sec;


SELECT nano, milli 
FROM timestamp 
WHERE nano = milli;


SELECT nano, micro 
FROM timestamp 
WHERE nano = micro;


SELECT nano, nano 
FROM timestamp 
WHERE nano = nano;

-- Cast to DATE


SELECT sec::DATE from timestamp;


SELECT milli::DATE from timestamp;


SELECT micro::DATE from timestamp;


SELECT nano::DATE from timestamp;

-- Sorting on the timestamps

select sec from timestamp order by sec;


select milli from timestamp order by milli;


select nano from timestamp order by nano;

-- GROUP BY on each of these timestamp types

INSERT INTO timestamp VALUES ('2008-01-01 00:00:51','2008-01-01 00:00:01.894','2008-01-01 00:00:01.99926','2008-01-01 00:00:01.999268321' );


INSERT INTO timestamp VALUES ('2008-01-01 00:00:11','2008-01-01 00:00:01.794','2008-01-01 00:00:01.98926','2008-01-01 00:00:01.899268321' );


select count(*), nano from timestamp group by nano order by nano;


select count(*), sec from timestamp group by sec order by sec;


select count(*), milli from timestamp group by milli order by milli;

-- Joins on the timestamps

CREATE TABLE IF NOT EXISTS timestamp_two (sec TIMESTAMP_S, milli TIMESTAMP_MS,micro TIMESTAMP_US, nano TIMESTAMP_NS );


INSERT INTO timestamp_two VALUES ('2008-01-01 00:00:11','2008-01-01 00:00:01.794','2008-01-01 00:00:01.98926','2008-01-01 00:00:01.899268321' );


select timestamp.sec from timestamp inner join  timestamp_two on (timestamp.sec = timestamp_two.sec);


select timestamp.milli from timestamp inner join  timestamp_two on (timestamp.milli = timestamp_two.milli);


select timestamp.nano from timestamp inner join  timestamp_two on (timestamp.nano = timestamp_two.nano);

-- Comparisons between all the different timestamp types (e.g. TIMESTAMP = TIMESTAMP_MS, etc)

select '2008-01-01 00:00:11'::TIMESTAMP_US = '2008-01-01 00:00:11'::TIMESTAMP_MS;


select '2008-01-01 00:00:11'::TIMESTAMP_US = '2008-01-01 00:00:11'::TIMESTAMP_NS;


select '2008-01-01 00:00:11'::TIMESTAMP_US = '2008-01-01 00:00:11'::TIMESTAMP_S;




select '2008-01-01 00:00:11.1'::TIMESTAMP_US = '2008-01-01 00:00:11'::TIMESTAMP_MS;


select '2008-01-01 00:00:11.1'::TIMESTAMP_US = '2008-01-01 00:00:11'::TIMESTAMP_NS;


select '2008-01-01 00:00:11.1'::TIMESTAMP_US = '2008-01-01 00:00:11.1'::TIMESTAMP_S;

-- Precision casts

select '2008-01-01 00:00:11.1'::TIMESTAMP_MS = '2008-01-01 00:00:11'::TIMESTAMP_NS;


select '2008-01-01 00:00:11.1'::TIMESTAMP_MS = '2008-01-01 00:00:11'::TIMESTAMP_S;


select '2008-01-01 00:00:11.1'::TIMESTAMP_NS = '2008-01-01 00:00:11'::TIMESTAMP_S;


select '2008-01-01 00:00:11'::TIMESTAMP_MS = '2008-01-01 00:00:11'::TIMESTAMP_NS;


select '2008-01-01 00:00:11'::TIMESTAMP_MS = '2008-01-01 00:00:11'::TIMESTAMP_S;


select '2008-01-01 00:00:11'::TIMESTAMP_NS = '2008-01-01 00:00:11'::TIMESTAMP_S;


SELECT CAST(t0.c0 AS TIME)>=('12:34:56') FROM  values ('2030-01-01'::TIMESTAMP_S), ('1969-12-23 20:44:40'::TIMESTAMP_S) as t0(c0);


SELECT NOT CAST(t0.c0 AS TIME)>=('12:34:56') FROM  values ('2030-01-01'::TIMESTAMP_MS), ('1969-12-23 20:44:40'::TIMESTAMP_MS) as t0(c0);
