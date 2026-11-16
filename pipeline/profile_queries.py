"""Part 2b - find the most expensive query: EXPLAIN ANALYZE every query in the given files.

Runs each query 3 times (the first warms the buffer pool) and reports the median of the
actual total time from MySQL's EXPLAIN ANALYZE, plus the rows read in the plan's first table scan.

Usage (from HW3/):
    python pipeline/profile_queries.py sql/05_analytical_queries.sql sql/07_showcase_queries.sql
    python pipeline/profile_queries.py sql/06_optimization.sql --plan    # print full plans
"""
from __future__ import annotations

import re
import statistics
import sys
from pathlib import Path

from common import LOG_DIR, connect, split_sql

TIME_RE = re.compile(r"actual time=([\d.]+)\.\.([\d.]+) rows=([\d.e+]+) loops=(\d+)")
# A query in the .sql file may already start with EXPLAIN ANALYZE (06_optimization.sql does, so it can
# be pasted straight into Workbench). Strip it here; explain() adds it back exactly once.
EXPLAIN_PREFIX = re.compile(r"^\s*EXPLAIN\s+ANALYZE\s+", re.IGNORECASE)


def explain(cur, stmt: str) -> tuple[float, str]:
    cur.execute("EXPLAIN ANALYZE " + stmt)
    plan = cur.fetchall()[0][0]
    first = TIME_RE.search(plan)
    return (float(first.group(2)) if first else float("nan")), plan


def main() -> None:
    files = [a for a in sys.argv[1:] if not a.startswith("--")]
    show_plan = "--plan" in sys.argv
    conn = connect()
    report = []
    with conn.cursor() as cur:
        for f in files:
            stmts = split_sql(Path(f).read_text())
            label_no = 0
            for stmt in stmts:
                stmt = EXPLAIN_PREFIX.sub("", stmt)
                head = stmt.lstrip().split()[0].upper()
                if head not in ("SELECT", "WITH"):
                    cur.execute(stmt)          # DDL/DML like the summary-table build in 06_optimization.sql
                    print(f"ran: {stmt.splitlines()[0][:90]}")
                    continue
                label_no += 1
                times, plan = [], ""
                for _ in range(3):
                    t, plan = explain(cur, stmt)
                    times.append(t)
                ms = statistics.median(times[1:])
                label = f"{Path(f).stem} #{label_no}"
                report.append((ms, label, plan))
                print(f"{label:<32} {ms:9.1f} ms")
                if show_plan:
                    print(plan)
    print("\nMost expensive first:")
    for ms, label, _ in sorted(report, reverse=True):
        print(f"  {label:<32} {ms:9.1f} ms")
    LOG_DIR.mkdir(exist_ok=True)
    out = LOG_DIR / ("profile_" + "_".join(Path(f).stem for f in files) + ".txt")
    out.write_text("\n\n".join(f"== {label}  {ms:.1f} ms\n{plan}" for ms, label, plan in report))
    print(f"Plans saved to {out}")
    conn.close()


if __name__ == "__main__":
    main()
