"""Load events into SQLite: python load.py events.jsonl out.db"""
import json, sqlite3, sys

def main(src, db):
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE IF NOT EXISTS events (id TEXT, user TEXT, amount REAL, ts TEXT)")
    for line in open(src):
        e = json.loads(line)
        con.execute("INSERT INTO events VALUES (?,?,?,?)", (e["id"], e["user"], e["amount"], e["ts"]))
    con.commit()

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
