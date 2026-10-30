#!/usr/bin/env python3
"""Checks for the OpenCode Go quota card (no XCTest required).

OpenCode Zen exposes the Go subscription's three windows at
`GET https://opencode.ai/zen/go/v1/usage` with `Authorization: Bearer <api key>`:

    {"usage": {"rolling":  {"status": "ok",           "percent": 0,  "resetsAt": "..."},
               "weekly":   {"status": "ok",           "percent": 19, "resetsAt": "..."},
               "monthly":  {"status": "rate-limited", "percent": 9,  "resetsAt": "..."}}}

The card maps rolling→5h, weekly→7d, monthly→30d, and treats `rate-limited` as
100% used because `percent` lags behind the actual block.

Run with --live to enable the optional contract check using a local OpenCode key.
Exit 0 on success, 1 on failure.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FETCHER = ROOT / "Sources" / "NativeUsageFetcher.swift"
AUTH_STATUS = ROOT / "Sources" / "AuthStatus.swift"
USAGE_URL = "https://opencode.ai/zen/go/v1/usage"
USER_AGENT = "VibeRouter/1.0"


def check(name: str, ok: bool, detail: str = "") -> None:
    status = "ok" if ok else "FAIL"
    extra = f" — {detail}" if detail else ""
    print(f"[{status}] {name}{extra}")
    if not ok:
        raise SystemExit(1)


def source_checks() -> None:
    src = FETCHER.read_text()

    check("usage endpoint is the Go-scoped one", USAGE_URL in src)
    check(
        "custom User-Agent set (opencode.ai Cloudflare 1010-blocks defaults)",
        'forHTTPHeaderField: "User-Agent"' in src and USER_AGENT in src,
    )

    buckets = re.search(
        r'\("rolling", "5-hour", (\d+)\),\s*\("weekly", "Weekly", ([\d_]+)\),\s*\("monthly", "Monthly", ([\d_]+)\),',
        src,
    )
    check("three windows declared in rolling/weekly/monthly order", buckets is not None)
    minutes = [int(g.replace("_", "")) for g in buckets.groups()]
    check("window durations are 5h / 7d / 30d", minutes == [300, 10080, 43200], str(minutes))

    check(
        "rate-limited status forces 100% used",
        'status == "rate-limited" ? 100 : clampPercent(reported)' in src,
    )
    check("401 reports a rejected key", "API key rejected" in src)
    check("403 reports a missing Go entitlement", "no active OpenCode Go subscription" in src)

    auth = AUTH_STATUS.read_text()
    check(
        "opencode-go auth files map to the ServiceType",
        "case opencodeGo" in auth and "case ProviderCatalog.openCodeGoProviderName: return .opencodeGo" in auth,
    )


def local_api_keys() -> list[str]:
    keys: list[str] = []
    auth_json = Path.home() / ".local/share/opencode/auth.json"
    if auth_json.exists():
        try:
            data = json.loads(auth_json.read_text())
        except ValueError:
            data = {}
        for provider, entry in data.items():
            if provider in {"opencode", "opencode-go"} and isinstance(entry, dict) and entry.get("type") == "api" and entry.get("key"):
                keys.append(entry["key"])
    for auth_file in (Path.home() / ".cli-proxy-api").glob("*.json"):
        try:
            entry = json.loads(auth_file.read_text())
        except (OSError, ValueError):
            continue
        if entry.get("type") == "openai-compat" and entry.get("provider") == "opencode-go" and entry.get("api_key"):
            keys.append(entry["api_key"])
    return keys


def live_contract_check() -> None:
    keys = local_api_keys()
    if not keys:
        print("[skip] live contract check — no local OpenCode key found")
        return

    last_error = ""
    for key in keys:
        request = urllib.request.Request(
            USAGE_URL,
            headers={
                "Authorization": f"Bearer {key}",
                "Accept": "application/json",
                "User-Agent": USER_AGENT,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                payload = json.loads(response.read().decode())
        except urllib.error.HTTPError as exc:
            last_error = f"HTTP {exc.code}"
            continue
        except Exception as exc:  # network unavailable / DNS / TLS
            print(f"[skip] live contract check — {type(exc).__name__}")
            return

        usage = payload.get("usage")
        check("live response has a usage object", isinstance(usage, dict))
        for bucket in ("rolling", "weekly", "monthly"):
            entry = usage.get(bucket)
            check(f"live response has {bucket}", isinstance(entry, dict))
            check(
                f"{bucket} carries status/percent/resetsAt",
                {"status", "percent", "resetsAt"} <= set(entry),
                str(sorted(entry)),
            )
            check(
                f"{bucket} status is a known value",
                entry["status"] in {"ok", "rate-limited"},
                entry["status"],
            )
        return

    print(f"[skip] live contract check — no key was accepted ({last_error})")


def main() -> int:
    source_checks()
    if "--live" in sys.argv:
        live_contract_check()
    print("all OpenCode Go limits checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
