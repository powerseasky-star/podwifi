# -*- coding: utf-8 -*-
"""查设备上 PodWifi 的真实安装状态（用于判断 Sideloadly 是否半装/卡住）"""
import json
import subprocess
import sys

PY = sys.executable
MAP = {
    "CFBundleIdentifier": "bundle",
    "CFBundleShortVersionString": "ver",
    "CFBundleVersion": "build",
    "ApplicationType": "type",
    "SignerIdentity": "signer",
}

cmd = [PY, "-X", "utf8", "-m", "pymobiledevice3", "apps", "list"]
try:
    out = subprocess.run(cmd, capture_output=True, timeout=180)
except subprocess.TimeoutExpired:
    print("apps list 超时（设备可能忙或锁屏拒绝服务）")
    raise SystemExit(1)

txt = out.stdout.decode("utf-8", "replace")
if out.returncode != 0:
    print("命令失败 rc=", out.returncode)
    print(out.stderr.decode("utf-8", "replace")[:800])
    raise SystemExit(1)

try:
    data = json.loads(txt)
except Exception as e:
    print("JSON 解析失败:", e)
    print(txt[:600])
    raise SystemExit(1)

apps = {}
if isinstance(data, dict):
    apps = data
elif isinstance(data, list):
    for a in data:
        ident = a.get("CFBundleIdentifier") or a.get("Identifier") or "?"
        apps[ident] = a

print("设备上共", len(apps), "个条目")
print()
hits = {k: v for k, v in apps.items() if isinstance(v, dict) and "podwifi" in json.dumps(v, ensure_ascii=False).lower()}
print("=== 含 podwifi 的条目 ===")
if not hits:
    print("  （无）→ 说明 PodWifi 当前不在设备上，安装没有落地")
for k, v in hits.items():
    print("  key:", k)
    for kk, label in MAP.items():
        if kk in v:
            print("    %-10s %s" % (label, v[kk]))
    for extra in ("Path", "CFBundleDisplayName", "IsAppClip", "Entitlements"):
        if extra in v:
            s = str(v[extra])
            print("    %-10s %s" % (extra, s[:160]))
    print()
