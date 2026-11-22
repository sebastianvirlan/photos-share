from __future__ import annotations

import asyncio
from pathlib import Path
from urllib.parse import parse_qs

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

from . import media
from .auth import COOKIE, COOKIE_DAYS, Auth, login_page
from .library import Asset, Collection, Library

STATIC = Path(__file__).parent / "static"
IMG_CACHE = {"Cache-Control": "private, max-age=604800"}


def create_app(col: Collection, video_mode: str, downloads: bool = False,
               auth: Auth | None = None) -> FastAPI:
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    converter = media.VideoConverter() if video_mode == "convert" else None

    def lookup(lib_id: str, uuid: str) -> tuple[Library, Asset]:
        lib = col.get(lib_id)
        if lib is None or lib.state != "ready":
            raise HTTPException(404)
        asset = lib.by_uuid.get(uuid)  # only visible assets; never a client-supplied path
        if asset is None:
            raise HTTPException(404)
        return lib, asset

    @app.get("/")
    def index():
        return FileResponse(STATIC / "index.html", headers={"Cache-Control": "no-cache"})

    app.mount("/static", StaticFiles(directory=STATIC), name="static")

    @app.middleware("http")
    async def revalidate_static(request, call_next):
        response = await call_next(request)
        if request.url.path.startswith("/static/"):
            response.headers["Cache-Control"] = "no-cache"  # pick up app updates on reload
        return response

    if auth is not None:
        @app.middleware("http")
        async def require_login(request: Request, call_next):
            # Registered last, so it runs first: nothing is served without a valid session.
            if request.url.path in ("/login", "/logout") or auth.is_authed(
                    request.cookies.get(COOKIE)):
                return await call_next(request)
            if request.url.path == "/":
                return RedirectResponse("/login", status_code=303)
            return JSONResponse({"error": "login required"}, status_code=401)

        @app.get("/login")
        def login_form():
            return HTMLResponse(login_page())

        @app.post("/login")
        async def login(request: Request):
            if auth.locked_out():
                return HTMLResponse(login_page("Too many attempts. Try again in a few minutes."),
                                    status_code=429)
            form = parse_qs((await request.body()).decode(errors="replace"))
            if not auth.check(form.get("password", [""])[0]):
                await asyncio.sleep(1)  # slow down guessing
                return HTMLResponse(login_page("Wrong password."), status_code=401)
            resp = RedirectResponse("/", status_code=303)
            resp.set_cookie(COOKIE, auth.token, max_age=COOKIE_DAYS * 86400, httponly=True,
                            samesite="lax", secure=auth.secure_cookie)
            return resp

        @app.get("/logout")
        def logout():
            resp = RedirectResponse("/login", status_code=303)
            resp.delete_cookie(COOKIE)
            return resp

    @app.get("/api/libraries")
    def libraries():
        out = []
        for lib in col.libraries.values():
            item = {"id": lib.id, "name": lib.name, "state": lib.state,
                    "available": lib.available}
            if lib.state == "ready" and lib.assets:
                item.update(count=len(lib.assets), cover=lib.assets[0].uuid,
                            first=lib.assets[-1].date, last=lib.assets[0].date)
            out.append(item)
        return out

    @app.get("/api/libraries/{lib_id}")
    def library(lib_id: str):
        lib = col.get(lib_id)
        if lib is None:
            raise HTTPException(404)
        if lib.state != "ready" and not lib.available:
            return JSONResponse({"state": "unavailable", "name": lib.name}, status_code=503)
        if lib.state != "ready":
            lib.ensure_open()
            code = 500 if lib.state == "error" else 202
            return JSONResponse({"state": lib.state, "error": lib.error, "name": lib.name},
                                status_code=code)
        return {
            "id": lib.id, "name": lib.name, "state": "ready",
            "available": lib.available, "downloads": downloads,
            "assets": [_asset_json(a) for a in lib.assets],
            "albums": [{"title": al["title"], "uuids": al["uuids"]} for al in lib.albums],
            "people": _people_json(lib),
        }

    @app.get("/thumb/{lib_id}/{uuid}")
    def thumb(lib_id: str, uuid: str):
        lib, asset = lookup(lib_id, uuid)
        path = media.thumbnail(lib, asset)
        if path is None:
            raise HTTPException(404)
        return FileResponse(path, media_type="image/jpeg", headers=IMG_CACHE)

    @app.get("/photo/{lib_id}/{uuid}")
    def photo(lib_id: str, uuid: str):
        lib, asset = lookup(lib_id, uuid)
        path = media.full_image(lib, asset)
        if path is None:
            raise HTTPException(404)
        return FileResponse(path, media_type="image/jpeg", headers=IMG_CACHE)

    @app.get("/video-status/{lib_id}/{uuid}")
    def video_status(lib_id: str, uuid: str):
        lib, asset = lookup(lib_id, uuid)
        if not asset.is_movie:
            raise HTTPException(404)
        if converter is None:
            return {"state": "ready" if media.video_source(lib, asset) else "error"}
        return {"state": converter.status(lib, asset)[0]}

    @app.get("/video/{lib_id}/{uuid}")
    def video(lib_id: str, uuid: str):
        lib, asset = lookup(lib_id, uuid)
        if not asset.is_movie:
            raise HTTPException(404)
        if converter is None:
            path = media.video_source(lib, asset)
        else:
            state, path = converter.status(lib, asset)
            if state == "preparing":
                return JSONResponse({"state": state}, status_code=202)
        if path is None:
            raise HTTPException(404)
        # Served as video/mp4 even for .mov: Safari and Chrome then play HEVC/H.264 alike.
        return FileResponse(path, media_type="video/mp4")

    @app.get("/live/{lib_id}/{uuid}")
    def live(lib_id: str, uuid: str):
        lib, asset = lookup(lib_id, uuid)
        path = lib.abs(asset.live)
        if path is None:
            raise HTTPException(404)
        return FileResponse(path, media_type="video/mp4", headers=IMG_CACHE)

    @app.get("/original/{lib_id}/{uuid}")
    def original(lib_id: str, uuid: str):
        if not downloads:
            raise HTTPException(404)
        lib, asset = lookup(lib_id, uuid)
        path = lib.abs(asset.original)
        if path is None:
            raise HTTPException(404)
        return FileResponse(path, filename=asset.filename or path.name)

    return app


def _asset_json(a: Asset) -> dict:
    """Compact per-asset payload; optional keys are omitted when empty."""
    out = {"u": a.uuid, "d": a.date, "w": a.width, "h": a.height,
           "m": a.is_movie, "l": bool(a.live), "e": bool(a.edited)}
    if a.favorite:
        out["f"] = True
    if a.kinds:
        out["k"] = a.kinds
    if a.is_screenshot:
        out["ss"] = True
    if a.lat is not None and a.lon is not None and (a.lat or a.lon):
        out["g"] = [round(a.lat, 5), round(a.lon, 5)]
    if a.place:
        out["pl"] = a.place
    if a.persons:
        out["p"] = list(a.persons)
    return out


def _people_json(lib: Library) -> list[dict]:
    counts = [0] * len(lib.people)
    for a in lib.assets:
        for i in a.persons:
            if i < len(counts):
                counts[i] += 1
    return [{"name": p["name"], "face": p["face"], "count": c}
            for p, c in zip(lib.people, counts)]
