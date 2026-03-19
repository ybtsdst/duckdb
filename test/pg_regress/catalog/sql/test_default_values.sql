-- Converted from test_default_values.test
-- DuckDB catalog/table test suite

-- name: test/sql/catalog/table/test_default_values.test
-- description: Test DEFAULT VALUES insert
-- group: [table]
create table x (i int default 1, j int default 2);

insert into x default values;

SELECT * FROM x;

-- returning
insert into x default values returning (i);

insert into x default values returning (j);

insert into x(i) default values;

-- on conflict
drop table x;

create table x (i int primary key default 1, j int default 2);

insert into x default values;

insert into x default values;

insert into x default values on conflict do nothing;

