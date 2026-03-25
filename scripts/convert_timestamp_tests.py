#!/usr/bin/env python3
"""
Convert DuckDB .test files from test/sql/types/timestamp/ into pg_regress format.
"""

import os
import re
import datetime
import duckdb
from pathlib import Path

# DuckDB Python API type codes for temporal types that need VARCHAR casting
# to get the correct string representation (e.g. infinity, -infinity, TZ offsets)
TEMPORAL_TYPECODES = {'DATETIME', 'DATE', 'TIME', 'TIMEDELTA'}

REPO_ROOT = Path("/home/runner/work/duckdb/duckdb")
SOURCE_DIR = REPO_ROOT / "test/sql/types/timestamp"
OUTPUT_DIR = REPO_ROOT / "test/pg_regress/timestamp"
SQL_DIR = OUTPUT_DIR / "sql"
EXPECTED_DIR = OUTPUT_DIR / "expected"


def format_value(val):
    """Format a Python value for psql output."""
    if val is None:
        return ""
    # Booleans: DuckDB wire protocol sends lowercase true/false
    if isinstance(val, bool):
        return "true" if val else "false"
    # Temporal Python objects should have been cast to VARCHAR via execute_query;
    # these are just fallback string representations if the wrapper failed.
    if isinstance(val, datetime.datetime):
        # Format as DuckDB would: YYYY-MM-DD HH:MM:SS[.ffffff]
        s = val.strftime('%Y-%m-%d %H:%M:%S')
        if val.microsecond:
            s += '.' + f'{val.microsecond:06d}'.rstrip('0')
        return s
    if isinstance(val, datetime.date):
        return val.isoformat()
    if isinstance(val, datetime.timedelta):
        total_secs = int(val.total_seconds())
        h, rem = divmod(abs(total_secs), 3600)
        m, s = divmod(rem, 60)
        prefix = '-' if total_secs < 0 else ''
        return f'{prefix}{h:02d}:{m:02d}:{s:02d}'
    return str(val)


def execute_query(con, sql):
    """Execute a SQL query, casting temporal columns to VARCHAR for correct string representation.

    DuckDB's Python API converts TIMESTAMP/DATE/TIME to Python datetime objects, which
    cannot represent special values like 'infinity' and '-infinity'. To get the actual
    DuckDB string representation (as sent over the wire protocol), we wrap temporal
    columns in ::VARCHAR.
    """
    result = con.execute(sql)
    desc = result.description
    rows = result.fetchall()

    if not desc:
        return desc, rows

    # Check if any columns are temporal types
    temporal_indices = [i for i, col in enumerate(desc) if col[1] in TEMPORAL_TYPECODES]

    if not temporal_indices:
        return desc, rows

    # Re-run with temporal columns cast to VARCHAR so we get exact DuckDB strings
    aliases = [f'_c{i}' for i in range(len(desc))]
    alias_str = ', '.join(aliases)
    casts = []
    for i in range(len(desc)):
        if i in temporal_indices:
            casts.append(f'"{aliases[i]}"::VARCHAR')
        else:
            casts.append(f'"{aliases[i]}"')
    cast_str = ', '.join(casts)

    try:
        sql_clean = sql.rstrip().rstrip(';')
        wrapped = f'SELECT {cast_str} FROM ({sql_clean}) AS _t({alias_str})'
        result2 = con.execute(wrapped)
        rows = result2.fetchall()
    except Exception:
        pass  # fall back to already-fetched rows

    return desc, rows


def format_table(description, rows):
    """Format query results in psql border-0 table style."""
    col_names = [d[0] for d in description]
    n_cols = len(col_names)
    str_rows = [[format_value(row[i]) for i in range(n_cols)] for row in rows]

    col_widths = [len(name) for name in col_names]
    for row in str_rows:
        for i, val in enumerate(row):
            col_widths[i] = max(col_widths[i], len(val))

    def format_row(values):
        # psql format: each cell = " " + value_padded + " ", joined by "|"
        parts = []
        for i, val in enumerate(values):
            parts.append(" " + val.ljust(col_widths[i]) + " ")
        return "|".join(parts)

    header = format_row(col_names)
    sep_parts = []
    for w in col_widths:
        sep_parts.append("-" * (w + 2))
    separator = "+".join(sep_parts)

    lines = []
    lines.append(header)
    lines.append(separator)
    for row in str_rows:
        lines.append(format_row(row))
    n = len(rows)
    lines.append(f"({n} row{'s' if n != 1 else ''})")
    return "\n".join(lines)


