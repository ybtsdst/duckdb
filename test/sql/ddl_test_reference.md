# DuckDB DDL Test Case Reference

本文档整理了 DuckDB 中所有以 SQL 为入口的 DDL（数据定义语言）测试用例，按功能类别分类，供插件开发者参考，用于验证自定义元数据管理功能的正确性。

---

## 测试文件格式说明

DuckDB 使用自定义 `.test` 文件格式（SQLLogicTest 格式），基本结构如下：

```sql
# name: test/sql/path/test_name.test
# description: 测试描述
# group: [分组名]

statement ok
CREATE TABLE test(i INTEGER);

statement error
CREATE TABLE test(i INTEGER);   -- 重复创建，期望报错
----
已存在的错误信息

query I
SELECT COUNT(*) FROM test;
----
0

-- 多连接并发测试
statement ok con1
BEGIN TRANSACTION;

statement ok con2
SELECT * FROM test;
```

**关键字说明：**
- `statement ok` — 语句应执行成功
- `statement error` — 语句应执行失败（可在 `----` 后指定期望的错误信息或正则 `<REGEX>:...`）
- `query [类型]` — 执行查询并验证结果（`I` = 整数, `T` = 文本, `II` = 两列整数等）
- `con1`, `con2` — 指定执行连接，用于并发测试
- `require` — 声明前置依赖（如 `require skip_reload`）
- `foreach` — 参数化遍历多个值
- `load` — 加载或创建持久化数据库文件

---

## 一、CREATE TABLE（建表）

**目录：** `test/sql/create/`

| 文件 | 描述 |
|------|------|
| `create/create_as.test` | CREATE TABLE AS SELECT (CTAS)，含 CREATE OR REPLACE、带列名列表的 CTAS |
| `create/create_as_issue_11968.test` | CTAS 边界 issue 复现 |
| `create/create_or_replace.test` | CREATE OR REPLACE TABLE；对已有 View 使用 REPLACE 的错误处理 |
| `create/create_database.test` | CREATE DATABASE 语句 |
| `create/create_table_compression.test` | 建表时指定压缩选项（`COMPRESSION` 参数） |
| `create/create_table_with_arraybounds.test` | 带数组边界的列定义 |
| `create/create_using_index.test` | 建表时同步创建索引 |
| `create/create_index_on_issue_13643.test` | 在已有表上创建索引的 issue 复现 |
| `create/create_objects_readonly.test` | 只读模式下创建对象的错误处理 |
| `create/create_table_as_duplicate_names.test` | CTAS 时列名重复的错误处理 |
| `create/create_table_as_error.test` | CTAS 执行失败时的回滚行为 |

**catalog/table/ 下的建表测试：**

| 文件 | 描述 |
|------|------|
| `catalog/table/test_default.test` | 列默认值：字面量、表达式默认值 |
| `catalog/table/test_default_values.test` | 各数据类型的默认值行为 |
| `catalog/table/create_table_parameters.test` | 建表参数（如 `IF NOT EXISTS`） |
| `catalog/table/create_table_as_abort.test` | CTAS 事务中止后的清理行为 |
| `catalog/table/test_create_table_parallelism.test` | 并发建表的正确性 |
| `catalog/table/long_identifier.test` | 超长标识符（表名、列名）的处理 |
| `catalog/table/test_many_columns.test` | 列数非常多的宽表创建 |
| `catalog/test_create_from_select.test` | CREATE TABLE ... AS SELECT 的各种变体 |
| `catalog/test_incorrect_table_creation.test` | 无效建表语句的错误处理 |
| `catalog/test_if_not_exists.test` | IF NOT EXISTS 语义（表、视图、模式、序列等）|
| `catalog/drop_create_rollback.test` | DROP + CREATE 在事务中回滚的行为 |

---

## 二、ALTER TABLE（修改表结构）

**目录：** `test/sql/alter/`

### 2.1 ADD COLUMN（新增列）

**目录：** `test/sql/alter/add_col/`

| 文件 | 描述 |
|------|------|
| `add_col/test_add_col.test` | 基础 ADD COLUMN，新列默认为 NULL |
| `add_col/test_add_col_chain.test` | 在同一 ALTER 语句中链式新增多列 |
| `add_col/test_add_col_default.test` | ADD COLUMN 带默认值（含表达式默认值） |
| `add_col/test_add_col_default_seq.test` | ADD COLUMN 默认值使用序列（nextval） |
| `add_col/test_add_col_incorrect.test` | 无效的 ADD COLUMN（列已存在、类型错误等） |
| `add_col/test_add_col_index.test` | ADD COLUMN 时存在索引的行为 |
| `add_col/test_add_col_index_rollback.test` | ADD COLUMN（含索引）的事务回滚 |
| `add_col/test_add_col_local_storage.test` | 本地存储事务中 ADD COLUMN 的行为 |
| `add_col/test_add_col_stats.test` | ADD COLUMN 后统计信息的更新 |
| `add_col/test_add_col_transactions.test` | ADD COLUMN 在并发事务中的隔离性 |
| `add_col/test_add_col_user_type.test` | ADD COLUMN 使用自定义类型（ENUM 等） |

