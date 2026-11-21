#!/usr/bin/env python3
"""OmaShelf store.

The shelf holds references to files where they already live, like BuddyFiles
on macOS. Pasted images and text, and files dropped from a browser, have no
path of their own, so they are saved under the data directory and deleted
when they leave the shelf.

Every command prints the shelf as JSON, newest first.
"""

import hashlib
import json
import mimetypes
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request

DATA = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "omashelf")
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "omashelf")
MANIFEST = os.path.join(DATA, "shelf.json")
ITEMS = os.path.join(DATA, "items")
THUMBS = os.path.join(CACHE, "thumbs")

IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp", "image/avif", "image/tiff"]


def load():
    try:
        with open(MANIFEST) as f:
            value = json.load(f)
        return [p for p in value if isinstance(p, str)] if isinstance(value, list) else []
    except (OSError, ValueError):
        return []


def save(paths):
    os.makedirs(DATA, exist_ok=True)
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w") as f:
        json.dump(paths, f, indent=1)
    os.replace(tmp, MANIFEST)


def owned(path):
    return os.path.abspath(path).startswith(ITEMS + os.sep)


def unique_path(name):
    os.makedirs(ITEMS, exist_ok=True)
    name = os.path.basename(name).strip() or "File"
    base, ext = os.path.splitext(name)
    candidate = os.path.join(ITEMS, name)
    n = 2
    while os.path.exists(candidate):
        candidate = os.path.join(ITEMS, f"{base} {n}{ext}")
        n += 1
    return candidate


def stamp():
    return time.strftime("%Y-%m-%d %H.%M.%S")


def kind_of(path, mime):
    if os.path.isdir(path):
        return "folder"
    top = mime.split("/")[0]
    if top in ("image", "video", "audio"):
        return top
    if mime == "application/pdf":
        return "pdf"
    if top == "text" or mime in ("application/json", "application/xml", "application/javascript"):
        return "text"
    if any(word in mime for word in ("zip", "tar", "compressed", "x-7z", "rar", "gzip", "xz")):
        return "archive"
    return "file"


def mime_of(path):
    if os.path.isdir(path):
        return "inode/directory"
    mime, _ = mimetypes.guess_type(path)
    if mime:
        return mime
    try:
        out = subprocess.run(["file", "--brief", "--mime-type", path], capture_output=True, text=True, timeout=3)
        return out.stdout.strip() or "application/octet-stream"
    except (OSError, subprocess.SubprocessError):
        return "application/octet-stream"