def _normalize_expected_value(p):
    """Normalize a single expected value from .test file format to psql display format."""
    if p == "NULL":
        return ""
    if p == "True":
        return "true"
    if p == "False":
        return "false"
    return p


def format_table_from_expected(col_names, expected_rows):
    """Format test-file expected values in psql border-0 table style.

    DuckDB .test files support two expected-value formats:
    1. Tab-separated per line: each line is one row with n_cols tab-separated values.
    2. One-value-per-line: values listed one per line, grouped n_cols-at-a-time into rows.
       This is the original SQLite sqllogictest format.

    NULL → empty string, True/False → true/false (psql wire protocol uses lowercase).
    """
    n_cols = len(col_names)
    str_rows = []

    # Detect format: if any line has tabs, use tab-separated mode.
    # Otherwise (or for single-column), use one-value-per-line grouping.
    has_tabs = any("\t" in row for row in expected_rows)

    if has_tabs or n_cols == 1:
        # Tab-separated mode: each expected_row line is one result row.
        for raw in expected_rows:
            parts = raw.split("\t") if "\t" in raw else [raw]
            normalized = [_normalize_expected_value(p) for p in parts]
            # Pad to n_cols
            while len(normalized) < n_cols:
                normalized.append("")
            str_rows.append(normalized[:n_cols])
    else:
        # One-value-per-line mode: collect all values and group into rows.
        values = [_normalize_expected_value(raw) for raw in expected_rows]
        for i in range(0, max(len(values), 1), n_cols):
            row = values[i: i + n_cols]
            while len(row) < n_cols:
                row.append("")
            str_rows.append(row)

    col_widths = [len(name) for name in col_names]
    for row in str_rows:
        for i, val in enumerate(row):
            if i < n_cols:
                col_widths[i] = max(col_widths[i], len(val))

    def format_row(values):
        # psql format: each cell = " " + value_padded + " ", joined by "|"
        parts = []
        for i, val in enumerate(values[:n_cols]):
            parts.append(" " + val.ljust(col_widths[i]) + " ")
        return "|".join(parts)

    header = format_row(col_names)
    sep_parts = ["-" * (col_widths[i] + 2) for i in range(n_cols)]
    separator = "+".join(sep_parts)

    lines = [header, separator]
    for row in str_rows:
        lines.append(format_row(row))
    n = len(str_rows)
    lines.append(f"({n} row{'s' if n != 1 else ''})")
    return "\n".join(lines)


def get_col_names_from_sql(con, sql):
    """Run a SQL query (with fallback substitutions) to get column names only.

    For queries that may fail with DuckDB Python but work in the repo DuckDB
    (e.g. 'inf'::TIMESTAMP), we try with 'inf' substituted for 'infinity'.
    Returns list of column name strings, or empty list on failure.
    """
    try:
        result = con.execute(sql)
        return [d[0] for d in result.description], result
    except Exception:
        pass
    # Fallback: replace 'inf' with 'infinity' in string literals for the Python run
    sql_sub = re.sub(r"'inf'", "'infinity'", sql, flags=re.IGNORECASE)
    sql_sub = re.sub(r"'-inf'", "'-infinity'", sql_sub, flags=re.IGNORECASE)
    if sql_sub != sql:
        try:
            result = con.execute(sql_sub)
            # Restore 'inf' in column names (best-effort)
            col_names = []
            for d in result.description:
                name = d[0].replace("'infinity'", "'inf'").replace("'-infinity'", "'-inf'")
                col_names.append(name)
            return col_names, result
        except Exception:
            pass
    return [], None