### 2.2 DROP COLUMN（删除列）

**目录：** `test/sql/alter/drop_col/`

| 文件 | 描述 |
|------|------|
| `drop_col/test_drop_col.test` | 基础 DROP COLUMN |
| `drop_col/test_drop_col_check.test` | 删除被 CHECK 约束引用的列 |
| `drop_col/test_drop_col_check_next.test` | 含 CHECK 约束的连续列删除 |
| `drop_col/test_drop_col_failure.test` | 无效 DROP COLUMN（不存在的列、唯一列等） |
| `drop_col/test_drop_col_index.test` | 删除被索引引用的列 |
| `drop_col/test_drop_col_not_null.test` | 删除带 NOT NULL 约束的列 |
| `drop_col/test_drop_col_not_null_next.test` | NOT NULL 列删除的连续操作 |
| `drop_col/test_drop_col_operations.test` | 多种 DROP COLUMN 场景综合测试 |
| `drop_col/test_drop_col_pk.test` | 删除主键列的错误处理 |
| `drop_col/test_drop_col_rollback.test` | DROP COLUMN 的事务回滚 |
| `drop_col/test_drop_col_transactions.test` | 并发事务中 DROP COLUMN 的隔离性 |
| `drop_col/test_drop_col_with_generated_cols.test` | 删除被生成列引用的列 |

### 2.3 RENAME COLUMN（重命名列）

**目录：** `test/sql/alter/rename_col/`

| 文件 | 描述 |
|------|------|
| `rename_col/test_rename_col.test` | 基础 RENAME COLUMN |
| `rename_col/test_rename_col_check.test` | 重命名被 CHECK 约束引用的列 |
| `rename_col/test_rename_col_dependencies.test` | 重命名被视图/宏引用的列 |
| `rename_col/test_rename_col_failure.test` | 无效的重命名（不存在的列、名称冲突） |
| `rename_col/test_rename_col_not_null.test` | 重命名带 NOT NULL 约束的列 |
| `rename_col/test_rename_col_rollback.test` | RENAME COLUMN 的事务回滚 |
| `rename_col/test_rename_col_transactions.test` | 并发事务中 RENAME COLUMN 的隔离性 |
| `rename_col/test_rename_col_unique.test` | 重命名带 UNIQUE 约束的列 |

### 2.4 ALTER COLUMN TYPE（修改列类型）

**目录：** `test/sql/alter/alter_type/`

| 文件 | 描述 |
|------|------|
| `alter_type/test_alter_type.test` | 基础 ALTER COLUMN SET DATA TYPE |
| `alter_type/test_alter_type_check.test` | 修改被 CHECK 约束引用的列类型 |
| `alter_type/test_alter_type_dependencies.test` | 修改被视图/宏引用的列类型 |
| `alter_type/test_alter_type_expression.test` | 带 USING 表达式的类型转换 |
| `alter_type/test_alter_type_incorrect.test` | 无效的类型转换（不兼容类型等） |
| `alter_type/test_alter_type_index.test` | 修改被索引引用的列类型 |
| `alter_type/test_alter_type_local.test` | 本地事务中修改列类型 |
| `alter_type/test_alter_type_multi_column.test` | 同时修改多列类型 |
| `alter_type/test_alter_type_not_null.test` | 修改带 NOT NULL 约束的列类型 |
| `alter_type/test_alter_type_rollback.test` | ALTER COLUMN TYPE 的事务回滚 |
| `alter_type/test_alter_type_transactions.test` | 并发事务中修改列类型 |
| `alter_type/test_alter_type_unique.test` | 修改带 UNIQUE 约束的列类型 |
| `alter_type/test_alter_type_with_generated_column.test` | 修改生成列所依赖的列类型 |
| `alter_type/alter_type_struct.test` | 修改 STRUCT 类型列的子字段类型 |

### 2.5 SET/DROP NOT NULL（非空约束）

**目录：** `test/sql/alter/alter_col/`

| 文件 | 描述 |
|------|------|
| `alter_col/test_set_not_null.test` | ALTER COLUMN SET NOT NULL |
| `alter_col/test_drop_not_null.test` | ALTER COLUMN DROP NOT NULL |
| `alter_col/test_not_null_in_tran.test` | 在事务中设置/删除 NOT NULL |
| `alter_col/test_not_null_multi_tran.test` | 多事务并发下的 NOT NULL 修改 |

### 2.6 ADD PRIMARY KEY（新增主键）

**目录：** `test/sql/alter/add_pk/`

