#!/usr/bin/env bash
cd "$1" || exit 1
python3 - <<'PY'
import pricing
assert pricing.apply_tax(1050, 5) == 1103, pricing.apply_tax(1050, 5)
assert pricing.apply_tax(1000, 10) == 1100
assert pricing.apply_tax(10, 25) == 13          # 2.5 -> 3
assert pricing.apply_tax(333, 7) == 356         # 23.31 -> 23
assert pricing.apply_tax(1, 50) == 2            # 0.5 -> 1
assert pricing.apply_tax(115, 30) == 150
assert pricing.apply_tax(0, 20) == 0
assert pricing.order_total([(1050, 1)], 0, 5) == 1103
assert pricing.apply_discount(1000, 10) == 900
PY
[ $? -eq 0 ] || exit 1
python3 -m unittest -q test_pricing 2>/dev/null || { echo "FAIL: existing tests broken"; exit 1; }
n=$(grep -c 'def test_' test_pricing.py); [ "$n" -gt 3 ] || { echo "FAIL: no regression test added for the reported case"; exit 1; }
