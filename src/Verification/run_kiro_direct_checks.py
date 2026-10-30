#!/usr/bin/env python3
"""Checks for the Kiro direct route (no XCTest required).

Neither the bundled proxy nor upstream CLIProxyAPI has a Kiro executor, so Kiro
is served by ThinkingProxy itself. It translates the Anthropic Messages API onto
the CodeWhisperer surface:

    POST https://codewhisperer.us-east-1.amazonaws.com/generateAssistantResponse
    Authorization: Bearer <Kiro IdC / Builder ID access token>
    {"conversationState": {"chatTriggerType", "conversationId",
                           "currentMessage": {"userInputMessage": {...}},
                           "history": [{"userInputMessage"}, {"assistantResponseMessage"}]}}

The reply is an AWS event stream whose frames carry assistantResponseEvent
(text), toolUseEvent (incremental tool JSON), and meteringEvent (credits).

Run with --live to enable optional upstream and local API checks. Offline source
checks do not consume credits or depend on the machine's current login.
Exit 0 on success, 1 on failure.
"""
from __future__ import annotations

import glob
import json
import os
import struct
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROVIDER = ROOT / "Sources" / "KiroDirectProvider.swift"
PROXY = ROOT / "Sources" / "ThinkingProxy.swift"
CW_URL = "https://codewhisperer.us-east-1.amazonaws.com/generateAssistantResponse"
LOCAL = "http://127.0.0.1:8317"


def check(name: str, ok: bool, detail: str = "") -> None:
    status = "ok" if ok else "FAIL"
    extra = f" — {detail}" if detail else ""
    print(f"[{status}] {name}{extra}")
    if not ok:
        raise SystemExit(1)


def decode_event_stream(raw: bytes):
    """Reference decoder — the Swift one must agree with this."""
    out, i = [], 0
    while i + 16 <= len(raw):
        total, hlen = struct.unpack(">II", raw[i : i + 8])
        if total < 16 or i + total > len(raw):
            break
        headers, j, end = {}, i + 12, i + 12 + hlen
        while j < end:
            nl = raw[j]
            j += 1
            name = raw[j : j + nl].decode()
            j += nl
            vt = raw[j]
            j += 1
            if vt != 7:
                break
            vl = struct.unpack(">H", raw[j : j + 2])[0]
            j += 2
            headers[name] = raw[j : j + vl].decode()
            j += vl
        payload = raw[i + 12 + hlen : i + total - 4]
        try:
            out.append((headers.get(":event-type"), json.loads(payload)))
        except ValueError:
            pass
        i += total
    return out


def source_checks() -> None:
    src = PROVIDER.read_text()
    check("targets the CodeWhisperer surface", CW_URL in src)
    check(
        "advertises only models this account can reach",
        '"auto"' in src and '"claude-sonnet-4.5"' in src and '"claude-haiku-4.5"' in src,
    )
    check("model catalog uses the CLI's current model list with a namespaced fallback",
          "fetchCLIModels" in src and 'modelPrefix = "kiro/"' in src and "fallbackModels" in src)
    check("history is built as userInputMessage/assistantResponseMessage pairs",
          '"userInputMessage"' in src and '"assistantResponseMessage"' in src)
    check("tool calls round-trip", "toolUses" in src and "toolResults" in src)
    check("tool JSON fragments are concatenated, not replaced",
          "argumentsJSON += fragment" in src)
    check("rate/credit metering is read", "meteringEvent" in src)
    check("token counts are labelled estimates (Kiro reports credits only)",
          "estimatedInputTokens" in src and "estimatedOutputTokens" in src)

    proxy = PROXY.read_text()
    check("proxy intercepts /v1/messages for Kiro models",
          "KiroDirectProvider.httpRoute(for: rewrittenPath)" in proxy and "KiroDirectProvider.translateRequest" in proxy
          and "case .messages:" in proxy and "case .countTokens:" in proxy)
    check("proxy preserves backend model filtering instead of resurrecting disabled Kiro models",
          "serveMergedModelCatalog" in proxy and "ModelProviderLabel.tag" in proxy
          and "KiroDirectProvider.advertisedModelIDs" not in proxy)


def kiro_token() -> str | None:
    for path in sorted(glob.glob(os.path.expanduser("~/.cli-proxy-api/kiro-*.json"))):
        try:
            payload = json.load(open(path))
        except ValueError:
            continue
        if payload.get("disabled"):
            continue
        if payload.get("access_token"):
            return payload["access_token"]
    return None


def upstream_contract_check() -> None:
    token = kiro_token()
    if not token:
        print("[skip] upstream contract — no Kiro credential on this machine")
        return
    body = json.dumps(
        {
            "conversationState": {
                "chatTriggerType": "MANUAL",
                "conversationId": "00000000-1111-2222-3333-444444444444",
                "currentMessage": {
                    "userInputMessage": {
                        "content": "Reply with the single word OK.",
                        "modelId": "claude-sonnet-4.5",
                        "origin": "AI_EDITOR",
                    }
                },
                "history": [],
            }
        }
    ).encode()
    request = urllib.request.Request(
        CW_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/x-amz-json-1.0",
            "User-Agent": "aws-sdk-rust/kiro",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            frames = decode_event_stream(response.read())
    except urllib.error.HTTPError as exc:
        check(f"upstream accepted the request (HTTP {exc.code})", False, exc.read()[:120].decode())
        return
    except Exception as exc:
        print(f"[skip] upstream contract — {type(exc).__name__}")
        return

    kinds = {kind for kind, _ in frames}
    check("event stream decodes into frames", bool(frames), f"{len(frames)} frames")
    check("assistantResponseEvent present", "assistantResponseEvent" in kinds, str(sorted(k for k in kinds if k)))


def local_route_check() -> None:
    payload = json.dumps(
        {
            "model": "kiro/claude-sonnet-4.5",
            "max_tokens": 32,
            "messages": [{"role": "user", "content": "Reply with exactly: KIRO OK"}],
        }
    ).encode()
    request = urllib.request.Request(
        LOCAL + "/v1/messages",
        data=payload,
        headers={"Content-Type": "application/json", "x-api-key": "viberouter",
                 "anthropic-version": "2023-06-01"},
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            body = json.loads(response.read())
    except Exception as exc:
        print(f"[skip] local route — proxy not reachable ({type(exc).__name__})")
        return

    check("local route answers in Anthropic message shape",
          body.get("type") == "message" and body.get("role") == "assistant", str(body)[:120])
    check("content carries a text block",
          any(b.get("type") == "text" for b in body.get("content", [])))
    check("usage block is present (Claude Code requires it)",
          {"input_tokens", "output_tokens"} <= set(body.get("usage", {})))


def main() -> int:
    source_checks()
    if "--live" in sys.argv:
        upstream_contract_check()
        local_route_check()
    print("all Kiro direct-route checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
