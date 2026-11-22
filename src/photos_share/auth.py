"""Optional password protection: one shared password, a signed cookie, brute-force lockout."""

from __future__ import annotations

import hashlib
import hmac
import html
import os
import secrets
import threading
import time
from collections import deque

from .library import CACHE_ROOT

COOKIE = "ps_session"
COOKIE_DAYS = 30
MAX_FAILURES = 10        # failed logins allowed per window, across all clients
FAILURE_WINDOW = 600     # seconds


class Auth:
    def __init__(self, password: str, secure_cookie: bool):
        self._password = password.encode()
        self.secure_cookie = secure_cookie
        # The session value is derived from a persistent random key + the password, so
        # sessions survive restarts and are all invalidated by changing the password.
        self._token = hmac.new(_load_key(), self._password, hashlib.sha256).hexdigest()
        self._failures: deque[float] = deque()
        self._lock = threading.Lock()

    def is_authed(self, cookie: str | None) -> bool:
        return bool(cookie) and hmac.compare_digest(cookie, self._token)

    def locked_out(self) -> bool:
        with self._lock:
            cutoff = time.monotonic() - FAILURE_WINDOW
            while self._failures and self._failures[0] < cutoff:
                self._failures.popleft()
            return len(self._failures) >= MAX_FAILURES

    def check(self, password: str) -> bool:
        ok = hmac.compare_digest(password.encode(), self._password)
        if not ok:
            with self._lock:
                self._failures.append(time.monotonic())
        return ok

    @property
    def token(self) -> str:
        return self._token


def _load_key() -> bytes:
    path = CACHE_ROOT / "auth.key"
    try:
        key = path.read_bytes()
        if len(key) == 32:
            return key
    except FileNotFoundError:
        pass
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    key = secrets.token_bytes(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(key)
    return key


def login_page(error: str = "") -> str:
    err = f'<p class="err">{html.escape(error)}</p>' if error else ""
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Photos</title>
<style>
  :root {{ color-scheme: light dark; --bg:#f5f5f7; --card:#fff; --fg:#1d1d1f; --muted:#86868b;
          --line:rgba(0,0,0,.12); --accent:#0071e3; }}
  @media (prefers-color-scheme: dark) {{ :root {{ --bg:#1e1e1e; --card:#2c2c2e; --fg:#f5f5f7;
          --muted:#98989d; --line:rgba(255,255,255,.14); --accent:#0a84ff; }} }}
  body {{ margin:0; min-height:100vh; display:grid; place-items:center; background:var(--bg);
         color:var(--fg); font:15px -apple-system, BlinkMacSystemFont, sans-serif; padding:16px;
         box-sizing:border-box; }}
  form {{ width:100%; max-width:320px; background:var(--card); padding:28px 24px; border-radius:16px;
         box-shadow:0 8px 30px rgba(0,0,0,.08); text-align:center; }}
  h1 {{ margin:0 0 6px; font-size:22px; }}
  p {{ margin:0 0 18px; color:var(--muted); font-size:13px; }}
  input {{ width:100%; box-sizing:border-box; padding:11px 12px; font:inherit; color:inherit;
          border:1px solid var(--line); border-radius:10px; background:transparent; }}
  button {{ width:100%; margin-top:12px; padding:11px; font:inherit; font-weight:600; color:#fff;
           background:var(--accent); border:0; border-radius:10px; cursor:pointer; }}
  .err {{ color:#ff453a; margin:12px 0 0; }}
</style></head>
<body><form method="post" action="/login">
  <h1>Photos</h1><p>Enter the password to view these photos.</p>
  <input type="password" name="password" autocomplete="current-password" autofocus required
         aria-label="Password">
  <button type="submit">View photos</button>{err}
</form></body></html>"""
