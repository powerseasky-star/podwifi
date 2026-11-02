# -*- coding: utf-8 -*-
"""核实 Sideloadly 产出的临时 ipa 是否为有效签名包（决定能否直接安装）"""
import hashlib
import os
import plistlib
import shutil
import zipfile

SRC = r"C:\Users\Administrator\AppData\Local\Temp\sideloadly-wu1qt5oh-PodWifi.ipa"
KEEP = r"C:\podipa\PodWifi_v0.2.0_signed_20261102.ipa"

print("源文件:", SRC)
print("大小  :", os.path.getsize(SRC), "B")
print("SHA256:", hashlib.sha256(open(SRC, "rb").read()).hexdigest())
print()

z = zipfile.ZipFile(SRC)
names = z.namelist()

app_dirs = sorted({n.split("/")[1] for n in names if n.startswith("Payload/") and "/" in n[8:]})
print("Payload 内的 .app:", app_dirs)

has_codesig = any("_CodeSignature/CodeResources" in n for n in names)
has_provision = any(n.endswith("embedded.mobileprovision") for n in names)
has_sc_info = any(n.endswith("SC_Info") or "/SC_Info/" in n for n in names)
print("  _CodeSignature/CodeResources :", has_codesig)
print("  embedded.mobileprovision     :", has_provision)
print("  SC_Info                      :", has_sc_info)
print()

app = app_dirs[0] if app_dirs else "PodWifi.app"
try:
    d = plistlib.loads(z.read("Payload/%s/Info.plist" % app))
    print("=== Info.plist ===")
    for k in (
        "CFBundleIdentifier",
        "CFBundleDisplayName",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "MinimumOSVersion",
        "CFBundleExecutable",
    ):
        if k in d:
            print("  %-28s %s" % (k, d[k]))
    print("  NSBluetoothAlwaysUsageDescription:", "有" if "NSBluetoothAlwaysUsageDescription" in d else "缺失")
    print("  NSLocalNetworkUsageDescription   :", "有" if "NSLocalNetworkUsageDescription" in d else "缺失")
except KeyError as e:
    print("Info.plist 缺失:", e)

print()
if has_provision:
    try:
        prov = z.read("Payload/%s/embedded.mobileprovision" % app)
        # 抽 XML 段（plist 被包在 CMS 签名里）
        s = prov.find(b"<?xml")
        e = prov.find(b"</plist>")
        if s >= 0 and e > s:
            p = plistlib.loads(prov[s:e + 8])
            print("=== 描述文件 ===")
            print("  Name        :", p.get("Name"))
            print("  TeamName    :", p.get("TeamName"))
            print("  AppIDName   :", p.get("AppIDName"))
            print("  ExpirationDate:", p.get("ExpirationDate"))
            ent = p.get("Entitlements", {})
            print("  application-identifier:", ent.get("application-identifier"))
            devs = p.get("ProvisionedDevices") or []
            print("  已授权设备数:", len(devs))
            if devs:
                print("  含本机 UDID :", "00008130-0014105610EB8D3A" in devs or any("14105610EB8D3A" in x for x in devs))
        else:
            print("描述文件为二进制/无法解析 XML 段")
    except Exception as ex:
        print("描述文件解析异常:", ex)

# 拷一份到稳定目录，避免 Temp 被清
shutil.copy2(SRC, KEEP)
print()
print("已备份到:", KEEP, os.path.getsize(KEEP), "B")
