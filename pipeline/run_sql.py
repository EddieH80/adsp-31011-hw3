"""Run one or more .sql files against returns_dw and print every result set.

Usage (from HW3/, with RDS_* exported):
    python pipeline/run_sql.py sql/02_gold.sql sql/03_star_schema.sql sql/04_scd2_change.sql
    python pipeline/run_sql.py sql/05_analytical_queries.sql
Results are also saved to logs/results_<file>.txt for the report.
"""
from __future__ import annotations

import contextlib
import io
import sys
from pathlib import Path

from common import LOG_DIR, connect, run_sql_file, setup_logging

log = setup_logging("sql")


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    conn = connect()
    for name in sys.argv[1:]:
        path = Path(name)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            run_sql_file(conn, path, log, show_results=True)
        print(buffer.getvalue())
        LOG_DIR.mkdir(exist_ok=True)
        (LOG_DIR / f"results_{path.stem}.txt").write_text(buffer.getvalue())
    conn.close()


if __name__ == "__main__":
    main()
