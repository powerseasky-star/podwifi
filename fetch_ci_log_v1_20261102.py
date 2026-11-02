# -*- coding: utf-8 -*-
"""抓取最近一次 GitHub Actions 运行日志并提取报错行。

用法: python fetch_ci_log_v1_20261102.py [run_id]
不给 run_id 就取最新一次。
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

OWNER = "powerseasky-star"
REPO = "podwifi"
TOK = os.environ.get("GH_TOK", "")

ERR = re.compile(r"(error:|fatal error|undefined symbol|ld: |clang: error|No such file|"
                 r"not found for|linker command failed|❌|::error::)", re.I)


def api(url, raw=False):
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + TOK,
        "Accept": "application/vnd.github+json",
        "User-Agent": "pod-ci-log",
    })
    with urllib.request.urlopen(req, timeout=90) as r:
        data = r.read()
    return data if raw else json.loads(data)


def fetch_log(jid):
    """日志接口会 302 到签名地址；urllib 会把 Authorization 带过去导致 401，
    所以改用 curl（实测可用）。"""
    url = "https://api.github.com/repos/%s/%s/actions/jobs/%s/logs" % (OWNER, REPO, jid)
    p = subprocess.run(["curl", "-sL", "-H", "Authorization: Bearer " + TOK,
                        "-H", "Accept: application/vnd.github+json", url],
                       capture_output=True, timeout=120)
    return p.stdout.decode("utf-8", "replace")


def main():
    if not TOK:
        print("缺少环境变量 GH_TOK")
        return 2
    run_id = sys.argv[1] if len(sys.argv) > 1 else None
    if run_id is None:
        runs = api("https://api.github.com/repos/%s/%s/actions/runs?per_page=1" % (OWNER, REPO))
        run_id = runs["workflow_runs"][0]["id"]
    print("run_id =", run_id)

    jobs = api("https://api.github.com/repos/%s/%s/actions/runs/%s/jobs" % (OWNER, REPO, run_id))
    for job in jobs.get("jobs", []):
        jid = job["id"]
        print("job:", job.get("name"), job.get("conclusion"), jid)
        log = fetch_log(jid)
        if not log.strip():
            print("  日志为空")
            continue
        # 去掉时间戳前缀便于阅读
        lines = [re.sub(r"^\S+Z ", "", ln) for ln in log.splitlines()]
        hits = [ln for ln in lines if ERR.search(ln)]
        print("  报错行数:", len(hits))
        seen = set()
        printed = 0
        for ln in hits:
            key = ln.strip()[:120]
            if key in seen or "::error::" in ln and "echo" in ln:
                continue
            seen.add(key)
            print("   ", ln.strip()[:300])
            printed += 1
            if printed >= 30:
                print("   ...（更多略）")
                break
        if printed == 0:
            print("   未匹配到错误行，最后 20 行：")
            for ln in lines[-20:]:
                if ln.strip():
                    print("   ", ln.strip()[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main())
