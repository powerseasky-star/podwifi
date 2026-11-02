# -*- coding: utf-8 -*-
"""只读 dump Sideloadly installations.db，定位卡在 Installing 的原因"""
import datetime
import sqlite3

DB = r"C:\Users\Administrator\AppData\Local\Sideloadly\installations.db"

con = sqlite3.connect(DB)
con.row_factory = sqlite3.Row
cur = con.cursor()

cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
tabs = [r[0] for r in cur.fetchall()]
print("表:", tabs)

for t in tabs:
    print()
    print("=== " + t + " ===")
    cur.execute('PRAGMA table_info("%s")' % t)
    cols = [r[1] for r in cur.fetchall()]
    print("  列:", cols)
    cur.execute('SELECT * FROM "%s"' % t)
    for row in cur.fetchall():
        d = dict(row)
        print("  ---")
        for k, v in d.items():
            if v in (None, "", b""):
                continue
            s = str(v)
            if len(s) > 200:
                s = s[:200] + " ..."
            print("    %-18s %s" % (k, s))

con.close()
print()
print("现在时间:", datetime.datetime.now().strftime("%H:%M:%S"))
