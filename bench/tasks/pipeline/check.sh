#!/usr/bin/env bash
cd "$1" || exit 1
PY="${PY:-$(command -v python3 >/dev/null 2>&1 && echo python3 || echo python)}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
q() { "$PY" -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])" "$T/o.db" "$1"; }
"$PY" load.py events.jsonl "$T/o.db" >/dev/null || fail "first load crashed"
"$PY" load.py events.jsonl "$T/o.db" >/dev/null || fail "second load crashed"
[ "$(q 'select count(*) from events')" = 3 ] || fail "duplicates after rerun: $(q 'select count(*) from events')"
cat > "$T/more.jsonl" <<'J'
{"id": "e2", "user": "bo", "amount": 9.0, "ts": "2026-03-03T11:00:00Z"}
this is not json
{"id": "e4", "user": "cy"}

{"id": "e5", "user": "cy", "amount": 2.0, "ts": "2026-03-03T12:00:00Z"}
J
out=$("$PY" load.py "$T/more.jsonl" "$T/o.db" 2>&1) || fail "crashed on bad lines: $out"
[ "$(q 'select count(*) from events')" = 4 ] || fail "row count after mixed file: $(q 'select count(*) from events')"
[ "$(q "select amount from events where id='e2'")" = 9.0 ] || fail "e2 not replaced by newer copy"
[ "$(q "select count(*) from events where id='e5'")" = 1 ] || fail "good line after bad lines was not loaded"
echo "$out" | grep -q 2 || fail "output does not report 2 loaded/skipped: $out"
[ "$(q "select printf('%.2f', sum(amount)) from events")" = 17.25 ] || fail "sum wrong"
