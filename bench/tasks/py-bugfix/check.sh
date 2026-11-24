#!/usr/bin/env bash
cd "$1" || exit 1
python3 - <<'PY'
import report
rows = report.load("sales.csv")
top = report.top_products(rows)
assert [n for n,_ in top] == ["gadget","widget","gizmo"], top
assert len(report.top_products(rows, n=1)) == 1
assert len(report.top_products(rows, n=10)) == 4
assert report.monthly_totals(rows)["2026-02"] == 22.25
PY