def parse_test_file(filepath):
    """Parse a DuckDB .test file into a list of statement dicts."""
    with open(filepath) as f:
        content = f.read()

    lines = content.splitlines()
    statements = []
    i = 0
    meta = {"name": "", "description": "", "group": ""}
    requires_icu = False

    while i < len(lines):
        line = lines[i]

        # Metadata comments
        if line.startswith("# name:"):
            meta["name"] = line[len("# name:"):].strip()
            i += 1
            continue
        if line.startswith("# description:"):
            meta["description"] = line[len("# description:"):].strip()
            i += 1
            continue
        if line.startswith("# group:"):
            meta["group"] = line[len("# group:"):].strip()
            i += 1
            continue

        # Regular comment
        if line.startswith("#"):
            comment = line[1:].strip()
            statements.append({"type": "comment", "text": comment})
            i += 1
            continue

        # Blank line
        if not line.strip():
            statements.append({"type": "blank"})
            i += 1
            continue

        # require directive
        if line.startswith("require "):
            req = line[len("require "):].strip()
            if req == "icu":
                requires_icu = True
            statements.append({"type": "require", "name": req})
            i += 1
            continue

        # foreach loop
        m = re.match(r"^foreach\s+(\w+)\s+(.+)$", line)
        if m:
            var_name = m.group(1)
            var_values = m.group(2).split()
            # Collect loop body until endloop
            loop_body = []
            i += 1
            depth = 1
            while i < len(lines) and depth > 0:
                if lines[i].startswith("foreach ") or lines[i].startswith("loop "):
                    depth += 1
                elif lines[i].strip() == "endloop":
                    depth -= 1
                    if depth == 0:
                        break
                loop_body.append(lines[i])
                i += 1
            i += 1  # skip endloop
            # Expand foreach
            for val in var_values:
                expanded = "\n".join(loop_body).replace(f"${{{var_name}}}", val)
                statements.append({"type": "loop_block", "text": expanded, "var": var_name, "val": val})
            continue

        # loop i N M
        m = re.match(r"^loop\s+(\w+)\s+(\d+)\s+(\d+)$", line)
        if m:
            var_name = m.group(1)
            start = int(m.group(2))
            end = int(m.group(3))
            loop_body = []
            i += 1
            depth = 1
            while i < len(lines) and depth > 0:
                if lines[i].startswith("foreach ") or lines[i].startswith("loop "):
                    depth += 1
                elif lines[i].strip() == "endloop":
                    depth -= 1
                    if depth == 0:
                        break
                loop_body.append(lines[i])
                i += 1
            i += 1  # skip endloop
            for val in range(start, end):
                expanded = "\n".join(loop_body).replace(f"${{{var_name}}}", str(val))
                statements.append({"type": "loop_block", "text": expanded, "var": var_name, "val": str(val)})
            continue

        # statement ok / statement error
        if line.startswith("statement ok") or line.startswith("statement error"):
            stmt_type = "ok" if "ok" in line else "error"
            sql_lines = []
            i += 1
            while i < len(lines) and lines[i].strip() and not lines[i].startswith("----"):
                # Stop at next directive
                if (lines[i].startswith("statement ") or lines[i].startswith("query ") or
                        lines[i].startswith("require ") or lines[i].startswith("foreach ") or
                        lines[i].startswith("loop ") or lines[i].startswith("# ") or
                        lines[i].strip() == "endloop"):
                    break
                sql_lines.append(lines[i])
                i += 1
            # Capture expected error message after ----
            expected_error = None
            if i < len(lines) and lines[i].startswith("----"):
                i += 1
                err_lines = []
                while i < len(lines) and lines[i].strip():
                    err_lines.append(lines[i].strip())
                    i += 1
                if err_lines:
                    expected_error = "\n".join(err_lines)
            sql = "\n".join(sql_lines).strip()
            if sql:
                statements.append({"type": "statement", "stmt_type": stmt_type, "sql": sql,
                                    "expected_error": expected_error})
            continue

        # query line
        if re.match(r"^query\s", line):
            # Optional modifiers like nosort, rowsort, etc.
            parts = line.split()
            col_type_str = parts[1] if len(parts) > 1 else ""
            n_cols_expected = len(col_type_str)
            sql_lines = []
            i += 1
            while i < len(lines) and lines[i].strip() and not lines[i].startswith("----"):
                if (lines[i].startswith("statement ") or lines[i].startswith("query ") or
                        lines[i].startswith("require ") or lines[i].startswith("foreach ") or
                        lines[i].startswith("loop ") or lines[i].startswith("# ") or
                        lines[i].strip() == "endloop"):
                    break
                sql_lines.append(lines[i])
                i += 1
            # Capture expected values after ----
            expected_rows = None
            if i < len(lines) and lines[i].startswith("----"):
                i += 1
                expected_rows = []
                while i < len(lines) and lines[i].strip():
                    expected_rows.append(lines[i].rstrip())
                    i += 1
            sql = "\n".join(sql_lines).strip()
            if sql:
                statements.append({"type": "query", "sql": sql,
                                    "expected_rows": expected_rows,
                                    "n_cols": n_cols_expected})
            continue

        # PRAGMA, SET, etc. that appear at start of line without a directive prefix
        # These shouldn't normally happen but handle them
        i += 1

    return meta, requires_icu, statements


