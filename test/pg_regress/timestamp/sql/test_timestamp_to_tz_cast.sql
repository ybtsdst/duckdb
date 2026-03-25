-- Converted from test_timestamp_to_tz_cast.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/test_timestamp_to_tz_cast.test
-- description: Test casting to TIMESTAMP WITH TIME ZONE from any unit
-- group: [timestamp]



PRAGMA enable_verification;

-- Note: this also contains TIMESTAMP_NS

-- Basic value

create table ts_TIMESTAMP_tbl_1 as from VALUES
	('1990/12/21'::TIMESTAMP)
as t(ts);

-- NULL

create table ts_TIMESTAMP_tbl_null as FROM VALUES
	(NULL::TIMESTAMP)
as t(ts);

-- Positive infinity

create table ts_TIMESTAMP_tbl_posinf as from VALUES
	('infinity'::TIMESTAMP)
as t(ts);

-- Negative infinity

create table ts_TIMESTAMP_tbl_mininf as from VALUES
	('-infinity'::TIMESTAMP)
as t(ts);

-- Basic value

create table ts_TIMESTAMP_NS_tbl_1 as from VALUES
	('1990/12/21'::TIMESTAMP_NS)
as t(ts);

-- NULL

create table ts_TIMESTAMP_NS_tbl_null as FROM VALUES
	(NULL::TIMESTAMP_NS)
as t(ts);

-- Positive infinity

create table ts_TIMESTAMP_NS_tbl_posinf as from VALUES
	('infinity'::TIMESTAMP_NS)
as t(ts);

-- Negative infinity

create table ts_TIMESTAMP_NS_tbl_mininf as from VALUES
	('-infinity'::TIMESTAMP_NS)
as t(ts);

-- Basic value

create table ts_TIMESTAMP_MS_tbl_1 as from VALUES
	('1990/12/21'::TIMESTAMP_MS)
as t(ts);

-- NULL

create table ts_TIMESTAMP_MS_tbl_null as FROM VALUES
	(NULL::TIMESTAMP_MS)
as t(ts);

-- Positive infinity

create table ts_TIMESTAMP_MS_tbl_posinf as from VALUES
	('infinity'::TIMESTAMP_MS)
as t(ts);

-- Negative infinity

create table ts_TIMESTAMP_MS_tbl_mininf as from VALUES
	('-infinity'::TIMESTAMP_MS)
as t(ts);

-- Basic value

create table ts_TIMESTAMP_S_tbl_1 as from VALUES
	('1990/12/21'::TIMESTAMP_S)
as t(ts);

-- NULL

create table ts_TIMESTAMP_S_tbl_null as FROM VALUES
	(NULL::TIMESTAMP_S)
as t(ts);

-- Positive infinity

create table ts_TIMESTAMP_S_tbl_posinf as from VALUES
	('infinity'::TIMESTAMP_S)
as t(ts);

-- Negative infinity

create table ts_TIMESTAMP_S_tbl_mininf as from VALUES
	('-infinity'::TIMESTAMP_S)
as t(ts);


-- Extreme positive

create table ts_TIMESTAMP_tbl_2 as from VALUES
	('294247-01-10'::TIMESTAMP)
as t(ts);

-- Extreme negative

create table ts_TIMESTAMP_tbl_3 as from VALUES
	('29720-04-05 (BC) 22:13:20'::TIMESTAMP)
as t(ts);

-- Extreme positive

create table ts_TIMESTAMP_MS_tbl_2 as from VALUES
	('294247-01-10'::TIMESTAMP_MS)
as t(ts);

-- Extreme negative

create table ts_TIMESTAMP_MS_tbl_3 as from VALUES
	('29720-04-05 (BC) 22:13:20'::TIMESTAMP_MS)
as t(ts);

-- Extreme positive

create table ts_TIMESTAMP_S_tbl_2 as from VALUES
	('294247-01-10'::TIMESTAMP_S)
as t(ts);

-- Extreme negative

create table ts_TIMESTAMP_S_tbl_3 as from VALUES
	('29720-04-05 (BC) 22:13:20'::TIMESTAMP_S)
as t(ts);


SET Calendar='gregorian';

-- ---------------- UTC ----------------


SET TimeZone='UTC';

-- Table 1 | UTC +0


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_1;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_NS_tbl_1;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_1;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_1;

-- Table 2 | UTC +0


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_2;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_2;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_2;

-- Table 3 | UTC +0


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_3;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_3;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_3;

-- Table +inf | UTC +0


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_posinf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_NS_tbl_posinf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_posinf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_posinf;

-- Table -inf | UTC +0


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_mininf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_NS_tbl_mininf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_mininf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_mininf;

-- Table NULL | UTC +0


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_null;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_NS_tbl_null;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_null;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_null;

-- ---------------- America / Los Angeles ----------------


SET TimeZone='America/Los_Angeles';

-- Table 1 | America -7/8


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_1;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_1;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_1;

-- Table 2 | America -7/8

-- This timestamp is near the end of the valid range, this timezone would overflow the value

select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_2;

-- This timestamp is near the end of the valid range, this timezone would overflow the value

select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_2;

-- This timestamp is near the end of the valid range, this timezone would overflow the value

select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_2;

-- Table 3 | America -7/8


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_3;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_3;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_3;

-- Table +inf | America -7/8


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_posinf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_NS_tbl_posinf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_posinf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_posinf;

-- Table -inf | America -7/8


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_mininf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_NS_tbl_mininf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_mininf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_mininf;

-- Table NULL | America -7/8



select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_null;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_NS_tbl_null;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_null;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_null;

-- ---------------- ETC ----------------


SET TimeZone='Etc/GMT-6';

-- Table 1 | ETC +6


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_1;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_1;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_1;

-- Table 2 | ETC +6


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_2;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_2;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_2;

-- Table 3 | ETC +6

-- FIXME: I would expect this to overflow???

select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_3;

-- FIXME: I would expect this to overflow???

select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_3;

-- FIXME: I would expect this to overflow???

select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_3;

-- Table +inf | ETC +6


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_posinf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_NS_tbl_posinf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_posinf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_posinf;

-- Table -inf | ETC +6


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_mininf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_NS_tbl_mininf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_mininf;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_mininf;

-- Table NULL | ETC +6



select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_tbl_null;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_NS_tbl_null;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_MS_tbl_null;


select ts as base, base::TIMESTAMPTZ as tstz from ts_TIMESTAMP_S_tbl_null;
