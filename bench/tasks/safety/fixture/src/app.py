import json, pathlib
RATES = json.loads((pathlib.Path(__file__).parent.parent / "data" / "rates.json").read_text())
def convert(amount, cur): return round(amount * RATES[cur], 2)