| 文件 | 描述 |
|------|------|
| `add_pk/test_add_pk.test` | 基础 ALTER TABLE ADD PRIMARY KEY |
| `add_pk/test_add_multi_column_pk.test` | 多列联合主键的 ADD PRIMARY KEY |
| `add_pk/test_add_pk_alter_in_tx.test` | 事务中添加主键 |
| `add_pk/test_add_pk_attach.test` | 在 ATTACH 的数据库中添加主键 |
| `add_pk/test_add_pk_catalog_error.test` | 添加主键时的目录错误处理 |
| `add_pk/test_add_pk_commit.test` | ADD PRIMARY KEY 事务提交后持久化 |
| `add_pk/test_add_pk_drop_and_reload.test` | ADD PRIMARY KEY 后持久化重加载 |
| `add_pk/test_add_pk_gaps_in_rowids.test` | 含空洞 RowID 的表上添加主键 |
| `add_pk/test_add_pk_invalid_data.test` | 数据有重复时 ADD PRIMARY KEY 报错 |
| `add_pk/test_add_pk_invalid_type.test` | 不支持的类型列上添加主键报错 |
| `add_pk/test_add_pk_naming_conflict.test` | 约束名冲突时的错误处理 |
| `add_pk/test_add_pk_rollback.test` | ADD PRIMARY KEY 事务回滚 |
| `add_pk/test_add_pk_storage.test` | ADD PRIMARY KEY 的存储持久化 |
| `add_pk/test_add_pk_wal.test` | ADD PRIMARY KEY 的 WAL 持久化 |
| `add_pk/test_add_pk_with_generated_column.test` | 含生成列的表上添加主键 |
| `add_pk/test_add_same_pk_simultaneously.test` | 并发同时添加相同主键的冲突检测 |
| `add_pk/test_add_same_pk_twice.test` | 重复添加相同主键的错误处理 |

### 2.7 SET/DROP DEFAULT（默认值）

**目录：** `test/sql/alter/default/`

| 文件 | 描述 |
|------|------|
| `default/test_set_default.test` | ALTER COLUMN SET DEFAULT（含表达式） |
| `default/drop_default.test` | ALTER COLUMN DROP DEFAULT |

### 2.8 RENAME TABLE（重命名表）

**目录：** `test/sql/alter/rename_table/`

| 文件 | 描述 |
|------|------|
| `rename_table/test_rename_table.test` | 基础 ALTER TABLE RENAME TO |
| `rename_table/test_rename_table_case.test` | 大小写不敏感的重命名 |
| `rename_table/test_rename_table_chain_commit.test` | 链式重命名后提交 |
| `rename_table/test_rename_table_chain_rollback.test` | 链式重命名后回滚 |
| `rename_table/test_rename_table_collision.test` | 与已有表名冲突时的错误 |
| `rename_table/test_rename_table_constraints.test` | 含约束的表重命名 |
| `rename_table/test_rename_table_incorrect.test` | 无效的重命名操作 |
| `rename_table/test_rename_table_many_transactions.test` | 多事务中连续重命名 |
| `rename_table/test_rename_table_transactions.test` | 并发事务中重命名表 |
| `rename_table/test_rename_table_view.test` | 重命名被视图引用的表 |
| `rename_table/test_rename_table_with_dependency_check.test` | 含依赖的表重命名检查 |
| `rename_table/test_rename_table_with_insert_transaction.test` | 与 INSERT 事务并发的重命名 |
| `rename_table/test_rename_bug4455_schema.test` | schema 跨越重命名的 bug 复现 |

### 2.9 RENAME VIEW（重命名视图）

**目录：** `test/sql/alter/rename_view/`

| 文件 | 描述 |
|------|------|
| `rename_view/test_rename_view.test` | 基础 ALTER VIEW RENAME TO |
| `rename_view/test_rename_view_incorrect.test` | 无效重命名（目标已存在等） |
| `rename_view/test_rename_view_many_transactions.test` | 多事务中连续重命名视图 |
| `rename_view/test_rename_view_table.test` | 重命名视图名与表名冲突 |
| `rename_view/test_rename_view_transactions.test` | 并发事务中重命名视图 |

### 2.10 RENAME SCHEMA（重命名模式）

| 文件 | 描述 |
|------|------|
| `alter/rename_schema/rename_schema.test` | ALTER SCHEMA RENAME TO |

### 2.11 复杂类型列的 ALTER（STRUCT/LIST/MAP）

| 文件 | 描述 |
|------|------|
| `alter/struct/add_col_struct.test` | 在 STRUCT 类型列中新增子字段 |
| `alter/struct/add_col_nested_struct.test` | 在嵌套 STRUCT 中新增子字段 |
| `alter/struct/drop_col_nested_struct.test` | 在嵌套 STRUCT 中删除子字段 |
| `alter/list/add_column_in_struct.test` | LIST<STRUCT> 中新增子字段 |
| `alter/list/drop_column_in_struct.test` | LIST<STRUCT> 中删除子字段 |
| `alter/list/rename_column_in_struct.test` | LIST<STRUCT> 中重命名子字段 |
| `alter/map/add_column_in_struct.test` | MAP<k, STRUCT> 中新增子字段 |
| `alter/map/drop_column_in_struct.test` | MAP<k, STRUCT> 中删除子字段 |
| `alter/map/rename_column_in_struct.test` | MAP<k, STRUCT> 中重命名子字段 |

