import report
def test_monthly():
    rows = report.load("sales.csv")
    assert report.monthly_totals(rows)["2026-01"] == 35.5
