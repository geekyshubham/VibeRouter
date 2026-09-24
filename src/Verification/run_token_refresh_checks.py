#!/usr/bin/env python3
"""Checks for Codex refresh-token rotation keep-alive (no XCTest required).

OpenAI rotates the refresh token on every success and invalidates the previous one.
Duplicate auth files sharing that token must refresh once and fan the new token out,
or the leftover file's next refresh sends refresh_token_reused and kills the family.

Also: unused accounts must be rotated before the ~30-day refresh-token wall.
Access tokens last 10 days; we refresh when iat is older than 7 days.

Exit 0 on success, 1 on failure.
"""
from __future__ import annotations

import base64
import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

GRACE = timedelta(minutes=15)
UNUSED_AGE = timedelta(days=7)


def check(name: str, ok: bool, detail: str = "") -> None:
    status = "ok" if ok else "FAIL"
    extra = f" — {detail}" if detail else ""
    print(f"[{status}] {name}{extra}")
    if not ok:
        raise SystemExit(1)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def jwt(*, iat: datetime, exp: datetime) -> str:
    header = b64url(b'{"alg":"none","typ":"JWT"}')
    payload = {
        "iat": int(iat.timestamp()),
        "exp": int(exp.timestamp()),
    }
    body = b64url(json.dumps(payload, separators=(",", ":")).encode())
    return f"{header}.{body}.sig"


def jwt_claim(token: str, key: str) -> datetime | None:
    parts = token.split(".")
    if len(parts) < 2:
        return None
    pad = parts[1] + "=" * (-len(parts[1]) % 4)
    raw = json.loads(base64.urlsafe_b64decode(pad))
    value = raw.get(key)
    if value is None:
        return None
    return datetime.fromtimestamp(int(value), tz=timezone.utc)


def flattened_auth(payload: dict) -> dict:
    out = dict(payload)
    tokens = payload.get("tokens")
    if isinstance(tokens, dict):
        for key, value in tokens.items():
            out.setdefault(key, value)
    return out


def should_refresh(payload: dict, now: datetime) -> bool:
    payload = flattened_auth(payload)
    rt = (payload.get("refresh_token") or "").strip()
    if not rt:
        return False
    token = payload.get("access_token") or ""
    exp = jwt_claim(token, "exp")
    if exp is not None:
        if exp <= now + GRACE:
            return True
        iat = jwt_claim(token, "iat")
        if iat is not None and iat + UNUSED_AGE <= now:
            return True
        return False
    return True


def grouped_by_refresh_token(jobs: list[tuple[str, str, str | None]]) -> list[list[str]]:
    """jobs: (file, type, refresh) -> groups of file names."""
    groups: dict[str, list[str]] = {}
    order: list[str] = []
    for file, typ, refresh in jobs:
        if refresh:
            key = f"{typ}\x1e{refresh}"
        else:
            key = f"{typ}\x1efile\x1e{file}"
        if key not in groups:
            order.append(key)
            groups[key] = []
        groups[key].append(file)
    return [groups[k] for k in order]


def should_adopt_codex_cli(local: dict, file: dict, now: datetime) -> bool:
    local = flattened_auth(local)
    file = flattened_auth(file)
    local_token = (local.get("access_token") or "").strip()
    if not local_token:
        return False
    file_token = (file.get("access_token") or "").strip() or None
    if file_token == local_token and (local.get("refresh_token") or "") == (file.get("refresh_token") or ""):
        return False
    local_email = (local.get("email") or "").strip()
    file_email = (file.get("email") or "").strip()
    if local_email and file_email and local_email.lower() != file_email.lower():
        return False
    local_id = (local.get("account_id") or "").strip()
    file_id = (file.get("account_id") or "").strip()
    if local_id and file_id and local_id.lower() != file_id.lower():
        return False
    local_exp = jwt_claim(local_token, "exp") or datetime.fromtimestamp(0, tz=timezone.utc)
    file_exp = jwt_claim(file_token or "", "exp") or datetime.fromtimestamp(0, tz=timezone.utc)
    if local_exp <= file_exp:
        return False
    if local_exp <= now and file_exp > now:
        return False
    return True


def copy_token_fields(updated: dict, original: dict) -> dict:
    out = dict(original)
    for key in (
        "access_token",
        "refresh_token",
        "id_token",
        "expires_in",
        "expired",
        "expires_at",
        "last_refresh",
        "account_id",
        "plan_type",
    ):
        if key in updated:
            out[key] = updated[key]
    return out


def propagate(old_refresh: str, updated: dict, directory: Path, skipping: set[str] | None = None) -> int:
    skipped = skipping or set()
    wrote = 0
    for path in directory.glob("*.json"):
        if path.name in skipped:
            continue
        payload = json.loads(path.read_text())
        if (payload.get("refresh_token") or "").strip() != old_refresh:
            continue
        path.write_text(json.dumps(copy_token_fields(updated, payload)))
        wrote += 1
    return wrote