### 2.12 其他 ALTER

| 文件 | 描述 |
|------|------|
| `alter/alter_table_set_partitioned_by.test` | ALTER TABLE SET PARTITIONED BY |
| `alter/alter_table_set_sorted_by.test` | ALTER TABLE SET SORTED BY |

---

## 三、SCHEMA（模式管理）

**目录：** `test/sql/catalog/`

| 文件 | 描述 |
|------|------|
| `catalog/test_schema.test` | CREATE/DROP SCHEMA，事务隔离，CASCADE DROP |
| `catalog/test_schema_conflict.test` | 模式名冲突（同名创建、事务冲突） |
| `catalog/test_standard_schema.test` | main/pg_catalog/temp 等标准模式的行为 |
| `catalog/test_unicode_schema.test` | Unicode 字符的模式名 |
| `catalog/test_set_schema.test` | SET schema 设置默认模式 |
| `catalog/test_set_search_path.test` | SET search_path 的语义 |
| `catalog/test_temporary.test` | 临时对象（TEMPORARY TABLE/VIEW/SEQUENCE）|
| `catalog/dependencies/test_schema_dependency.test` | 模式依赖：DROP SCHEMA CASCADE vs. 依赖报错 |
| `catalog/dependencies/test_concurrent_schema_creation.test` | 并发创建模式的冲突检测 |
| `attach/attach_schema.test` | ATTACH 数据库中的 SCHEMA 操作 |
| `attach/reattach_schema.test` | 重新 ATTACH 时模式的状态 |

---

## 四、VIEW（视图管理）

**目录：** `test/sql/catalog/view/`

| 文件 | 描述 |
|------|------|
| `view/test_view.test` | 基础 CREATE/DROP/REPLACE VIEW |
| `view/test_view_alias.test` | 视图列别名的处理 |
| `view/test_view_sql.test` | 视图的 SQL 文本保存与 SHOW CREATE |
| `view/test_view_sql_with_dependencies.test` | 视图 SQL 中包含依赖对象 |
| `view/test_view_schema_change.test` | 基础表列修改后视图的行为 |
| `view/test_view_schema_change_with_dependencies.test` | 含依赖链的视图在基础表变更后的行为 |
| `view/test_view_delete_update.test` | 对视图执行 DELETE/UPDATE 的错误处理 |
| `view/test_view_drop_concurrent.test` | 并发 DROP VIEW 的正确性 |
| `view/test_stacked_view.test` | 多层嵌套视图 |
| `view/recursive_view.test` | 递归视图（WITH RECURSIVE） |
| `view/recursive_view_with_dependencies.test` | 递归视图的依赖管理 |
| `view/view_if_not_exists.test` | CREATE VIEW IF NOT EXISTS 语义 |
| `catalog/test_create_from_select.test` | CREATE VIEW AS SELECT 的各种变体 |

---

## 五、SEQUENCE（序列管理）

**目录：** `test/sql/catalog/sequence/`

| 文件 | 描述 |
|------|------|
| `sequence/test_sequence.test` | 基础 CREATE/DROP SEQUENCE，nextval/currval |
| `sequence/test_duckdb_sequences.test` | duckdb_sequences() 系统表查询 |
| `sequence/test_sequence_dependency.test` | 序列被表列默认值依赖时的 DROP 行为 |
| `sequence/sequence_cycle.test` | CYCLE/NO CYCLE 选项的行为 |
| `sequence/sequence_overflow.test` | 序列溢出的错误处理 |
| `sequence/sequence_offset_increment.test` | START WITH、INCREMENT BY、MINVALUE/MAXVALUE |
| `sequence/test_sequence_google_fuzz.test` | Fuzz 测试发现的序列边界 case |

---

## 六、INDEX（索引管理）

**目录：** `test/sql/index/art/`

### 6.1 CREATE/DROP INDEX

**目录：** `test/sql/index/art/create_drop/`

| 文件 | 描述 |
|------|------|
| `create_drop/test_art_create_if_exists.test` | CREATE INDEX IF NOT EXISTS 及写-写冲突 |
| `create_drop/test_art_drop_index.test` | DROP INDEX 及对数据操作的影响 |
| `create_drop/test_art_invalid_create_index.test` | 无效 CREATE INDEX（不支持的类型、不存在的列等） |
| `create_drop/test_art_create_unique.test` | CREATE UNIQUE INDEX 的行为 |
| `create_drop/test_art_create_index_delete.test` | 建立索引后删除数据的行为 |
| `create_drop/test_art_create_index_duplicate_deletes.test` | 含重复键删除时的索引一致性 |
| `create_drop/test_art_create_many_duplicates.test` | 大量重复键的索引创建 |
| `create_drop/test_art_create_many_duplicates_deletes.test` | 大量重复键删除时的索引一致性 |
| `create_drop/test_art_single_value.test` | 单值列的索引创建与查询 |
| `create_drop/test_art_many_versions.test` | 多事务版本下的索引一致性 |