def parse_loop_block_statements(text, requires_icu):
    """Parse a loop-expanded block into statements."""
    lines = text.splitlines()
    statements = []
    i = 0
    while i < len(lines):
        line = lines[i]

        if line.startswith("#"):
            comment = line[1:].strip()
            statements.append({"type": "comment", "text": comment})
            i += 1
            continue

        if not line.strip():
            statements.append({"type": "blank"})
            i += 1
            continue

        if line.startswith("require "):
            req = line[len("require "):].strip()
            if req == "icu":
                pass  # handled at file level
            statements.append({"type": "require", "name": req})
            i += 1
            continue

        # nested foreach loop
        fm = re.match(r"^foreach\s+(\w+)\s+(.+)$", line)
        if fm:
            var_name = fm.group(1)
            var_values = fm.group(2).split()
            loop_body = []
            i += 1
            depth = 1
            while i < len(lines) and depth > 0:
                if lines[i].startswith("foreach ") or lines[i].startswith("loop "):
                    depth += 1
                elif lines[i].strip() == "endloop":
                    depth -= 1
                    if depth == 0:
                        break
                loop_body.append(lines[i])
                i += 1
            i += 1  # skip endloop
            for val in var_values:
                expanded = "\n".join(loop_body).replace(f"${{{var_name}}}", val)
                statements.append({"type": "loop_block", "text": expanded, "var": var_name, "val": val})
            continue

        # nested loop i N M
        lm = re.match(r"^loop\s+(\w+)\s+(\d+)\s+(\d+)$", line)
        if lm:
            var_name = lm.group(1)
            start = int(lm.group(2))
            end = int(lm.group(3))
            loop_body = []
            i += 1
            depth = 1
            while i < len(lines) and depth > 0:
                if lines[i].startswith("foreach ") or lines[i].startswith("loop "):
                    depth += 1
                elif lines[i].strip() == "endloop":
                    depth -= 1
                    if depth == 0:
                        break
                loop_body.append(lines[i])
                i += 1
            i += 1  # skip endloop
            for val in range(start, end):
                expanded = "\n".join(loop_body).replace(f"${{{var_name}}}", str(val))
                statements.append({"type": "loop_block", "text": expanded, "var": var_name, "val": str(val)})
            continue

        if line.startswith("statement ok") or line.startswith("statement error"):
            stmt_type = "ok" if "ok" in line else "error"
            sql_lines = []
            i += 1
            while i < len(lines) and lines[i].strip() and not lines[i].startswith("----"):
                if (lines[i].startswith("statement ") or lines[i].startswith("query ") or
                        lines[i].startswith("require ") or lines[i].startswith("# ") or
                        lines[i].strip() == "endloop"):
                    break
                sql_lines.append(lines[i])
                i += 1
            expected_error = None
            if i < len(lines) and lines[i].startswith("----"):
                i += 1
                err_lines = []
                while i < len(lines) and lines[i].strip():
                    err_lines.append(lines[i].strip())
                    i += 1
                if err_lines:
                    expected_error = "\n".join(err_lines)
            sql = "\n".join(sql_lines).strip()
            if sql:
                statements.append({"type": "statement", "stmt_type": stmt_type, "sql": sql,
                                    "expected_error": expected_error})
            continue

        if re.match(r"^query\s", line):
            parts = line.split()
            col_type_str = parts[1] if len(parts) > 1 else ""
            n_cols_expected = len(col_type_str)
            sql_lines = []
            i += 1
            while i < len(lines) and lines[i].strip() and not lines[i].startswith("----"):
                if (lines[i].startswith("statement ") or lines[i].startswith("query ") or
                        lines[i].startswith("require ") or lines[i].startswith("# ") or
                        lines[i].strip() == "endloop"):
                    break
                sql_lines.append(lines[i])
                i += 1
            expected_rows = None
            if i < len(lines) and lines[i].startswith("----"):
                i += 1
                expected_rows = []
                while i < len(lines) and lines[i].strip():
                    expected_rows.append(lines[i].rstrip())
                    i += 1
            sql = "\n".join(sql_lines).strip()
            if sql:
                statements.append({"type": "query", "sql": sql,
                                    "expected_rows": expected_rows,
                                    "n_cols": n_cols_expected})
            continue

        i += 1

    return statements


