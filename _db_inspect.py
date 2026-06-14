import sqlite3
DB = r"C:\Users\J_lin\Desktop\JL_Engine-SB.Omni\data\sparkbyte_memory.db"
con = sqlite3.connect(DB)
cur = con.cursor()

print("=== TABLES ===")
for (n,) in cur.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
    cnt = cur.execute(f"SELECT COUNT(*) FROM \"{n}\"").fetchone()[0]
    print(f"  • {n:30s}  rows={cnt}")

print("\n=== INDEXES ===")
for n, sql in cur.execute("SELECT name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name"):
    print(f"  • {n}")
    print(f"      {sql}")

print("\n=== ROW COUNTS PER TABLE (key ones) ===")
for t in ["memory", "telemetry", "thoughts", "behavior_states", "agents", "tools", "knowledge"]:
    try:
        n = cur.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        print(f"  {t:25s} = {n}")
    except Exception as e:
        print(f"  {t:25s} = (missing: {e})")