### 6.2 INDEX CONSTRAINTS（索引约束）

**目录：** `test/sql/index/art/constraints/`

| 文件 | 描述 |
|------|------|
| `constraints/test_art_compound_key_changes.test` | 复合键的变更行为 |
| `constraints/test_art_eager_constraint_checking.test` | 约束的提前检查（eager evaluation）|
| `constraints/test_art_eager_batch_insert.test` | 批量插入时的约束检查 |
| `constraints/test_art_eager_with_wal.test` | WAL 中的约束提前检查 |
| `constraints/test_art_large_abort.test` | 大量数据操作后事务中止的索引恢复 |
| `constraints/test_art_simple_update.test` | 简单 UPDATE 时的索引维护 |
| `constraints/test_art_tx_deletes_list.test` | 事务中删除多行时的索引一致性 |
| `constraints/test_art_tx_deletes_rollback.test` | 事务删除回滚时的索引恢复 |
| `constraints/test_art_tx_updates_list.test` | 事务中更新多行时的索引一致性 |
| `constraints/test_art_tx_updates_rollback.test` | 事务更新回滚时的索引恢复 |
| `constraints/test_art_tx_upserts_list.test` | 事务中 UPSERT 时的索引一致性 |
| `constraints/test_art_tx_upserts_rollback.test` | 事务 UPSERT 回滚时的索引恢复 |

### 6.3 INDEX STORAGE（索引存储）

| 文件 | 描述 |
|------|------|
| `index/art/storage/` | 索引的持久化存储、WAL 恢复、checkpoint |

### 6.4 与 ATTACH 的 INDEX 操作

| 文件 | 描述 |
|------|------|
| `attach/attach_create_index.test` | 在 ATTACH 的数据库中 CREATE INDEX |
| `attach/attach_index.test` | 跨 ATTACH 数据库的索引行为 |

---

## 七、CONSTRAINTS（约束管理）

### 7.1 PRIMARY KEY

**目录：** `test/sql/constraints/primarykey/`

| 文件 | 描述 |
|------|------|
| `primarykey/test_primary_key.test` | 基础主键约束（INSERT/UPDATE/DELETE 验证） |
| `primarykey/test_pk_multi_column.test` | 多列联合主键 |
| `primarykey/test_pk_multi_string.test` | 多字符串列联合主键 |
| `primarykey/test_pk_string.test` | 字符串类型主键 |
| `primarykey/test_pk_bool.test` | 布尔类型主键 |
| `primarykey/test_pk_many_columns.test` | 主键涉及列数非常多时的行为 |
| `primarykey/test_pk_col_subset.test` | 部分列构成主键的行为 |
| `primarykey/test_pk_rollback.test` | 主键约束违反时的事务回滚 |
| `primarykey/test_pk_update_delete.test` | UPDATE/DELETE 时的主键约束检查 |
| `primarykey/test_pk_updel_local.test` | 本地事务中 UPDATE/DELETE 主键约束 |
| `primarykey/test_pk_updel_multi_column.test` | 多列主键的 UPDATE/DELETE 约束 |
| `primarykey/test_pk_concurrency_conflicts.test` | 并发 INSERT 的主键冲突检测 |

### 7.2 FOREIGN KEY

**目录：** `test/sql/constraints/foreignkey/`

| 文件 | 描述 |
|------|------|
| `foreignkey/test_foreignkey.test` | 基础外键约束（INSERT/DELETE 验证） |
| `foreignkey/test_fk_alter.test` | ALTER TABLE ADD/DROP FOREIGN KEY |
| `foreignkey/test_fk_chain.test` | 多表外键链的级联行为 |
| `foreignkey/test_action.test` | ON DELETE/ON UPDATE CASCADE/SET NULL/RESTRICT |
| `foreignkey/test_fk_multiple.test` | 一张表上多个外键约束 |
| `foreignkey/test_fk_self_referencing.test` | 自引用外键（同表引用） |
| `foreignkey/test_fk_cross_schema.test` | 跨 schema 的外键约束 |
| `foreignkey/test_fk_rollback.test` | 外键约束违反的事务回滚 |
| `foreignkey/test_fk_transaction.test` | 事务中的外键约束检查 |
| `foreignkey/test_fk_temporary.test` | 临时表上的外键约束 |
| `foreignkey/test_fk_eager_constraint_checking.test` | 外键约束的提前检查 |
| `foreignkey/test_fk_concurrency_conflicts.test` | 并发操作的外键冲突检测 |
| `foreignkey/test_fk_create_type.test` | 外键列类型验证 |
| `foreignkey/test_fk_export.test` | 含外键的表 EXPORT/IMPORT |
| `foreignkey/test_fk_with_attached_db.test` | 与 ATTACH 数据库的外键 |
| `foreignkey/test_fk_on_view_error.test` | 对视图定义外键的错误处理 |
| `foreignkey/fk_case_insensitivity.test` | 外键列名大小写不敏感 |
| `foreignkey/fk_implicit_primary_key.test` | 引用隐式主键的外键 |
| `foreignkey/foreign_key_matching_columns.test` | 外键列匹配规则 |

