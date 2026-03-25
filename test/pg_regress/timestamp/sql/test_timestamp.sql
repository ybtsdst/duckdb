-- Converted from test_timestamp.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/test_timestamp.test
-- description: Test TIMESTAMP type
-- group: [timestamp]


SET default_null_order='nulls_first';


PRAGMA enable_verification;


CREATE TABLE IF NOT EXISTS timestamp (t TIMESTAMP);


INSERT INTO timestamp VALUES ('2008-01-01 00:00:01'), (NULL), ('2007-01-01 00:00:01'), ('2008-02-01 00:00:01'), ('2008-01-02 00:00:01'), ('2008-01-01 10:00:00'), ('2008-01-01 00:10:00'), ('2008-01-01 00:00:10');


SELECT timestamp '2017-07-23 13:10:11';

-- iso timestamps

SELECT timestamp '2017-07-23T13:10:11', timestamp '2017-07-23T13:10:11Z';

-- spaces everywhere

SELECT timestamp '    2017-07-23     13:10:11    ';

-- other trailing, preceding, or middle gunk is not accepted

SELECT timestamp '    2017-07-23     13:10:11    AA';


SELECT timestamp 'AA2017-07-23 13:10:11';


SELECT timestamp '2017-07-23A13:10:11';


SELECT t FROM timestamp ORDER BY t;


SELECT MIN(t) FROM timestamp;


SELECT MAX(t) FROM timestamp;


SELECT SUM(t) FROM timestamp;


SELECT AVG(t) FROM timestamp;


SELECT t+t FROM timestamp;


SELECT t*t FROM timestamp;


SELECT t/t FROM timestamp;


SELECT t%t FROM timestamp;


SELECT t-t FROM timestamp;


SELECT YEAR(TIMESTAMP '1992-01-01 01:01:01');


SELECT YEAR(TIMESTAMP '1992-01-01 01:01:01'::DATE);


SELECT (TIMESTAMP '1992-01-01 01:01:01')::DATE;


SELECT (TIMESTAMP '1992-01-01 01:01:01')::TIME;


SELECT t::DATE FROM timestamp WHERE EXTRACT(YEAR from t)=2007 ORDER BY 1;


SELECT t::TIME FROM timestamp WHERE EXTRACT(YEAR from t)=2007 ORDER BY 1;


SELECT (DATE '1992-01-01')::TIMESTAMP;


SELECT TIMESTAMP '2008-01-01 00:00:01.5'::VARCHAR;


SELECT TIMESTAMP '-8-01-01 00:00:01.5'::VARCHAR;

-- timestamp with large date

SELECT TIMESTAMP '100000-01-01 00:00:01.5'::VARCHAR;

-- Avoid infinite recursion.

SELECT CAST(REPEAT('1992-02-02 ', 100000) AS TIMESTAMP);
