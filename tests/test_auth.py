import pytest

import photos_share.server as server_mod
from photos_share.auth import COOKIE, MAX_FAILURES, Auth


@pytest.fixture(autouse=True)
def no_delay(monkeypatch):
    async def instant(_):
        return None
    monkeypatch.setattr(server_mod.asyncio, "sleep", instant)


@pytest.fixture
def locked(make_client):
    client, _ = make_client(auth=Auth("correct-horse", secure_cookie=False))
    return client


def login(client, password):
    return client.post("/login", data={"password": password}, follow_redirects=False)


@pytest.mark.parametrize("path", ["/api/libraries", "/static/app.js", "/thumb/x/y",
                                  "/photo/x/y", "/video/x/y", "/original/x/y"])
def test_everything_blocked_without_login(locked, path):
    assert locked.get(path).status_code == 401


def test_root_redirects_to_login(locked):
    r = locked.get("/", follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/login"
    assert "password" in locked.get("/login").text


def test_wrong_then_right_password(locked):
    assert login(locked, "nope").status_code == 401
    r = login(locked, "correct-horse")
    assert r.status_code == 303 and COOKIE in r.cookies
    cookie = r.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=lax" in cookie and "secure" not in cookie
    assert locked.get("/api/libraries").status_code == 200


def test_secure_cookie_for_public_links(make_client):
    client, _ = make_client(auth=Auth("correct-horse", secure_cookie=True))
    assert "secure" in login(client, "correct-horse").headers["set-cookie"].lower()


def test_lockout_after_repeated_failures(locked):
    for _ in range(MAX_FAILURES):
        assert login(locked, "guess").status_code == 401
    r = login(locked, "correct-horse")
    assert r.status_code == 429 and COOKIE not in r.cookies


def test_logout(locked):
    login(locked, "correct-horse")
    locked.get("/logout", follow_redirects=False)
    locked.cookies.clear()
    assert locked.get("/api/libraries").status_code == 401


def test_forged_cookie_rejected(locked):
    locked.cookies.set(COOKIE, "0" * 64)
    assert locked.get("/api/libraries").status_code == 401


def test_sessions_survive_restart_but_not_password_change():
    a, b = Auth("pw-one-123", False), Auth("pw-one-123", False)
    assert a.token == b.token                      # same key file + same password
    assert Auth("pw-two-456", False).token != a.token
    assert a.is_authed(a.token) and not a.is_authed(None) and not a.is_authed("")


def test_key_file_is_private(cache_root):
    Auth("pw-one-123", False)
    assert (cache_root / "auth.key").stat().st_mode & 0o777 == 0o600


def api_login(client, password):
    return client.post("/api/login", json={"password": password})


def test_app_login_gives_a_token_used_as_bearer(locked):
    assert api_login(locked, "nope").status_code == 401
    r = api_login(locked, "correct-horse")
    assert r.status_code == 200 and COOKIE not in r.cookies
    token = r.json()["token"]
    assert locked.get("/api/info").status_code == 401
    ok = locked.get("/api/info", headers={"Authorization": f"Bearer {token}"})
    assert ok.status_code == 200 and ok.json()["app"] == "photos-share"
    assert locked.get("/api/info", headers={"Authorization": "Bearer wrong"}).status_code == 401


def test_app_login_rejects_bad_bodies_and_locks_out(locked):
    assert locked.post("/api/login", content=b"not json").status_code == 401
    assert api_login(locked, 123).status_code == 401
    for _ in range(MAX_FAILURES - 2):   # the two bad bodies count too
        api_login(locked, "guess")
    assert api_login(locked, "correct-horse").status_code == 429


def test_token_stops_working_when_the_password_changes(make_client):
    old, _ = make_client(auth=Auth("correct-horse", secure_cookie=False))
    token = api_login(old, "correct-horse").json()["token"]
    new, _ = make_client(auth=Auth("battery-staple", secure_cookie=False))
    assert new.get("/api/info", headers={"Authorization": f"Bearer {token}"}).status_code == 401