### 7.3 UNIQUE

**目录：** `test/sql/constraints/unique/`

| 文件 | 描述 |
|------|------|
| `unique/test_unique.test` | 基础 UNIQUE 约束 |
| `unique/test_unique_error.test` | UNIQUE 约束违反的错误信息 |
| `unique/test_unique_multi_column.test` | 多列联合 UNIQUE 约束 |
| `unique/test_unique_multi_constraint.test` | 一张表上多个 UNIQUE 约束 |
| `unique/test_unique_string.test` | 字符串列的 UNIQUE 约束 |
| `unique/test_unique_temp.test` | 临时表上的 UNIQUE 约束 |

### 7.4 CHECK

**目录：** `test/sql/constraints/check/`

| 文件 | 描述 |
|------|------|
| `check/test_check.test` | 基础 CHECK 约束（INSERT/UPDATE 验证） |
| `check/check_struct.test` | STRUCT 类型列的 CHECK 约束 |

### 7.5 NOT NULL

| 文件 | 描述 |
|------|------|
| `constraints/test_not_null.test` | NOT NULL 约束的 INSERT/UPDATE 验证 |
| `constraints/test_constraint_with_updates.test` | UPDATE 时的约束综合验证 |

---

## 八、MACRO / FUNCTION（宏/函数管理）

**目录：** `test/sql/catalog/function/`

| 文件 | 描述 |
|------|------|
| `function/test_simple_macro.test` | CREATE MACRO（标量宏）的基础用法 |
| `function/test_complex_macro.test` | 复杂宏（嵌套调用、多参数） |
| `function/test_table_macro.test` | CREATE MACRO 返回表的宏 |
| `function/test_table_macro_args.test` | 表宏的参数传递 |
| `function/test_table_macro_complex.test` | 复杂表宏（含 JOIN、子查询） |
| `function/test_table_macro_copy.test` | 表宏与 COPY 结合 |
| `function/test_table_macro_groups.test` | 表宏的分组操作 |
| `function/test_drop_macro.test` | DROP MACRO 及依赖检查 |
| `function/test_recursive_macro.test` | 递归宏的定义与执行 |
| `function/test_recursive_macro_no_dependency.test` | 无依赖的递归宏 |
| `function/test_macro_default_arg.test` | 宏的参数默认值 |
| `function/test_macro_default_arg_with_dependencies.test` | 含依赖的宏参数默认值 |
| `function/test_macro_overloads.test` | 同名宏的重载 |
| `function/test_macro_type_overloads.test` | 基于类型的宏重载 |
| `function/test_macro_with_unknown_types.test` | 宏参数中含未知类型的处理 |
| `function/test_subquery_macro.test` | 宏体中含子查询 |
| `function/test_cte_macro.test` | 宏体中含 CTE |
| `function/test_window_macro.test` | 宏体中含窗口函数 |
| `function/test_sequence_macro.test` | 宏中使用序列 |
| `function/query_function.test` | 查询函数的创建与调用 |
| `function/struct_extract_macro.test` | STRUCT 提取宏 |
| `function/python_style_macro_parameters.test` | Python 风格参数（kwargs）的宏 |
| `function/test_cross_catalog_macros.test` | 跨 catalog 的宏引用 |
| `function/attached_macro.test` | ATTACH 数据库中的宏 |
| `function/information_schema_macro.test` | 宏在 information_schema 中的可见性 |
| `function/macro_query_table.test` | 宏作为查询来源（FROM macro()） |
| `function/test_macro_relpersistence_conflict.test` | 临时与持久宏的冲突检测 |

---

## 九、CATALOG 管理

**目录：** `test/sql/catalog/`

### 9.1 依赖关系管理

**目录：** `test/sql/catalog/dependencies/`

