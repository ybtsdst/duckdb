#!/usr/bin/env python3
"""
Convert DuckDB .test files from test/sql/types/timestamp/ into pg_regress format.
"""

import os
import re
import duckdb
from pathlib import Path

REPO_ROOT = Path("/home/runner/work/duckdb/duckdb")
SOURCE_DIR = REPO_ROOT / "test/sql/types/timestamp"
OUTPUT_DIR = REPO_ROOT / "test/pg_regress/timestamp"
SQL_DIR = OUTPUT_DIR / "sql"
EXPECTED_DIR = OUTPUT_DIR / "expected"


def format_value(val):
    """Format a Python value for psql output."""
    if val is None:
        return ""
    return str(val)


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
        parts = []
        for i, val in enumerate(values):
            parts.append(" " + val.ljust(col_widths[i]))
        return "|".join(parts)

    header = format_row(col_names)
    separator = "+".join("-" * (col_widths[i] + 1) for i in range(n_cols))
    # separator has a leading '-' to match psql style (starts with -)
    sep_parts = []
    for w in col_widths:
        sep_parts.append("-" * (w + 1))
    separator = "+".join(sep_parts)

    lines = []
    lines.append(header)
    lines.append(separator)
    for row in str_rows:
        lines.append(format_row(row))
    n = len(rows)
    lines.append(f"({n} row{'s' if n != 1 else ''})")
    return "\n".join(lines)


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
            # Skip ---- and any expected output
            if i < len(lines) and lines[i].startswith("----"):
                i += 1
                while i < len(lines) and lines[i].strip():
                    i += 1
            sql = "\n".join(sql_lines).strip()
            if sql:
                statements.append({"type": "statement", "stmt_type": stmt_type, "sql": sql})
            continue

        # query line
        if re.match(r"^query\s", line):
            # Optional modifiers like nosort, rowsort, etc.
            parts = line.split()
            # parts[0] = "query", parts[1] = type_string, parts[2:] = optional modifiers
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
            # Skip ---- and expected output
            if i < len(lines) and lines[i].startswith("----"):
                i += 1
                while i < len(lines) and (lines[i].strip() or (i + 1 < len(lines) and lines[i + 1].strip())):
                    # Read until blank line
                    if not lines[i].strip():
                        break
                    i += 1
            sql = "\n".join(sql_lines).strip()
            if sql:
                statements.append({"type": "query", "sql": sql})
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
            if i < len(lines) and lines[i].startswith("----"):
                i += 1
                while i < len(lines) and lines[i].strip():
                    i += 1
            sql = "\n".join(sql_lines).strip()
            if sql:
                statements.append({"type": "statement", "stmt_type": stmt_type, "sql": sql})
            continue

        if re.match(r"^query\s", line):
            sql_lines = []
            i += 1
            while i < len(lines) and lines[i].strip() and not lines[i].startswith("----"):
                if (lines[i].startswith("statement ") or lines[i].startswith("query ") or
                        lines[i].startswith("require ") or lines[i].startswith("# ") or
                        lines[i].strip() == "endloop"):
                    break
                sql_lines.append(lines[i])
                i += 1
            if i < len(lines) and lines[i].startswith("----"):
                i += 1
                while i < len(lines) and lines[i].strip():
                    i += 1
            sql = "\n".join(sql_lines).strip()
            if sql:
                statements.append({"type": "query", "sql": sql})
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

    def run_and_get_count(sql):
        """Run SQL and return (result, count) where count is rows affected."""
        result = con.execute(sql)
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

                if stmt["stmt_type"] == "error":
                    try:
                        con.execute(sql)
                        out_lines.append("-- Expected error but got none")
                    except Exception as e:
                        err_msg = str(e).split("\n")[0]
                        out_lines.append(f"ERROR:  {err_msg}")
                else:
                    try:
                        if ddl_class == "PRAGMA":
                            con.execute(sql)
                            # No output for PRAGMA/SET-like commands
                        elif ddl_class == "CREATE TABLE":
                            con.execute(sql)
                            out_lines.append("CREATE TABLE")
                        elif ddl_class == "CTAS":
                            n = run_and_get_count(sql)
                            out_lines.append(f"SELECT {n}")
                        elif ddl_class == "DROP TABLE":
                            con.execute(sql)
                            out_lines.append("DROP TABLE")
                        elif ddl_class == "CREATE SEQUENCE":
                            con.execute(sql)
                            out_lines.append("CREATE SEQUENCE")
                        elif ddl_class == "DROP SEQUENCE":
                            con.execute(sql)
                            out_lines.append("DROP SEQUENCE")
                        elif ddl_class == "CREATE INDEX":
                            con.execute(sql)
                            out_lines.append("CREATE INDEX")
                        elif ddl_class == "DROP INDEX":
                            con.execute(sql)
                            out_lines.append("DROP INDEX")
                        elif ddl_class == "CREATE TYPE":
                            con.execute(sql)
                            out_lines.append("CREATE TYPE")
                        elif ddl_class == "CREATE VIEW":
                            con.execute(sql)
                            out_lines.append("CREATE VIEW")
                        elif ddl_class == "DROP VIEW":
                            con.execute(sql)
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
                            con.execute(sql)
                            out_lines.append("SET")
                        else:
                            con.execute(sql)
                    except Exception as e:
                        err_msg = str(e).split("\n")[0]
                        out_lines.append(f"ERROR:  {err_msg}")

            elif stmt["type"] == "query":
                sql = stmt["sql"]
                sql_clean = sql.rstrip(";").rstrip()
                sql_lines.append("")
                sql_lines.append(sql_clean + ";")
                out_lines.append("")
                try:
                    result = con.execute(sql)
                    desc = result.description
                    rows = result.fetchall()
                    table_str = format_table(desc, rows)
                    out_lines.append(table_str)
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
