#!/usr/bin/env python3
"""
QRScanner 云端构建助手（纯 API 版）

本机直连 github.com 会超时，但 api.github.com 可访问，所以这里全部走 REST API：
建仓库 → 上传源码 → 触发 GitHub Actions 构建未签名 IPA → 下载 artifact。

用法：
    export GITHUB_TOKEN=ghp_xxx          # 需要 repo + workflow 权限（经典 PAT 勾选这两项）
    python3 gh_build_ipa.py              # 默认仓库名 QRScanner
    python3 gh_build_ipa.py --repo MyQR  # 自定义仓库名

可选环境变量：
    GITHUB_OWNER  仓库所属账号，默认用 token 对应的用户
    PRIVATE=1     创建私有仓库（默认公开，公开仓库 Actions 不计分钟数）
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"
ROOT = Path(__file__).resolve().parent
SKIP_DIRS = {".git", "build", "DerivedData"}
SKIP_SUFFIX = {".ipa", ".xcarchive", ".xcuserstate"}


def token() -> str:
    tok = os.environ.get("GITHUB_TOKEN", "").strip()
    if not tok:
        sys.exit("❌ 请先设置 GITHUB_TOKEN 环境变量（需 repo + workflow 权限）")
    return tok


def call(method: str, path: str, tok: str, body=None, raw=False):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {tok}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = resp.read()
            return resp.status, (payload if raw else json.loads(payload or b"null"))
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except urllib.error.URLError as e:
        sys.exit(f"❌ 网络错误: {e}")


def collect_files():
    files = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix in SKIP_SUFFIX:
                continue
            if name == ".DS_Store":
                continue
            files.append(p)
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="QRScanner")
    ap.add_argument("--branch", default="main")
    args = ap.parse_args()

    tok = token()
    code, me = call("GET", "/user", tok)
    if code != 200:
        sys.exit(f"❌ token 无效或权限不足: {me}")
    owner = os.environ.get("GITHUB_OWNER") or me["login"]
    repo = args.repo
    private = os.environ.get("PRIVATE", "0") == "1"

    print(f"👤 账号: {owner}    📦 仓库: {owner}/{repo}    {'私有' if private else '公开'}")

    # 1) 建仓库
    code, resp = call("POST", "/user/repos", tok, {
        "name": repo,
        "private": private,
        "auto_init": False,
        "description": "QRScanner - SwiftUI 扫码/拍照水印 App",
    })
    if code == 201:
        print("✅ 仓库已创建")
    elif code == 422:
        print("ℹ️ 仓库已存在，继续覆盖更新文件")
    else:
        sys.exit(f"❌ 建仓失败 {code}: {resp}")

    # 2) 上传文件（每个文件一次提交）
    files = collect_files()
    print(f"📤 待上传 {len(files)} 个文件")
    for i, f in enumerate(files, 1):
        rel = f.relative_to(ROOT).as_posix()
        content = base64.b64encode(f.read_bytes()).decode()
        # 文件已存在时必须带上 sha，否则 API 返回 422（重复运行也能覆盖更新）
        sha = None
        code, existing = call("GET", f"/repos/{owner}/{repo}/contents/{rel}?ref={args.branch}", tok)
        if code == 200 and isinstance(existing, dict):
            sha = existing.get("sha")
        body = {
            "message": f"{'update' if sha else 'add'} {rel}",
            "content": content,
            "branch": args.branch,
        }
        if sha:
            body["sha"] = sha
        code, resp = call("PUT", f"/repos/{owner}/{repo}/contents/{rel}", tok, body)
        if code not in (200, 201):
            if rel.startswith(".github/workflows"):
                sys.exit(f"❌ 上传 workflow 失败 {code}: {resp}\n"
                         f"   多半是 token 缺少 workflow 权限，重新生成 PAT 时请勾选。")
            sys.exit(f"❌ 上传 {rel} 失败 {code}: {resp}")
        print(f"   [{i}/{len(files)}] {rel}")

    # 3) 触发 Actions
    code, resp = call("POST", f"/repos/{owner}/{repo}/actions/workflows/build-ipa.yml/dispatches",
                      tok, {"ref": args.branch})
    if code not in (204, 201):
        sys.exit(f"❌ 触发构建失败 {code}: {resp}\n"
                 f"   检查 .github/workflows/build-ipa.yml 是否已上传，以及 token 是否有 workflow 权限。")
    print("🚀 已触发构建，等待 macOS runner…")

    # 4) 轮询运行状态
    time.sleep(8)
    run_id, status, conclusion = None, None, None
    for _ in range(60):  # 最多等 10 分钟
        code, runs = call("GET", f"/repos/{owner}/{repo}/actions/runs?per_page=5", tok)
        if code != 200:
            sys.exit(f"❌ 查询运行失败 {code}: {runs}")
        for r in runs.get("workflow_runs", []):
            if r.get("name") == "Build unsigned IPA" or "build-ipa" in (r.get("path") or ""):
                run_id, status, conclusion = r["id"], r["status"], r["conclusion"]
                break
        if status == "completed":
            break
        print(f"   … 状态: {status}")
        time.sleep(15)
    else:
        sys.exit("❌ 超时：10 分钟内构建未结束，请到 Actions 页面查看日志")

    if conclusion != "success":
        sys.exit(f"❌ 构建失败（{conclusion}），请打开 https://github.com/{owner}/{repo}/actions 查看日志")

    # 5) 下载 artifact
    code, arts = call("GET", f"/repos/{owner}/{repo}/actions/artifacts?per_page=20", tok)
    target = None
    for a in arts.get("artifacts", []):
        if a["name"] == "QRScanner-unsigned-ipa" and not a.get("expired"):
            target = a
            break
    if not target:
        sys.exit("❌ 未找到 artifact，可能刚生成还没同步，稍等重跑或去页面手动下载")

    out_zip = ROOT / "build" / "QRScanner-unsigned-ipa.zip"
    out_zip.parent.mkdir(parents=True, exist_ok=True)
    code, blob = call("GET", target["archive_download_url"], tok, raw=True)
    if code != 200:
        sys.exit(f"❌ 下载 artifact 失败 {code}: {blob}")
    out_zip.write_bytes(blob)
    print(f"✅ 已下载: {out_zip}")

    # 6) 解压
    import zipfile
    ipa_dir = ROOT / "build" / "ipa-unsigned"
    ipa_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_zip) as z:
        z.extractall(ipa_dir)
    ipas = list(ipa_dir.rglob("*.ipa"))
    if ipas:
        print(f"🎉 IPA 就绪: {ipas[0]}")
        print("   下一步：用 Sideloadly / AltStore 以 Apple ID 自签安装")
    else:
        print("⚠️ 解压后没找到 .ipa，检查 Actions 日志")


if __name__ == "__main__":
    main()
