#!/usr/bin/env bash
cd "$1" || exit 1
python3 - <<'PY'
import random
from ledger import Ledger, InsufficientFunds
def total(l): return sum(l.balances.values())
l = Ledger(); l.open("a", 10_000); l.open("b", 0)
l.transfer("a", "b", 1000, fee_bps=25)            # fee 2.5 -> 3 cents
assert l.balance("b") == 1000 and l.balance("fees") == 3 and l.balance("a") == 8997, l.balances
assert total(l) == 10_000
l.transfer("a", "b", 100, fee_bps=0)
assert l.balance("fees") == 3
snap = dict(l.balances); n = len(l.entries)
try:
    l.transfer("a", "b", 8897, fee_bps=100); raise SystemExit("should be insufficient")
except InsufficientFunds: pass
assert l.balances == snap and len(l.entries) == n, "failed transfer changed state"
l.transfer("a", "b", 500, key="k1"); s2 = dict(l.balances)
l.transfer("a", "b", 500, key="k1")
assert l.balances == s2, "duplicate key applied twice"
for bad in (0, -5):
    try: l.transfer("a", "b", bad); raise SystemExit(f"accepted amount {bad}")
    except (ValueError, InsufficientFunds): pass
try: l.transfer("a", "nope", 1); raise SystemExit("accepted unknown account")
except (KeyError, ValueError): pass
assert l.balances == s2
try: l.transfer("a", "a", 10, fee_bps=100)
except ValueError: pass
assert total(l) == 10_000
random.seed(7)
m = Ledger(); [m.open(x, 50_000) for x in "pqr"]
for i in range(2000):
    s, d = random.sample("pqr", 2)
    try: m.transfer(s, d, random.randint(1, 30_000), fee_bps=random.choice([0, 1, 33, 250]))
    except InsufficientFunds: pass
    assert total(m) == 150_000 and min(m.balances.values()) >= 0
assert sum(d for _, d, _ in m.entries) == 150_000, "entries do not reconcile with balances"
for acct in m.balances:
    assert sum(d for a, d, _ in m.entries if a == acct) == m.balances[acct], "per-account reconciliation"
PY
