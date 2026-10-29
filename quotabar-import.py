#!/usr/bin/env python3
"""把 ClaudeBar 已登录的 claude.ai 账号（含 sessionKey cookie）导入 QuotaBar。

ClaudeBar 把每个账号的网页登录态存在独立的 WebKit 数据目录里，
目录 UUID 记录在它的偏好 webUsageProfileIdentifiersJSON 中。
仅在 QuotaBar 主动迁移时通过私有管道输出，由主程序保存到钥匙串。
不直接写入账号配置文件。
"""
from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
REGISTRY = HOME / "Library/Application Support/claude-swap-widget/registry.json"
WEBKIT = HOME / "Library/WebKit/dev.ncthanhngo.claude-bar/WebsiteDataStore"
OUT = HOME / ".config/quotabar/accounts.json"
PREF_DOMAIN = "dev.ncthanhngo.claude-bar"


def read_pages(data: bytes) -> list[bytes]:
    if data[:4] != b"cook":
        raise ValueError("不是 binarycookies 文件")
    count = struct.unpack(">i", data[4:8])[0]
    sizes = [struct.unpack(">i", data[8 + 4 * i:12 + 4 * i])[0] for i in range(count)]
    offset = 8 + 4 * count
    pages = []
    for size in sizes:
        pages.append(data[offset:offset + size])
        offset += size
    return pages


def parse_page(page: bytes) -> list[dict]:
    cookies: list[dict] = []
    if page[:4] != b"\x00\x00\x01\x00":
        return cookies
    count = struct.unpack("<i", page[4:8])[0]
    offsets = [struct.unpack("<i", page[8 + 4 * i:12 + 4 * i])[0] for i in range(count)]
    for start in offsets:
        blob = page[start:]

        def cstr(base: int) -> str:
            end = blob.index(b"\x00", base)
            return blob[base:end].decode("utf-8", "replace")

        url_off = struct.unpack("<i", blob[16:20])[0]
        name_off = struct.unpack("<i", blob[20:24])[0]
        path_off = struct.unpack("<i", blob[24:28])[0]
        value_off = struct.unpack("<i", blob[28:32])[0]
        cookies.append({
            "domain": cstr(url_off),
            "path": cstr(path_off),
            "name": cstr(name_off),
            "value": cstr(value_off),
        })
    return cookies


def load_cookies(path: Path) -> list[dict]:
    out: list[dict] = []
    for page in read_pages(path.read_bytes()):
        out.extend(parse_page(page))
    return out


def profile_map() -> dict[str, str]:
    try:
        raw = subprocess.run(
            ["defaults", "read", PREF_DOMAIN, "webUsageProfileIdentifiersJSON"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        mapping = json.loads(raw)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return {}
    return {k: v.lower() for k, v in mapping.items()}


def export_accounts() -> list[dict]:
    registry = json.loads(REGISTRY.read_text())
    profiles = profile_map()
    accounts = []
    for number, account in sorted(registry.get("accounts", {}).items(), key=lambda kv: int(kv[0])):
        email = account.get("email", "")
        org = account.get("organizationUuid", "")
        key = ""
        uuid = profiles.get(f"{email}|{org}")
        if uuid:
            cookie_file = WEBKIT / uuid / "Cookies/Cookies.binarycookies"
            try:
                cookies = {c["name"]: c["value"] for c in load_cookies(cookie_file)
                           if c["domain"].lower() in ("claude.ai", ".claude.ai")}
                key = cookies.get("sessionKey", "")
            except (OSError, ValueError, struct.error, IndexError):
                pass
        accounts.append({"name": account.get("nickname") or email.split("@")[0],
                         "email": email, "org": org, "sessionKey": key})
    return accounts


def main() -> int:
    # QuotaBar reads this through a private pipe, then stores secrets in Keychain.
    # Never print cookies to a terminal or write them to accounts.json.
    if sys.argv[1:] != ["--export"] or sys.stdout.isatty():
        print("请在 QuotaBar 内点击‘从 ClaudeBar 导入’。", file=sys.stderr)
        return 2
    try:
        accounts = export_accounts()
        if not accounts:
            return 1
        print(json.dumps({"accounts": accounts}, ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError):
        print("无法读取 ClaudeBar 账号资料", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