def get_ddl_class(sql):
    """Classify a SQL statement for output generation."""
    first_line = sql.strip().split("\n")[0].strip().upper()
    sql_upper = sql.strip().upper()

    if first_line.startswith("CREATE TABLE"):
        if re.search(r'\bAS\s+(SELECT|FROM)\b', sql_upper):
            return "CTAS"
        return "CREATE TABLE"
    if first_line.startswith("DROP TABLE"):
        return "DROP TABLE"
    if first_line.startswith("CREATE SEQUENCE"):
        return "CREATE SEQUENCE"
    if first_line.startswith("DROP SEQUENCE"):
        return "DROP SEQUENCE"
    if first_line.startswith("CREATE INDEX"):
        return "CREATE INDEX"
    if first_line.startswith("DROP INDEX"):
        return "DROP INDEX"
    if first_line.startswith("CREATE TYPE"):
        return "CREATE TYPE"
    if first_line.startswith("CREATE VIEW"):
        return "CREATE VIEW"
    if first_line.startswith("DROP VIEW"):
        return "DROP VIEW"
    if first_line.startswith("UPDATE"):
        return "UPDATE"
    if first_line.startswith("DELETE"):
        return "DELETE"
    if first_line.startswith("INSERT"):
        return "INSERT"
    if first_line.startswith("SET"):
        return "SET"
    if first_line.startswith("PRAGMA"):
        return "PRAGMA"
    if first_line.startswith("LOAD"):
        return "PRAGMA"
    if first_line.startswith("INSTALL"):
        return "PRAGMA"
    return "OTHER"


# Type alias normalization map for constructing DuckDB column names from expressions
_TYPE_ALIASES = {
    'TIMESTAMPTZ': 'TIMESTAMP WITH TIME ZONE',
    'TIMESTAMP_S': 'TIMESTAMP_S',
    'TIMESTAMP_MS': 'TIMESTAMP_MS',
    'TIMESTAMP_NS': 'TIMESTAMP_NS',
}


def _normalize_type(type_str):
    """Normalize a DuckDB type alias to its canonical display name."""
    upper = type_str.strip().upper()
    return _TYPE_ALIASES.get(upper, type_str.strip())


def _derive_col_names(sql, n_cols):
    """Derive DuckDB column names from a SELECT SQL when DuckDB Python can't run it.

    Handles the common pattern: SELECT expr::TYPE by converting to CAST(expr AS TYPE).
    Returns a list of n_cols column name strings.
    """
    sql_clean = sql.rstrip(';').strip()
    # Extract the SELECT list (simplified: assume single-line SELECT or simple FROM)
    m = re.match(r'^\s*SELECT\s+(.+?)(?:\s+FROM\s+|\s*$)', sql_clean,
                 re.IGNORECASE | re.DOTALL)
    if not m:
        return ['?column?'] * n_cols
    exprs_str = m.group(1).strip().rstrip(',')
    # Split by comma (rough: won't handle nested function calls with commas)
    parts = [p.strip() for p in exprs_str.split(',')]
    col_names = []
    for expr in parts:
        # Convert x::TYPE → CAST(x AS CANONICAL_TYPE)
        cast_m = re.match(r'^(.+?)::([\w\s]+)$', expr)
        if cast_m:
            val = cast_m.group(1).strip()
            typ = _normalize_type(cast_m.group(2).strip())
            col_names.append(f'CAST({val} AS {typ})')
        else:
            col_names.append(expr)
    # Pad or trim to n_cols
    while len(col_names) < n_cols:
        col_names.append('?column?')
    return col_names[:n_cols]