def video_thumb(path, mtime):
    key = hashlib.sha1(f"{path}:{mtime}".encode()).hexdigest()
    thumb = os.path.join(THUMBS, key + ".png")
    if os.path.exists(thumb):
        return thumb
    os.makedirs(THUMBS, exist_ok=True)
    try:
        subprocess.run(["ffmpegthumbnailer", "-i", path, "-o", thumb, "-s", "256", "-q", "6"],
                       capture_output=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return ""
    return thumb if os.path.exists(thumb) else ""


def describe(path):
    exists = os.path.exists(path)
    entry = {"path": path, "name": os.path.basename(path.rstrip("/")) or path, "exists": exists,
             "owned": owned(path), "size": 0, "mime": "", "kind": "file", "thumb": ""}
    if not exists:
        return entry
    info = os.stat(path)
    mime = mime_of(path)
    entry["mime"] = mime
    entry["kind"] = kind_of(path, mime)
    entry["size"] = 0 if os.path.isdir(path) else info.st_size
    if entry["kind"] == "image":
        entry["thumb"] = path
    elif entry["kind"] == "video":
        entry["thumb"] = video_thumb(path, info.st_mtime)
    return entry


def print_shelf():
    print(json.dumps([describe(p) for p in load()]))


def download(url):
    parsed = urllib.parse.urlparse(url)
    name = urllib.parse.unquote(os.path.basename(parsed.path)) or "Download"
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        if "." not in name:
            ext = mimetypes.guess_extension(response.headers.get_content_type() or "") or ""
            name += ext
        target = unique_path(name)
        with open(target, "wb") as f:
            shutil.copyfileobj(response, f)
    return target


def resolve(value):
    """A dropped or pasted reference to a shelf path, or None."""
    value = value.strip()
    if not value or value.startswith("#"):
        return None
    if value.startswith("file://"):
        path = urllib.parse.unquote(urllib.parse.urlparse(value).path)
        return path if os.path.exists(path) else None
    if value.startswith(("http://", "https://")):
        return download(value)
    path = os.path.expanduser(value)
    return os.path.abspath(path) if os.path.isabs(path) and os.path.exists(path) else None


def add(values):
    paths = load()
    added = []
    for value in values:
        for line in value.replace("\r", "\n").split("\n"):
            path = resolve(line)
            if path and path not in added:
                added.append(path)
    if not added:
        raise SystemExit("Nothing to add.")
    save(added + [p for p in paths if p not in added])


def remove(targets):
    paths = load()
    for path in targets:
        if owned(path) and os.path.isfile(path):
            os.remove(path)
    save([p for p in paths if p not in targets])


def clear():
    remove(load())


def clipboard_types():
    try:
        out = subprocess.run(["wl-paste", "--list-types"], capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return []
    return [t.strip() for t in out.stdout.splitlines() if t.strip()]


def clipboard(mime):
    return subprocess.run(["wl-paste", "--no-newline", "--type", mime], capture_output=True, timeout=10).stdout


def paste():
    types = clipboard_types()
    if "text/uri-list" in types:
        add([clipboard("text/uri-list").decode(errors="replace")])
        return
    if "x-special/gnome-copied-files" in types:
        lines = clipboard("x-special/gnome-copied-files").decode(errors="replace").splitlines()
        add(lines[1:] if lines and lines[0] in ("copy", "cut") else lines)
        return
    image = next((t for t in IMAGE_TYPES if t in types), None)
    if image:
        ext = mimetypes.guess_extension(image) or ".png"
        target = unique_path(f"Pasted image {stamp()}{ext}")
        with open(target, "wb") as f:
            f.write(clipboard(image))
        add([target])
        return
    text_type = next((t for t in ("text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "TEXT") if t in types), None)
    if not text_type:
        raise SystemExit("Copy a file, image or text first.")
    text = clipboard(text_type).decode(errors="replace")
    # Copied paths become shelf references; any other text is saved as a file.
    lines = [l.strip() for l in text.strip().splitlines() if l.strip()]
    if lines and not any(l.startswith(("http://", "https://")) for l in lines) and all(resolve(l) for l in lines):
        add(lines)
        return
    target = unique_path(f"Pasted text {stamp()}.txt")
    with open(target, "w") as f:
        f.write(text)
    add([target])


def copy(paths):
    paths = [p for p in paths if os.path.exists(p)]
    if not paths:
        raise SystemExit("These files are no longer there.")
    if len(paths) == 1 and mime_of(paths[0]) in IMAGE_TYPES:
        # Chat apps and browsers paste image data, not file references.
        with open(paths[0], "rb") as f:
            subprocess.Popen(["wl-copy", "--type", mime_of(paths[0])], stdin=f, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    uris = "".join("file://" + urllib.parse.quote(p) + "\r\n" for p in paths)
    subprocess.Popen(["wl-copy", "--type", "text/uri-list", uris], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def detach(command):
    subprocess.Popen(command, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def open_paths(paths):
    for path in paths:
        if os.path.exists(path):
            detach(["xdg-open", path])


def reveal(paths):
    folders = []
    for path in paths:
        folder = path if os.path.isdir(path) else os.path.dirname(path)
        if os.path.isdir(folder) and folder not in folders:
            folders.append(folder)
    for folder in folders:
        detach(["xdg-open", folder])


def choose():
    """Ask the desktop's file chooser portal for files."""
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    token = f"omashelf{os.getpid()}"
    sender = bus.get_unique_name().lstrip(":").replace(".", "_")
    handle = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"
    loop = GLib.MainLoop()
    result = {"uris": []}

    def on_response(_conn, _sender, _path, _iface, _signal, params):
        code, results = params.unpack()
        if code == 0:
            result["uris"] = list(results.get("uris", []))
        loop.quit()

    bus.signal_subscribe("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response",
                         handle, None, Gio.DBusSignalFlags.NO_MATCH_RULE, on_response)
    options = {"handle_token": GLib.Variant("s", token), "multiple": GLib.Variant("b", True),
               "modal": GLib.Variant("b", False)}
    bus.call_sync("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                  "org.freedesktop.portal.FileChooser", "OpenFile",
                  GLib.Variant("(ssa{sv})", ("", "Add to shelf", options)),
                  None, Gio.DBusCallFlags.NONE, -1, None)
    loop.run()
    if result["uris"]:
        add(result["uris"])


def main():
    command, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("list", [])
    actions = {
        "list": lambda: None,
        "add": lambda: add(args),
        "remove": lambda: remove(args),
        "clear": clear,
        "paste": paste,
        "copy": lambda: copy(args),
        "open": lambda: open_paths(args),
        "reveal": lambda: reveal(args),
        "choose": choose,
    }
    if command not in actions:
        raise SystemExit(f"Unknown command: {command}")
    if not os.path.exists(MANIFEST):
        save([])  # The panel watches this file, so it has to exist.
    try:
        actions[command]()
    except SystemExit as error:
        print_shelf()
        if error.code not in (None, 0):
            print(error.code, file=sys.stderr)
            sys.exit(1)
        return
    except Exception as error:  # Report any failure to the panel instead of a trace.
        print_shelf()
        print(str(error) or error.__class__.__name__, file=sys.stderr)
        sys.exit(1)
    print_shelf()


if __name__ == "__main__":
    main()