def main() -> None:
    now = datetime.now(timezone.utc)

    groups = grouped_by_refresh_token(
        [
            ("codex-a.json", "codex", "rt.1.shared"),
            ("codex-seat.json", "codex", "rt.1.shared"),
            ("codex-other.json", "codex", "rt.1.other"),
        ]
    )
    check("duplicate refresh tokens collapse to one group", len(groups) == 2, str(groups))
    sizes = sorted(len(g) for g in groups)
    check("shared group has both sibling files", sizes == [1, 2], str(groups))

    fresh = {
        "refresh_token": "rt.1.alive",
        "access_token": jwt(iat=now - timedelta(hours=2), exp=now + timedelta(days=9)),
    }
    check("fresh access token is left alone", not should_refresh(fresh, now))

    stale = {
        "refresh_token": "rt.1.alive",
        "access_token": jwt(iat=now - timedelta(days=8), exp=now + timedelta(days=2)),
    }
    check("8-day-old unused session is rotated before 30d wall", should_refresh(stale, now))

    near = {
        "refresh_token": "rt.1.alive",
        "access_token": jwt(iat=now - timedelta(days=9), exp=now + timedelta(minutes=5)),
    }
    check("near-expiry access token still refreshes", should_refresh(near, now))

    nested = {
        "tokens": {
            "refresh_token": "rt.1.alive",
            "access_token": jwt(iat=now - timedelta(days=8), exp=now + timedelta(days=2)),
        }
    }
    check("nested tokens.refresh_token still refreshes", should_refresh(nested, now))

    def session_expiry(payload: dict) -> bool:
        flat = flattened_auth(payload)
        return not bool((flat.get("refresh_token") or "").strip())

    check(
        "refreshable session is not expired when RT JWT exp is past",
        not session_expiry(
            {
                "refresh_token": jwt(iat=now - timedelta(days=20), exp=now - timedelta(minutes=1)),
                "access_token": jwt(iat=now - timedelta(hours=2), exp=now + timedelta(days=8)),
            }
        ),
    )

    live = jwt(iat=now - timedelta(minutes=1), exp=now + timedelta(hours=1))
    dead = jwt(iat=now - timedelta(hours=2), exp=now - timedelta(minutes=1))
    older = jwt(iat=now - timedelta(hours=2), exp=now + timedelta(minutes=10))
    check(
        "fresher matching CLI token is adopted",
        should_adopt_codex_cli(
            {"email": "a@x.com", "access_token": live, "refresh_token": "rt-new", "account_id": "acct-1"},
            {"email": "a@x.com", "access_token": dead, "refresh_token": "rt-old", "account_id": "acct-1"},
            now,
        ),
    )
    check(
        "older CLI token is not adopted over a live file",
        not should_adopt_codex_cli(
            {"email": "a@x.com", "access_token": older, "refresh_token": "rt-old"},
            {"email": "a@x.com", "access_token": live, "refresh_token": "rt-new"},
            now,
        ),
    )
    check(
        "same tokens are a no-op",
        not should_adopt_codex_cli(
            {"email": "a@x.com", "access_token": live, "refresh_token": "rt"},
            {"email": "a@x.com", "access_token": live, "refresh_token": "rt"},
            now,
        ),
    )

    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        (d / "codex-a.json").write_text(
            json.dumps({"type": "codex", "email": "a@x.com", "refresh_token": "rt-old", "access_token": "old"})
        )
        (d / "codex-seat.json").write_text(
            json.dumps({"type": "codex", "email": "a@x.com", "refresh_token": "rt-old", "access_token": "old"})
        )
        (d / "codex-other.json").write_text(
            json.dumps({"type": "codex", "email": "b@x.com", "refresh_token": "rt-other", "access_token": "old"})
        )
        n = propagate("rt-old", {"refresh_token": "rt-new", "access_token": "new"}, d)
        check("propagate writes both siblings", n == 2, str(n))
        a = json.loads((d / "codex-a.json").read_text())
        seat = json.loads((d / "codex-seat.json").read_text())
        other = json.loads((d / "codex-other.json").read_text())
        check("sibling A got new refresh token", a["refresh_token"] == "rt-new")
        check("sibling seat got new refresh token", seat["refresh_token"] == "rt-new")
        check("sibling email preserved", a["email"] == "a@x.com")
        check("unrelated file not touched", other["refresh_token"] == "rt-other")

    def should_network_refresh_claude(payload: dict, native: dict | None) -> bool:
        if not native:
            return True
        local_email = (native.get("email") or "").strip()
        file_email = (payload.get("email") or "").strip()
        if local_email and file_email and local_email.lower() != file_email.lower():
            return True
        if not (native.get("access_token") or native.get("refresh_token")):
            return True
        return False

    check(
        "native Claude Code session blocks proxy refresh",
        not should_network_refresh_claude(
            {"email": "a@x.com", "refresh_token": "rt-file"},
            {"email": "a@x.com", "access_token": "cli-at", "refresh_token": "rt-cli"},
        ),
    )
    check(
        "different Claude account can still refresh",
        should_network_refresh_claude(
            {"email": "other@x.com", "refresh_token": "rt-file"},
            {"email": "a@x.com", "access_token": "cli-at"},
        ),
    )
    check(
        "no native session still refreshes Claude",
        should_network_refresh_claude({"email": "a@x.com", "refresh_token": "rt-file"}, None),
    )

    scope = "openid email profile offline_access"
    check("openai refresh keeps offline_access", "offline_access" in scope)

    print("all token-refresh checks passed")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
