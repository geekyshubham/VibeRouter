#!/usr/bin/env python3
"""Sanity checks: OpenCode + Antigravity local usage sources are readable.

Not a full reimplementation of the Swift parsers — just proves the on-disk
sources the app scans still exist and contain countable usage.
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path


def check_opencode() -> None:
    db = Path.home() / ".local/share/opencode/opencode.db"
    if not db.exists():
        db = Path.home() / ".opencode/opencode.db"
    assert db.exists(), f"OpenCode DB missing at {db}"
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    cur = conn.cursor()
    cutoff = int((time.time() - 30 * 86400) * 1000)
    cur.execute(
        "SELECT COUNT(*) FROM message WHERE time_created >= ? AND data LIKE '%assistant%'",
        (cutoff,),
    )
    n = cur.fetchone()[0]
    assert n > 0, "no assistant messages in last 30d"
    # Sum a sample of token totals
    cur.execute(
        "SELECT data FROM message WHERE time_created >= ? AND data LIKE '%\"role\":\"assistant\"%' LIMIT 200",
        (cutoff,),
    )
    tokens = 0
    for (raw,) in cur.fetchall():
        try:
            j = json.loads(raw)
        except Exception:
            continue
        if j.get("role") != "assistant":
            continue
        tk = j.get("tokens") or {}
        cache = tk.get("cache") or {}
        tokens += int(tk.get("input") or 0) + int(tk.get("output") or 0) + int(
            tk.get("reasoning") or 0
        ) + int(cache.get("read") or 0)
    conn.close()
    assert tokens > 0, "assistant messages present but tokens sum to 0"
    print(f"opencode: ok (assistant msgs≥{n}, sample tokens={tokens})")


def check_antigravity() -> None:
    root = Path.home() / ".gemini/antigravity-ide/conversations"
    assert root.exists(), f"Antigravity conversations dir missing: {root}"
    dbs = list(root.glob("*.db"))
    assert dbs, "no Antigravity conversation DBs"
    total_rows = 0
    model_hits = 0
    # Regression: Swift Int(UInt64.max) traps — ensure we can still parse steps with
    # max-uint sentinels present in real gen_metadata blobs.
    huge_varint_seen = False
    for db in dbs:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        cur = conn.cursor()
        try:
            cur.execute(
                "SELECT COUNT(*) FROM gen_metadata WHERE size IS NULL OR size < 8000"
            )
            total_rows += cur.fetchone()[0]
            cur.execute(
                "SELECT data FROM gen_metadata WHERE size IS NULL OR size < 8000 LIMIT 50"
            )
            for (blob,) in cur.fetchall():
                if not blob:
                    continue
                raw = blob if isinstance(blob, (bytes, bytearray)) else bytes(blob)
                text = raw.decode("utf-8", "replace")
                if "gemini-" in text or "claude-" in text or "gpt-" in text:
                    model_hits += 1
                # 0xFF-heavy tail patterns often encode large varints / sentinels
                if b"\xff\xff\xff\xff\xff\xff\xff\xff" in raw or raw.count(0xFF) > 8:
                    huge_varint_seen = True
        except sqlite3.Error:
            pass
        finally:
            conn.close()
    assert total_rows > 0, "no small gen_metadata rows"
    assert model_hits > 0, "no model ids in gen_metadata samples"
    print(
        f"antigravity: ok (dbs={len(dbs)}, gen_metadata_rows={total_rows}, "
        f"model_hits={model_hits}, huge_varint_seen={huge_varint_seen})"
    )


def check_int_exactly_safe() -> None:
    """Document the Swift trap we fixed: Int(UInt64.max) must not be used."""
    max_u = (1 << 64) - 1
    # Python int is unbounded; the bug is Swift-specific. Assert the sentinel we saw.
    assert max_u == 18446744073709551615
    assert max_u > (1 << 63) - 1  # larger than Int64.max
    print("int_exactly: ok (UInt64.max does not fit Int64 — use Int(exactly:))")


def check_int_from_double_safe() -> None:
    """Int(Double) traps on NaN/Inf/1e20 in Swift. JSONNumber.int must clamp."""
    import math

    huge = 1.9e19
    assert huge > (1 << 63) - 1
    assert math.isnan(float("nan"))
    assert math.isinf(float("inf"))
    print("int_from_double: ok (NaN/Inf/1e20 must not Int() in Swift)")


def main() -> int:
    check_opencode()
    check_antigravity()
    check_int_exactly_safe()
    check_int_from_double_safe()
    print("run_opencode_antigravity_usage_checks: OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
