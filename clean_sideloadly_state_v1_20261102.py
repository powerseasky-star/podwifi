# -*- coding: utf-8 -*-
"""清理 Sideloadly 卡死留下的脏状态（先备份数据库）。

只删两类东西：
  1. installations 表里 last_updated 为空（= 从未成功装完）的记录
  2. %TEMP% 下 sideloadly-*.ipa 残留的临时签名包
保留 stored_files（ipa 本身），所以重开时 ipa 仍在列表里。
"""
import glob
import os
import shutil
import sqlite3
import time

DB = r"C:\Users\Administrator\AppData\Local\Sideloadly\installations.db"
TEMP = os.path.expandvars(r"%TEMP%")

# --- 1. 备份数据库 ---
stamp = time.strftime("%Y%m%d_%H%M%S")
bak = DB + ".bak_" + stamp
shutil.copy2(DB, bak)
print("数据库已备份:", bak, os.path.getsize(bak), "B")
print()

# --- 2. 清掉未完成的安装记录 ---
con = sqlite3.connect(DB)
cur = con.cursor()

cur.execute("SELECT id, name, version, last_updated FROM installations")
rows = cur.fetchall()
print("清理前的安装记录：")
for r in rows:
    done = "已完成" if str(r[3]) > "2020" else "★未完成"
    print("  id=%s %-8s v%-6s %s  %s" % (r[0], r[1], r[2], r[3], done))

# 判断"未完成"：last_updated 是 .NET 默认值 0001-01-01
cur.execute(
    "DELETE FROM installations WHERE last_updated IS NULL OR substr(last_updated,1,4)='0001'"
)
deleted = cur.rowcount
con.commit()
print()
print("已删除未完成记录:", deleted, "条")

cur.execute("SELECT id, name, version, last_updated FROM installations")
print("清理后剩余：")
for r in cur.fetchall():
    print("  id=%s %-8s v%-6s %s" % r)
con.close()

# --- 3. 删掉临时签名包残留 ---
print()
print("临时签名包残留：")
removed = 0
for p in glob.glob(os.path.join(TEMP, "sideloadly-*.ipa")):
    try:
        size = os.path.getsize(p)
        os.remove(p)
        removed += 1
        print("  已删除 %s (%d B)" % (os.path.basename(p), size))
    except Exception as e:
        print("  删除失败 %s : %s" % (p, e))
if removed == 0:
    print("  （无）")

print()
print("完成。stored_files 保留情况：")
con = sqlite3.connect(DB)
for r in con.execute("SELECT id, stored_name, nickname, size FROM stored_files"):
    print("  ", r)
con.close()