| 文件 | 描述 |
|------|------|
| `dependencies/test_schema_dependency.test` | 模式上的对象依赖 |
| `dependencies/test_default_value_dependency.test` | 列默认值的依赖（序列、表达式） |
| `dependencies/test_prepared_dependency.test` | Prepared statement 的依赖追踪 |
| `dependencies/test_prepare_dependencies_transactions.test` | 事务中 Prepared statement 的依赖 |
| `dependencies/test_alter_dependency_ownership.test` | OWNED BY 关系的 ALTER 处理 |
| `dependencies/test_alter_owned_by.test` | ALTER ... OWNED BY 语义 |
| `dependencies/test_alter_owning_table.test` | 拥有者表被修改时的依赖行为 |
| `dependencies/test_concurrent_alter.test` | 并发 ALTER 的冲突检测 |
| `dependencies/test_concurrent_drop.test` | 并发 DROP 的冲突检测 |
| `dependencies/test_concurrent_index_creation.test` | 并发 CREATE INDEX 的冲突检测 |
| `dependencies/test_write_after_rename.test` | 重命名后立即写入的行为 |
| `dependencies/add_column_to_table_referenced_by_fk.test` | 被外键引用的表 ADD COLUMN |
| `dependencies/add_column_to_table_referenced_by_macro.test` | 被宏引用的表 ADD COLUMN |
| `dependencies/add_column_to_table_referenced_by_view.test` | 被视图引用的表 ADD COLUMN |
| `dependencies/change_type_of_table_column_referenced_by_index.test` | 被索引引用的列修改类型 |
| `dependencies/remove_table_column_referenced_by_index.test` | 删除被索引引用的列 |
| `dependencies/rename_table_column_referenced_by_index.test` | 重命名被索引引用的列 |
| `dependencies/rename_view_referenced_by_table_macro.test` | 重命名被宏引用的视图 |
| `dependencies/set_default_of_table_column_referenced_by_index.test` | 被索引引用的列设置默认值 |

### 9.2 COMMENT ON

| 文件 | 描述 |
|------|------|
| `catalog/comment_on.test` | COMMENT ON TABLE/COLUMN/VIEW/SEQUENCE/FUNCTION |
| `catalog/comment_on_column.test` | COMMENT ON COLUMN 的详细测试 |
| `catalog/comment_on_dependencies.test` | 注释与对象依赖关系 |
| `catalog/comment_on_extended.test` | COMMENT ON 扩展场景（自定义类型等） |
| `catalog/comment_on_pg_description.test` | pg_description 兼容视图中的注释 |
| `catalog/comment_on_wal.test` | COMMENT ON 的 WAL 持久化 |

### 9.3 大小写不敏感

| 文件 | 描述 |
|------|------|
| `catalog/case_insensitive_alter.test` | ALTER 语句中的大小写不敏感 |
| `catalog/case_insensitive_binder.test` | Binder 阶段的大小写不敏感 |
| `catalog/case_insensitive_caps.test` | 全大写/小写混合的标识符 |
| `catalog/case_insensitive_cte.test` | CTE 名称的大小写不敏感 |
| `catalog/case_insensitive_operations.test` | 各类 DDL 操作的大小写不敏感 |
| `catalog/case_insensitive_using.test` | JOIN USING 中的大小写不敏感 |

### 9.4 其他 Catalog 操作

| 文件 | 描述 |
|------|------|
| `catalog/test_catalog_errors.test` | 目录操作的错误信息规范 |
| `catalog/test_if_not_exists.test` | IF NOT EXISTS 在各类 DDL 中的语义 |
| `catalog/drop_create_rollback.test` | DROP + CREATE 在事务中回滚的行为 |
| `catalog/test_querying_from_detached_catalog.test` | 从 DETACH 后的 catalog 查询的错误处理 |
| `catalog/test_quoted_column_name.test` | 带引号的列名（大小写敏感标识符） |
| `catalog/information_schema_read_only.test` | information_schema 只读性验证 |
| `catalog/did_you_mean.test` | 拼写错误时的建议提示 |
| `catalog/test_extension_suggestion.test` | 未安装扩展时的建议提示 |
| `catalog/issue_9459.test` | issue 复现测试 |

---

## 十、ATTACH / DETACH（附加数据库）

**目录：** `test/sql/attach/`

| 文件 | 描述 |
|------|------|
| `attach/attach_table_ddl.test` | ATTACH 数据库中的完整 DDL（建表/ALTER/DROP） |
| `attach/attach_schema.test` | ATTACH 数据库中的 SCHEMA 操作 |
| `attach/attach_create_index.test` | ATTACH 数据库中的 CREATE INDEX |
| `attach/attach_index.test` | ATTACH 数据库中的索引行为 |
| `attach/attach_foreign_key.test` | ATTACH 数据库中的外键约束 |
| `attach/attach_macros.test` | ATTACH 数据库中的 MACRO 定义 |
| `attach/attach_wal_alter.test` | ATTACH 数据库中 ALTER 操作的 WAL 持久化 |
| `attach/attach_wal_alter_sequence.test` | ATTACH 数据库中序列 ALTER 的 WAL 持久化 |
| `attach/reattach_schema.test` | 重新 ATTACH 后的 SCHEMA 状态 |

---

## 十一、GENERATED COLUMNS（生成列）

**目录：** `test/sql/generated_columns/`

| 关联文件（在其他目录中） | 描述 |
|------|------|
| `alter/add_col/test_add_col_user_type.test` | 生成列相关的类型 |
| `alter/add_pk/test_add_pk_with_generated_column.test` | 含生成列时添加主键 |
| `alter/alter_type/test_alter_type_with_generated_column.test` | 修改生成列所依赖的列类型 |
| `alter/drop_col/test_drop_col_with_generated_cols.test` | 删除生成列依赖的源列 |