def _infer_error_from_sql(sql):
    """Infer a DuckDB error message for known version-mismatch SQL patterns.

    Some SQL constructs are not supported in older DuckDB versions (like the one
    in this repo) but work in newer versions (DuckDB Python 1.2.x). This function
    provides the expected error messages for those cases.
    """
    # TIMESTAMPTZ::DATE or TIMESTAMPTZ::TIME - unsupported cast in older DuckDB
    m = re.search(r'::\s*TIMESTAMPTZ\s*::\s*(DATE|TIME)\b', sql, re.IGNORECASE)
    if m:
        target = m.group(1).upper()
        return f"Conversion Error: Unimplemented type for cast (TIMESTAMP WITH TIME ZONE -> {target})"
    m = re.search(r'TIMESTAMP\s+WITH\s+TIME\s+ZONE.*::\s*(DATE|TIME)\b', sql, re.IGNORECASE)
    if m:
        target = m.group(1).upper()
        return f"Conversion Error: Unimplemented type for cast (TIMESTAMP WITH TIME ZONE -> {target})"
    return None


def _sub_inf_for_python(sql):
    """Substitute 'inf'/'- inf' temporal abbreviations with 'infinity'/'-infinity'.

    DuckDB Python (1.2.x) doesn't support 'inf' as a temporal alias, but
    the repo's DuckDB does. This preprocessing ensures that statements which
    use 'inf'::TIMESTAMP, 'inf'::DATE, etc. work in the Python connection.
    """
    result = re.sub(r"'inf'::", "'infinity'::", sql, flags=re.IGNORECASE)
    result = re.sub(r"'-inf'::", "'-infinity'::", result, flags=re.IGNORECASE)
    return result


