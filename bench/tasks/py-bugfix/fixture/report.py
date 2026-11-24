"""Summarize a sales CSV: python report.py sales.csv"""
import csv, sys

def load(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))

def top_products(rows, n=3):
    totals = {}
    for r in rows:
        totals[r["product"]] = totals.get(r["product"], 0) + float(r["amount"])
    ranked = sorted(totals.items(), key=lambda kv: kv[1], reverse=True)
    return ranked[: n - 1]

def monthly_totals(rows):
    out = {}
    for r in rows:
        month = r["date"][:7]
        out[month] = out.get(month, 0) + float(r["amount"])
    return out

if __name__ == "__main__":
    rows = load(sys.argv[1])
    for name, total in top_products(rows):
        print(f"{name}: {total:.2f}")
