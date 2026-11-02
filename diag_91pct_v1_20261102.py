# -*- coding: utf-8 -*-
"""诊断卡 91%：统计同一免费账号签名的 App 数量（3 个上限）+ 列出 PodWifi 状态"""
import json
import subprocess
import sys

PY = sys.executable


def run(args, timeout=180):
    try:
        p = subprocess.run([PY, "-X", "utf8", "-m", "pymobiledevice3"] + args,
                           capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"


rc, out, err = run(["apps", "list"])
if rc != 0:
    print("apps list 失败:", err[:400])
    raise SystemExit(1)

data = json.loads(out)
items = data.items() if isinstance(data, dict) else [(a.get("CFBundleIdentifier", "?"), a) for a in data]

sideloaded = []
free_acct = []
for ident, info in items:
    if not isinstance(info, dict):
        continue
    signer = str(info.get("SignerIdentity", ""))
    if "iPhone Developer" in signer or "Apple Development" in signer:
        sideloaded.append((ident, info.get("CFBundleShortVersionString"), signer))
    if "16403495" in signer or "VS958PDS5L" in ident:
        free_acct.append((ident, info.get("CFBundleShortVersionString"), signer))

print("=== 自签名（非 App Store）App 清单 ===")
for i, (ident, ver, signer) in enumerate(sideloaded, 1):
    print("  %d. %-45s %-10s %s" % (i, ident, ver, signer))
print("  合计:", len(sideloaded), "  ⚠️ 免费账号上限 3 个（满 3 个再装会失败/挂起）")
print()

print("=== 本账号（16403495@qq.com / Team VS958PDS5L）相关 ===")
for ident, ver, signer in free_acct:
    print("  %-45s %-10s %s" % (ident, ver, signer))
print("  合计:", len(free_acct))
print()

print("=== PodWifi 详情 ===")
for ident, info in items:
    if isinstance(info, dict) and "podwifi" in ident.lower():
        for k in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "ApplicationType", "SignerIdentity"):
            print("  %-28s %s" % (k, info.get(k)))