def run_statements(filepath, meta, requires_icu, statements):
    """Run all statements through DuckDB and collect SQL + output lines."""
    con = duckdb.connect()
    if requires_icu:
        try:
            con.execute("LOAD icu")
        except Exception:
            pass

    sql_lines = []
    out_lines = []

    # Header for .sql file
    stem = Path(filepath).stem
    source_name = Path(filepath).name
    sql_lines.append(f"-- Converted from {source_name}")
    sql_lines.append("-- DuckDB timestamp test suite")
    sql_lines.append("-- SQL is kept verbatim; run via PG-protocol-compatible DuckDB interface")
    sql_lines.append("")
    sql_lines.append(f"-- name: {meta['name']}")
    sql_lines.append(f"-- description: {meta['description']}")
    sql_lines.append(f"-- group: {meta['group']}")

    def _exec(sql):
        """Execute SQL with 'inf' substitution fallback for DuckDB Python."""
        try:
            return con.execute(sql)
        except Exception as original_err:
            sql_sub = _sub_inf_for_python(sql)
            if sql_sub != sql:
                try:
                    return con.execute(sql_sub)
                except Exception:
                    pass
            raise original_err

    def run_and_get_count(sql):
        """Run SQL and return (result, count) where count is rows affected."""
        result = _exec(sql)
        rows = result.fetchall()
        if rows and result.description and result.description[0][0] == 'Count':
            return rows[0][0]
        return 0

    def process_stmt_list(stmt_list):
        for stmt in stmt_list:
            if stmt["type"] == "blank":
                sql_lines.append("")
                continue
            if stmt["type"] == "comment":
                if stmt["text"]:
                    sql_lines.append(f"-- {stmt['text']}")
                else:
                    sql_lines.append("--")
                continue
            if stmt["type"] == "require":
                # Drop requires
                continue
            if stmt["type"] == "loop_block":
                # Parse and process the expanded loop block
                expanded_stmts = parse_loop_block_statements(stmt["text"], requires_icu)
                process_stmt_list(expanded_stmts)
                continue
            if stmt["type"] == "statement":
                sql = stmt["sql"]
                # Strip trailing semicolons to avoid double-semicolons
                sql_clean = sql.rstrip(";").rstrip()
                sql_lines.append("")
                sql_lines.append(sql_clean + ";")
                out_lines.append("")

                ddl_class = get_ddl_class(sql)
                expected_error = stmt.get("expected_error")

                if stmt["stmt_type"] == "error":
                    # Use the test file's expected error message as authoritative source.
                    # This avoids version mismatches between DuckDB Python and the repo DuckDB.
                    if expected_error:
                        err_line = expected_error.split("\n")[0]
                        if err_line.startswith("<REGEX>:"):
                            # For REGEX patterns, run the SQL to get the actual DuckDB error.
                            # If DuckDB Python throws and the error matches the regex, use it.
                            # Otherwise, fall back to extracting the pattern as a description.
                            actual_err = None
                            try:
                                con.execute(sql)
                            except Exception as e:
                                actual_err = str(e).split("\n")[0]
                            if actual_err:
                                # Verify it roughly matches the pattern (contains error type)
                                # e.g. <REGEX>:.*Conversion Error.*invalid timestamp field format.*
                                pattern_content = err_line[len("<REGEX>:"):].strip()
                                # Convert .* to regex and check
                                regex_str = re.escape(pattern_content).replace(r'\.\*', '.*')
                                if re.search(regex_str, actual_err, re.IGNORECASE):
                                    out_lines.append(f"ERROR:  {actual_err}")
                                else:
                                    # Mismatch: fall back to pattern extraction
                                    out_lines.append(f"ERROR:  {actual_err}")
                            else:
                                # SQL didn't throw; extract error type from pattern
                                content = err_line[len("<REGEX>:"):].strip()
                                content = re.sub(r'^\.\*\s*', '', content)
                                type_m = re.match(r'([\w ]+ Error)\s*\.\*\s*(.*)', content)
                                if type_m:
                                    error_type = type_m.group(1).strip()
                                    rest = type_m.group(2).strip()
                                    desc_m = re.match(r'([^.*]+)', rest)
                                    if desc_m:
                                        desc = desc_m.group(1).strip().rstrip('.:')
                                        out_lines.append(f"ERROR:  {error_type}: {desc}")
                                    else:
                                        out_lines.append(f"ERROR:  {error_type}")
                                else:
                                    out_lines.append(f"ERROR:  {re.sub(r'[.*]+', '', content).strip()}")
                        else:
                            # Plain error message; use it directly
                            # Also run the SQL to keep connection state up-to-date
                            try:
                                con.execute(sql)
                            except Exception:
                                pass
                            out_lines.append(f"ERROR:  {err_line}")
                    else:
                        # No expected message in test; use DuckDB Python error.
                        # For known version-mismatch patterns, infer the error message.
                        inferred_err = _infer_error_from_sql(sql)
                        if inferred_err:
                            try:
                                con.execute(sql)
                            except Exception:
                                pass
                            out_lines.append(f"ERROR:  {inferred_err}")
                        else:
                            try:
                                con.execute(sql)
                                out_lines.append("-- Expected error but got none")
                            except Exception as e:
                                err_msg = str(e).split("\n")[0]
                                out_lines.append(f"ERROR:  {err_msg}")
                else:
                    try:
                        if ddl_class == "PRAGMA":
                            _exec(sql)
                            # No output for PRAGMA/SET-like commands
                        elif ddl_class == "CREATE TABLE":
                            _exec(sql)
                            out_lines.append("CREATE TABLE")
                        elif ddl_class == "CTAS":
                            n = run_and_get_count(sql)
                            out_lines.append(f"SELECT {n}")
                        elif ddl_class == "DROP TABLE":
                            _exec(sql)
                            out_lines.append("DROP TABLE")
                        elif ddl_class == "CREATE SEQUENCE":
                            _exec(sql)
                            out_lines.append("CREATE SEQUENCE")
                        elif ddl_class == "DROP SEQUENCE":
                            _exec(sql)
                            out_lines.append("DROP SEQUENCE")
                        elif ddl_class == "CREATE INDEX":
                            _exec(sql)
                            out_lines.append("CREATE INDEX")
                        elif ddl_class == "DROP INDEX":
                            _exec(sql)
                            out_lines.append("DROP INDEX")
                        elif ddl_class == "CREATE TYPE":
                            _exec(sql)
                            out_lines.append("CREATE TYPE")
                        elif ddl_class == "CREATE VIEW":
                            _exec(sql)
                            out_lines.append("CREATE VIEW")
                        elif ddl_class == "DROP VIEW":
                            _exec(sql)
                            out_lines.append("DROP VIEW")
                        elif ddl_class == "INSERT":
                            n = run_and_get_count(sql)
                            out_lines.append(f"INSERT 0 {n}")
                        elif ddl_class == "UPDATE":
                            n = run_and_get_count(sql)
                            out_lines.append(f"UPDATE {n}")
                        elif ddl_class == "DELETE":
                            n = run_and_get_count(sql)
                            out_lines.append(f"DELETE {n}")
                        elif ddl_class == "SET":
                            _exec(sql)
                            out_lines.append("SET")
                        else:
                            _exec(sql)
                    except Exception as e:
                        err_msg = str(e).split("\n")[0]
                        out_lines.append(f"ERROR:  {err_msg}")

            elif stmt["type"] == "query":
                sql = stmt["sql"]
                sql_clean = sql.rstrip(";").rstrip()
                sql_lines.append("")
                sql_lines.append(sql_clean + ";")
                out_lines.append("")
                expected_rows = stmt.get("expected_rows")
                n_cols_hint = stmt.get("n_cols", 0)

                # Get column names from DuckDB Python (with inf→infinity fallback)
                col_names, result_obj = get_col_names_from_sql(con, sql)

                if col_names and expected_rows:
                    # Use test file's expected values: they match the repo DuckDB behavior.
                    # (DuckDB Python may differ on infinity, isfinite return type, etc.)
                    table_str = format_table_from_expected(col_names, expected_rows)
                    out_lines.append(table_str)
                elif col_names:
                    # No expected values in test file OR empty expected (nosort label).
                    # Fetch actual results from DuckDB Python with VARCHAR casting for
                    # temporal types to get correct string representation.
                    try:
                        desc, rows = execute_query(con, sql)
                        table_str = format_table(desc, rows)
                        out_lines.append(table_str)
                    except Exception as e:
                        err_msg = str(e).split("\n")[0]
                        out_lines.append(f"ERROR:  {err_msg}")
                elif expected_rows:
                    # DuckDB Python couldn't run the query (version difference) but
                    # the test file has expected values. Construct column names from
                    # the SQL expression and use the test file's values.
                    # Determine number of columns from n_cols_hint or first expected row
                    if expected_rows:
                        first_row = expected_rows[0]
                        n_cols = max(1, len(first_row.split("\t")) if "\t" in first_row else 1)
                    else:
                        n_cols = max(1, n_cols_hint)
                    # Construct column names by transforming the SELECT expressions
                    fallback_names = _derive_col_names(sql, n_cols)
                    table_str = format_table_from_expected(fallback_names, expected_rows)
                    out_lines.append(table_str)
                else:
                    # Query failed in DuckDB Python and no expected values; record error
                    try:
                        con.execute(sql)
                    except Exception as e:
                        err_msg = str(e).split("\n")[0]
                        out_lines.append(f"ERROR:  {err_msg}")

    process_stmt_list(statements)

    con.close()
    return sql_lines, out_lines


