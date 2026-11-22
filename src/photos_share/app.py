"""Menu bar app: choose a library or folder, pick who can see it, start/stop sharing."""

from __future__ import annotations

import json
import logging
import subprocess
import webbrowser
from pathlib import Path

import rumps
from AppKit import (NSApp, NSApplication, NSApplicationActivationPolicyAccessory, NSImage,
                    NSOpenPanel, NSPasteboard, NSPasteboardTypeString)

from .share import MIN_FUNNEL_PASSWORD, Share, ShareConfig, ShareError

SETTINGS = Path.home() / "Library" / "Application Support" / "photos-share" / "settings.json"
KEYCHAIN_SERVICE = "photos-share"
MODE_LABELS = {"local": "This Mac only", "tailscale": "Tailscale (private, viewers need the app)",
               "funnel": "Public link with password (Tailscale Funnel)"}
DEFAULTS = {"path": None, "mode": "tailscale", "screenshots": False, "downloads": False,
            "convert_video": False, "require_password": False, "port": 8080}

log = logging.getLogger("photos_share")


class PhotosShareApp(rumps.App):
    def __init__(self):
        super().__init__("Photos Share", title="▣", quit_button=None)
        self.settings = {**DEFAULTS, **_load_settings()}
        self.share: Share | None = None

        self.status = rumps.MenuItem("Not sharing")
        self.source = rumps.MenuItem("")
        self.mode_items = {m: rumps.MenuItem(label, callback=self.set_mode)
                           for m, label in MODE_LABELS.items()}
        self.opt_items = {
            "screenshots": rumps.MenuItem("Show screenshots", callback=self.toggle),
            "downloads": rumps.MenuItem("Allow downloading originals", callback=self.toggle),
            "convert_video": rumps.MenuItem("Convert videos for any browser", callback=self.toggle),
            "require_password": rumps.MenuItem("Require password", callback=self.toggle),
        }
        self.start_stop = rumps.MenuItem("Start Sharing", callback=self.start_or_stop)
        self.copy_item = rumps.MenuItem("Copy Link", callback=self.copy_link)
        self.open_item = rumps.MenuItem("Open in Browser", callback=self.open_link)

        access = rumps.MenuItem("Who can see it")
        for item in self.mode_items.values():
            access.add(item)
        options = rumps.MenuItem("Options")
        for item in self.opt_items.values():
            options.add(item)
        self.menu = [
            self.status, self.source,
            rumps.MenuItem("Choose Library or Folder…", callback=self.choose),
            None, access, options,
            rumps.MenuItem("Set Password…", callback=self.ask_password),
            None, self.start_stop, self.copy_item, self.open_item,
            None, rumps.MenuItem("Quit Photos Share", callback=self.quit),
        ]
        self.refresh()

    # ---- UI state ----------------------------------------------------------

    def refresh(self) -> None:
        s, sharing = self.settings, self.share is not None
        path = Path(s["path"]) if s["path"] else None
        self.source.title = f"Source: {path.name}" if path else "No library chosen"
        for m, item in self.mode_items.items():
            item.state = int(s["mode"] == m)
            item.set_callback(None if sharing else self.set_mode)
        for k, item in self.opt_items.items():
            item.state = int(bool(s[k]) or (k == "require_password" and s["mode"] == "funnel"))
            item.set_callback(None if sharing else self.toggle)
        self.status.title = f"Sharing: {self.share.url}" if sharing else "Not sharing"
        self.start_stop.title = "Stop Sharing" if sharing else "Start Sharing"
        self.start_stop.set_callback(self.start_or_stop if (path or sharing) else None)
        self.copy_item.set_callback(self.copy_link if sharing else None)
        self.open_item.set_callback(self.open_link if sharing else None)
        if getattr(self, "_icon_ok", False):
            self.title = "●" if sharing else ""
        else:
            self.title = "▣ ●" if sharing else "▣"

    def save(self) -> None:
        SETTINGS.parent.mkdir(parents=True, exist_ok=True)
        SETTINGS.write_text(json.dumps(self.settings, indent=2))
        self.refresh()

    # ---- menu actions ------------------------------------------------------

    def choose(self, _):
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseDirectories_(True)
        panel.setCanChooseFiles_(True)
        panel.setAllowsMultipleSelection_(False)
        panel.setMessage_("Choose a Photos library, or a folder that contains several.")
        panel.setPrompt_("Share")
        NSApp.activateIgnoringOtherApps_(True)
        if panel.runModal() != 1:
            return
        path = Path(panel.URLs()[0].path())
        if path.suffix != ".photoslibrary" and not any(path.glob("*.photoslibrary")):
            rumps.alert("Not a Photos library",
                        f"“{path.name}” isn’t a .photoslibrary and doesn’t contain any.")
            return
        was_sharing = self.share is not None
        self.stop_sharing()
        self.settings["path"] = str(path)
        self.save()
        if was_sharing:
            self.start_sharing()

    def set_mode(self, sender):
        self.settings["mode"] = next(m for m, i in self.mode_items.items() if i is sender)
        self.save()

    def toggle(self, sender):
        key = next(k for k, i in self.opt_items.items() if i is sender)
        if key == "require_password" and self.settings["mode"] == "funnel":
            rumps.alert("Password required", "A public link always needs a password.")
            return
        self.settings[key] = not self.settings[key]
        self.save()

    def ask_password(self, _=None) -> bool:
        NSApp.activateIgnoringOtherApps_(True)
        r = rumps.Window("Viewers enter this once per device. Changing it signs everyone out.",
                         "Password for viewers", ok="Save", cancel="Cancel",
                         dimensions=(260, 24), secure=True).run()
        if not r.clicked:
            return False
        if len(r.text) < MIN_FUNNEL_PASSWORD:
            rumps.alert("Password too short",
                        f"Use at least {MIN_FUNNEL_PASSWORD} characters.")
            return False
        _keychain_set(r.text)
        if self.share:  # apply immediately
            self.stop_sharing()
            self.start_sharing()
        return True

    def start_or_stop(self, _):
        if self.share:
            self.stop_sharing()
        else:
            self.start_sharing()

    def start_sharing(self) -> None:
        s = self.settings
        password = None
        if s["require_password"] or s["mode"] == "funnel":
            password = _keychain_get()
            if not password:
                if not self.ask_password():
                    return
                password = _keychain_get()
        cfg = ShareConfig(path=Path(s["path"]), screenshots=s["screenshots"],
                          video="convert" if s["convert_video"] else "original",
                          downloads=s["downloads"], password=password, mode=s["mode"],
                          port=s["port"])
        try:
            share = Share(cfg)
            share.start_background()
        except ShareError as e:
            rumps.alert("Couldn’t start sharing", str(e))
            return
        self.share = share
        self.refresh()
        self.copy_link(None)
        rumps.alert("Sharing started", f"{share.url}\n\nThe link has been copied.")

    def stop_sharing(self) -> None:
        if self.share:
            self.share.stop()
            self.share = None
        self.refresh()

    def copy_link(self, _):
        if self.share:
            pb = NSPasteboard.generalPasteboard()
            pb.clearContents()
            pb.setString_forType_(self.share.url, NSPasteboardTypeString)

    def open_link(self, _):
        if self.share:
            webbrowser.open(self.share.url)

    def quit(self, _):
        self.stop_sharing()
        rumps.quit_application()


# ---- persistence -------------------------------------------------------------

def _load_settings() -> dict:
    try:
        return json.loads(SETTINGS.read_text())
    except (FileNotFoundError, ValueError):
        return {}


def _keychain_get() -> str | None:
    r = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
                        "-a", "viewers", "-w"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return r.stdout.rstrip("\n") or None


def _keychain_set(password: str) -> None:
    subprocess.run(["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE,
                    "-a", "viewers", "-w", password], capture_output=True, check=True)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    logging.getLogger("osxphotos").setLevel(logging.ERROR)
    NSApplication.sharedApplication().setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    app = PhotosShareApp()

    @rumps.timer(0.1)
    def _set_icon(timer):  # swap the text title for an SF Symbol once the status item exists
        timer.stop()
        img = NSImage.imageWithSystemSymbolName_accessibilityDescription_(
            "photo.on.rectangle", "Photos Share")
        item = getattr(app, "_nsapp", None) and getattr(app._nsapp, "nsstatusitem", None)
        if img is not None and item is not None:
            img.setTemplate_(True)
            item.button().setImage_(img)
            app._icon_ok = True
            app.refresh()

    app.run()
