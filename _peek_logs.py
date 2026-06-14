import sqlite3, json
con = sqlite3.connect(r'C:\Users\J_lin\Desktop\JL_Engine-SB.Omni\data\sparkbyte_memory.db')
cur = con.cursor()

print("=" * 70)
print("TELEMETRY — last 8 events")
print("=" * 70)
cur.execute("SELECT name FROM pragma_table_info('telemetry')")
cols = [r[0] for r in cur.fetchall()]
print("COLS:", cols)
cur.execute("SELECT * FROM telemetry ORDER BY rowid DESC LIMIT 8")
rows = cur.fetchall()
for r in rows:
    rec = dict(zip(cols, r))
    ts = rec.get("ts") or rec.get("timestamp") or rec.get("created_at") or "?"
    ev = rec.get("event") or rec.get("type") or rec.get("event_type") or rec.get("name") or "?"
    extra = {k: v for k, v in rec.items() if k not in ("ts","timestamp","created_at","event","type","event_type","name")}
    print(f"[{ts}] {ev}")
    if extra:
        try:
            print("  ", json.dumps(extra, default=str)[:400])
        except Exception:
            print("  ", extra)

print()
print("=" * 70)
print("THOUGHTS — last 5 reasoning traces")
print("=" * 70)
cur.execute("SELECT name FROM pragma_table_info('thoughts')")
cols = [r[0] for r in cur.fetchall()]
print("COLS:", cols)
cur.execute("SELECT * FROM thoughts ORDER BY rowid DESC LIMIT 5")
for r in cur.fetchall():
    rec = dict(zip(cols, r))
    print(json.dumps(rec, default=str)[:600])
    print("-" * 40)

print()
print("=" * 70)
print("SESSIONS — last 3")
print("=" * 70)
cur.execute("SELECT name FROM pragma_table_info('sessions')")
cols = [r[0] for r in cur.fetchall()]
print("COLS:", cols)
cur.execute("SELECT * FROM sessions ORDER BY rowid DESC LIMIT 3")
for r in cur.fetchall():
    rec = dict(zip(cols, r))
    print(json.dumps(rec, default=str)[:500])
    print("-" * 40)

con.close()