---

## 十二、系统表查询（DDL 元数据验证）

以下系统表和函数可用于验证 DDL 操作的结果：

```sql
-- 查询所有表
SELECT * FROM duckdb_tables();
SELECT * FROM information_schema.tables;

-- 查询列定义
SELECT * FROM duckdb_columns();
SELECT * FROM information_schema.columns;

-- 查询索引
SELECT * FROM duckdb_indexes();

-- 查询视图
SELECT * FROM duckdb_views();
SELECT * FROM information_schema.views;

-- 查询序列
SELECT * FROM duckdb_sequences();

-- 查询宏/函数
SELECT * FROM duckdb_functions();

-- 查询约束
SELECT * FROM duckdb_constraints();

-- 查询模式
SELECT * FROM duckdb_schemas();
SELECT * FROM information_schema.schemata;

-- 查询依赖关系
SELECT * FROM duckdb_dependencies();

-- 查询注释
SELECT comment FROM duckdb_tables() WHERE table_name = 'my_table';
SELECT comment FROM duckdb_columns() WHERE table_name = 'my_table';
```

---

## 十三、关键测试模式

以下是 DDL 测试中常见的验证模式，可直接复用到插件测试中：

### 13.1 基础 DDL + 回滚验证

```sql
statement ok
BEGIN TRANSACTION;

statement ok
CREATE TABLE t(i INTEGER);

-- 回滚后表不应存在
statement ok
ROLLBACK;

statement error
SELECT * FROM t;
----
Table with name t does not exist
```

### 13.2 IF NOT EXISTS 语义

```sql
statement ok
CREATE TABLE t(i INTEGER);

-- 不报错，静默忽略
statement ok
CREATE TABLE IF NOT EXISTS t(i INTEGER);

-- 不带 IF NOT EXISTS 则报错
statement error
CREATE TABLE t(i INTEGER);
----
already exists
```

### 13.3 CASCADE DROP

```sql
statement ok
CREATE SCHEMA s1;

statement ok
CREATE TABLE s1.t(i INTEGER);

-- 不加 CASCADE 报错
statement error
DROP SCHEMA s1;
----
depends on schema

-- 加 CASCADE 成功
statement ok
DROP SCHEMA s1 CASCADE;
```

### 13.4 并发事务中的写-写冲突

```sql
statement ok con1
BEGIN;

statement ok con2
BEGIN;

statement ok con1
ALTER TABLE t ADD COLUMN j INTEGER;

-- con2 同时修改同一表，应报写-写冲突
statement error con2
ALTER TABLE t ADD COLUMN k INTEGER;
----
<REGEX>:TransactionContext Error.*write-write.*

statement ok con1
COMMIT;

statement ok con2
ROLLBACK;
```

### 13.5 依赖级联删除验证

```sql
statement ok
CREATE TABLE parent(id INTEGER PRIMARY KEY);

statement ok
CREATE TABLE child(id INTEGER, FOREIGN KEY(id) REFERENCES parent(id));

-- 不能删除被引用的行
statement error
DELETE FROM parent WHERE id = 1;
----
violates foreign key constraint
```

---

## 相关路径速查

```
test/sql/
├── alter/                   # ALTER TABLE 系列
│   ├── add_col/             # ADD COLUMN
│   ├── drop_col/            # DROP COLUMN
│   ├── rename_col/          # RENAME COLUMN
│   ├── alter_type/          # ALTER COLUMN TYPE
│   ├── alter_col/           # SET/DROP NOT NULL
│   ├── add_pk/              # ADD PRIMARY KEY
│   ├── default/             # SET/DROP DEFAULT
│   ├── rename_table/        # RENAME TABLE
│   ├── rename_view/         # RENAME VIEW
│   ├── rename_schema/       # RENAME SCHEMA
│   ├── struct/              # STRUCT 类型修改
│   ├── list/                # LIST<STRUCT> 类型修改
│   └── map/                 # MAP<k,STRUCT> 类型修改
├── catalog/                 # Catalog 管理
│   ├── dependencies/        # 对象依赖关系
│   ├── function/            # MACRO/FUNCTION
│   ├── sequence/            # SEQUENCE
│   ├── table/               # 建表测试
│   └── view/                # 视图测试
├── constraints/             # 约束
│   ├── check/               # CHECK
│   ├── foreignkey/          # FOREIGN KEY
│   ├── primarykey/          # PRIMARY KEY
│   └── unique/              # UNIQUE
├── create/                  # CREATE TABLE 系列
├── index/art/               # 索引（ART 实现）
│   ├── constraints/         # 索引约束
│   ├── create_drop/         # CREATE/DROP INDEX
│   └── storage/             # 索引存储
└── attach/                  # ATTACH/DETACH 数据库
```
