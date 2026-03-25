-- Converted from infinity_cast_coverage.test
-- DuckDB timestamp test suite
-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface

-- name: test/sql/types/timestamp/infinity_cast_coverage.test
-- description: Test casting to TIMESTAMP WITH TIME ZONE from any unit
-- group: [timestamp]


pragma enable_verification;




-- FIXME: this should be expanded with the other base types
-- Conversion Error: Unimplemented type for cast (TIMESTAMP_MS -> TIMESTAMP_S)


select 'infinity'::TIMESTAMP::TIMESTAMPTZ == 'infinity';

-- target_type


select 'infinity'::TIMESTAMP::TIMESTAMP == 'infinity';

-- target_type

-- base_type

-- FIXME: this should be expanded with the other base types
-- Conversion Error: Unimplemented type for cast (TIMESTAMP_MS -> TIMESTAMP_S)


select 'infinity'::TIMESTAMP_MS::TIMESTAMPTZ == 'infinity';

-- target_type


select 'infinity'::TIMESTAMP_MS::TIMESTAMP == 'infinity';

-- target_type

-- base_type

-- FIXME: this should be expanded with the other base types
-- Conversion Error: Unimplemented type for cast (TIMESTAMP_MS -> TIMESTAMP_S)


select 'infinity'::TIMESTAMP_NS::TIMESTAMPTZ == 'infinity';

-- target_type


select 'infinity'::TIMESTAMP_NS::TIMESTAMP == 'infinity';

-- target_type

-- base_type

-- FIXME: this should be expanded with the other base types
-- Conversion Error: Unimplemented type for cast (TIMESTAMP_MS -> TIMESTAMP_S)


select 'infinity'::TIMESTAMP_S::TIMESTAMPTZ == 'infinity';

-- target_type


select 'infinity'::TIMESTAMP_S::TIMESTAMP == 'infinity';

-- target_type

-- base_type

-- FIXME: this should be expanded with the other base types
-- Conversion Error: Unimplemented type for cast (TIMESTAMP_MS -> TIMESTAMP_S)


select 'infinity'::TIMESTAMPTZ::TIMESTAMPTZ == 'infinity';

-- target_type


select 'infinity'::TIMESTAMPTZ::TIMESTAMP == 'infinity';

-- target_type

-- base_type

-- infinity_string


-- FIXME: this should be expanded with the other base types
-- Conversion Error: Unimplemented type for cast (TIMESTAMP_MS -> TIMESTAMP_S)


select '-infinity'::TIMESTAMP::TIMESTAMPTZ == '-infinity';

-- target_type


select '-infinity'::TIMESTAMP::TIMESTAMP == '-infinity';

-- target_type

-- base_type

-- FIXME: this should be expanded with the other base types
-- Conversion Error: Unimplemented type for cast (TIMESTAMP_MS -> TIMESTAMP_S)


select '-infinity'::TIMESTAMP_MS::TIMESTAMPTZ == '-infinity';

-- target_type


select '-infinity'::TIMESTAMP_MS::TIMESTAMP == '-infinity';

-- target_type

-- base_type

-- FIXME: this should be expanded with the other base types
-- Conversion Error: Unimplemented type for cast (TIMESTAMP_MS -> TIMESTAMP_S)


select '-infinity'::TIMESTAMP_NS::TIMESTAMPTZ == '-infinity';

-- target_type


select '-infinity'::TIMESTAMP_NS::TIMESTAMP == '-infinity';

-- target_type

-- base_type

-- FIXME: this should be expanded with the other base types
-- Conversion Error: Unimplemented type for cast (TIMESTAMP_MS -> TIMESTAMP_S)


select '-infinity'::TIMESTAMP_S::TIMESTAMPTZ == '-infinity';

-- target_type


select '-infinity'::TIMESTAMP_S::TIMESTAMP == '-infinity';

-- target_type

-- base_type

-- FIXME: this should be expanded with the other base types
-- Conversion Error: Unimplemented type for cast (TIMESTAMP_MS -> TIMESTAMP_S)


select '-infinity'::TIMESTAMPTZ::TIMESTAMPTZ == '-infinity';

-- target_type


select '-infinity'::TIMESTAMPTZ::TIMESTAMP == '-infinity';

-- target_type

-- base_type

-- infinity_string