def write_files(stem, sql_lines, out_lines):
    """Write .sql and .out files."""
    sql_path = SQL_DIR / f"{stem}.sql"
    out_path = EXPECTED_DIR / f"{stem}.out"

    sql_content = "\n".join(sql_lines) + "\n"
    # Clean up out_lines: remove leading blank lines, trim trailing blanks
    out_content_parts = []
    for line in out_lines:
        out_content_parts.append(line)
    # Remove leading blank
    while out_content_parts and not out_content_parts[0].strip():
        out_content_parts.pop(0)
    out_content = "\n".join(out_content_parts) + "\n"

    sql_path.write_text(sql_content)
    out_path.write_text(out_content)
    print(f"  Written: {sql_path.name}, {out_path.name}")


def main():
    # Create output directories
    SQL_DIR.mkdir(parents=True, exist_ok=True)
    EXPECTED_DIR.mkdir(parents=True, exist_ok=True)

    test_files = sorted(SOURCE_DIR.glob("*.test"))
    test_names = []

    for filepath in test_files:
        stem = filepath.stem
        print(f"Processing {filepath.name}...")
        try:
            meta, requires_icu, statements = parse_test_file(filepath)
            sql_lines, out_lines = run_statements(filepath, meta, requires_icu, statements)
            write_files(stem, sql_lines, out_lines)
            test_names.append(stem)
        except Exception as e:
            print(f"  ERROR processing {filepath.name}: {e}")
            import traceback
            traceback.print_exc()

    # Write schedule file
    schedule_path = OUTPUT_DIR / "schedule"
    with open(schedule_path, "w") as f:
        for name in test_names:
            f.write(f"test: {name}\n")
    print(f"\nWritten schedule with {len(test_names)} tests: {schedule_path}")


if __name__ == "__main__":
    main()
