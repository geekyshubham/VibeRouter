#!/usr/bin/env python3
"""Runnable checks for the quota-wake request shapes, no XCTest required.

Mirrors the production rules discovered against the live backends:
- Codex (chatgpt.com/backend-api/codex/responses) REQUIRES stream=true and a
  list-shaped `input`; registry-era slugs (gpt-5.4 / gpt-5.4-mini /
  codex-mini-latest) are rejected with HTTP 400.
- HTTP 429 (usage_limit_reached) still means the window was engaged — the wake
  parses `resets_in_seconds` into a human hint.
- Cloud Code (daily-cloudcode-pa.googleapis.com) accepts
  `v1internal:generateContent` with `model` + optional `project` + `request`.
- /v1/models wake discovery matches on `owned_by` because IDs alone miss
  provider-owned models (gpt-5.5 has no "codex" substring).

Exit 0 on success, 1 on failure.
"""
from __future__ import annotations

import json
import sys


def codex_body(model: str) -> dict:
    return {
        "model": model,
        "instructions": "",
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": [
                    {"type": "input_text", "text": "Reply with the single word OK."}
                ],
            }
        ],
        "store": False,
        "stream": True,
    }


def cloud_code_body(model: str, project: str | None) -> dict:
    body: dict = {
        "model": model,
        "request": {
            "contents": [
                {"role": "user", "parts": [{"text": "Reply with the single word OK."}]}
            ]
        },
    }
    if project:
        body["project"] = project
    return body


def codex_rate_limit_detail(body: dict) -> str:
    resets = body.get("resets_in_seconds")
    if isinstance(resets, (int, float)) and resets > 0:
        minutes = (int(resets) + 59) // 60
        if minutes >= 60:
            return f"window engaged but usage limit reached — resets in ~{(minutes + 30) // 60}h"
        return f"window engaged but usage limit reached — resets in ~{max(1, minutes)}m"
    return "window engaged but usage limit reached"


CODEX_WAKE_MODELS = ["gpt-5.5", "gpt-5.6-luna", "codex-auto-review"]
CLOUD_CODE_WAKE_MODELS = ["gemini-3-flash", "gemini-3.1-flash-lite"]

OWNED_BY = {
    "codex": ["openai"],
    "claude": ["anthropic"],
    "antigravity": ["antigravity"],
    "gemini": ["antigravity", "gemini"],
}


def owned_by_match(provider: str, model_entry: dict) -> bool:
    return model_entry.get("owned_by") in OWNED_BY.get(provider, [])


def main() -> int:
    failures: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        if ok:
            print(f"ok  {name}")
        else:
            failures.append(name)
            print(f"FAIL {name}" + (f": {detail}" if detail else ""))

    # Codex body shape: stream must be true, input must be a list.
    body = codex_body("gpt-5.5")
    check("codex body stream=true", body.get("stream") is True)
    check("codex body input is list", isinstance(body.get("input"), list))
    check(
        "codex input item is message with input_text",
        body["input"][0]["type"] == "message"
        and body["input"][0]["role"] == "user"
        and body["input"][0]["content"][0]["type"] == "input_text",
    )
    check("codex instructions present", "instructions" in body)
    check("codex store disabled", body.get("store") is False)

    # Only backend-accepted models in the wake list.
    rejected = {"gpt-5.4-mini", "gpt-5.4", "codex-mini-latest"}
    check(
        "codex wake models exclude registry-era slugs",
        not (set(CODEX_WAKE_MODELS) & rejected),
        str(CODEX_WAKE_MODELS),
    )

    # 429 handling: window engaged, human reset hint.
    exhausted = {
        "error": {
            "type": "usage_limit_reached",
            "resets_in_seconds": 6439,
            "plan_type": "team",
        }
    }
    detail = codex_rate_limit_detail(exhausted["error"])
    check("codex 429 engages window", "window engaged" in detail, detail)
    check("codex 429 reset hint in hours", "resets in ~2h" in detail, detail)
    near = codex_rate_limit_detail({"resets_in_seconds": 300})
    check("codex 429 reset hint in minutes", "resets in ~5m" in near, near)

    # Cloud Code body shape.
    cc = cloud_code_body("gemini-3-flash", "fifth-vigil-123")
    check("cloud code model set", cc["model"] == "gemini-3-flash")
    check("cloud code project set", cc.get("project") == "fifth-vigil-123")
    check(
        "cloud code request contents",
        cc["request"]["contents"][0]["parts"][0]["text"].startswith("Reply"),
    )
    cc_noproject = cloud_code_body("gemini-3-flash", None)
    check("cloud code omits empty project", "project" not in cc_noproject)

    # owned_by-based discovery.
    catalog = [
        {"id": "gpt-5.5", "owned_by": "openai"},
        {"id": "codex-auto-review", "owned_by": "openai"},
        {"id": "claude-sonnet-4-20250514", "owned_by": "anthropic"},
        {"id": "gemini-3-flash", "owned_by": "antigravity"},
        {"id": "grok-4.5", "owned_by": "xai"},
    ]
    check(
        "owned_by finds codex models without 'codex' in id",
        all(owned_by_match("codex", m) for m in catalog if m["owned_by"] == "openai"),
    )
    check(
        "owned_by does not leak other providers",
        not owned_by_match("codex", {"id": "claude-sonnet-4-20250514", "owned_by": "anthropic"}),
    )
    check(
        "antigravity owns gemini-served ids",
        owned_by_match("antigravity", {"id": "gemini-3-flash", "owned_by": "antigravity"}),
    )
    check(
        "gemini accepts antigravity-hosted models",
        owned_by_match("gemini", {"id": "gemini-3-flash", "owned_by": "antigravity"}),
    )

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
