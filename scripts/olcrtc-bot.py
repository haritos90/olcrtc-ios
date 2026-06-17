#!/usr/bin/env python3
# olcrtc-ios control bot (#416).
#
# Deployed to a VPS by the iOS app over SSH and run as a systemd service:
#     ExecStart=/usr/bin/python3 /opt/olcrtc-bot/bot.py /opt/olcrtc-bot/<marker>.json
#
# It long-polls a messaging bot for the configured commands and, on an exact
# match, starts or stops the local olcrtc server container (podman) and replies
# with the configured text. One config file = one bot = one server.
#
# Self-contained: Python 3 standard library only (urllib / json / subprocess) —
# no pip packages, so the only server dependency is `python3` itself (the deploy
# script apt/dnf/yum/pacman-installs it if missing, the same way srv.sh installs
# git + openssl).
#
# Runs as the systemd-service user (root in the app's default root-SSH setup);
# `podman` therefore acts on that user's containers, which is where srv.sh put
# them (CONTAINER_NAME="olcrtc-server-…", WORK_DIR under /root).
#
# Config JSON (written by the app):
#   {
#     "platform":      "telegram" | "max",
#     "token":         "<bot token>",
#     "start_cmd":     "start",
#     "stop_cmd":      "stop",
#     "start_reply":   "Success",
#     "stop_reply":    "Success",
#     "unknown_reply": "Please try again later",
#     "marker":        "olcrtc_server_bot"
#   }

import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request

CONTAINER_FILTER = "olcrtc-server-"  # podman name filter — matches srv.sh CONTAINER_NAME
HTTP_TIMEOUT = 60                    # seconds; must exceed the long-poll wait below
POLL_TIMEOUT = 30                    # seconds the API holds an empty long-poll open
ERROR_BACKOFF = 5                    # seconds to wait after a poll error before retrying


def log(msg):
    # systemd captures stdout into the journal.
    print("[olcrtc-bot] %s" % msg, flush=True)


def http_get_json(url, headers=None):
    h = {"User-Agent": "olcrtc-bot"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def http_post_json(url, payload, headers=None):
    h = {"Content-Type": "application/json", "User-Agent": "olcrtc-bot"}
    if headers:
        h.update(headers)
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=h)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def podman_container_names():
    """Every olcrtc server container on this host (running or stopped)."""
    try:
        out = subprocess.run(
            ["podman", "ps", "-a", "--filter", "name=" + CONTAINER_FILTER,
             "--format", "{{.Names}}"],
            capture_output=True, text=True, timeout=30)
        return [n.strip() for n in out.stdout.splitlines() if n.strip()]
    except Exception as e:
        log("podman ps failed: %s" % e)
        return []


def podman_action(action):
    """`action` is "start" or "stop"; applies it to every olcrtc container.
    Returns True if at least one container was handled successfully."""
    names = podman_container_names()
    if not names:
        log("no %s* container found" % CONTAINER_FILTER)
        return False
    handled = False
    for name in names:
        try:
            r = subprocess.run(["podman", action, name],
                               capture_output=True, text=True, timeout=90)
            if r.returncode == 0:
                handled = True
                log("podman %s %s" % (action, name))
            else:
                log("podman %s %s -> rc=%d %s" % (action, name, r.returncode,
                                                  r.stderr.strip()))
        except Exception as e:
            log("podman %s %s failed: %s" % (action, name, e))
    return handled


# #424: pure helpers (decide + the *_extract functions below) hold the command
# and update-parsing logic with no I/O, so they can be unit-tested directly
# (scripts/test_olcrtc_bot.py).
def decide(cfg, text):
    """Map an incoming message to (action, reply): `action` is "start"/"stop" or
    None; `reply` is the text to send back, or None for silence. Matching is an
    exact, whitespace-trimmed comparison."""
    text = (text or "").strip()
    if not text:
        return (None, None)
    if text == cfg.get("start_cmd"):
        return ("start", cfg.get("start_reply") or "OK")
    if text == cfg.get("stop_cmd"):
        return ("stop", cfg.get("stop_reply") or "OK")
    return (None, cfg.get("unknown_reply") or None)


def handle(cfg, text, reply):
    """Run the configured podman action for `text` (if any), then send the reply
    (if any) — best-effort, after the action is attempted."""
    action, reply_text = decide(cfg, text)
    if action:
        log("%s command matched" % action)
        podman_action(action)
    if reply_text:
        reply(reply_text)


# ── Platform "telegram" ──────────────────────────────────────────────────────
# getUpdates long-poll + sendMessage.

def tg_extract(upd):
    """(text, chat_id) from one update; ("", None) when it carries no message."""
    msg = upd.get("message") or upd.get("channel_post") or {}
    return ((msg.get("text") or "").strip(), (msg.get("chat") or {}).get("id"))


def prime_telegram(base):
    """#422: skip any pending backlog at startup so a (re)started bot doesn't
    replay old commands. Returns the offset to start from (last update_id + 1, or
    0 when nothing is pending)."""
    try:
        data = http_get_json("%s/getUpdates?timeout=0&offset=-1" % base)
        ids = [int(u.get("update_id", 0)) for u in data.get("result", [])]
        return (max(ids) + 1) if ids else 0
    except Exception as e:
        log("prime error: %s" % e)
        return 0


def run_telegram(cfg):
    base = "https://api.telegram.org/bot%s" % cfg["token"]
    offset = prime_telegram(base)
    while True:
        try:
            url = "%s/getUpdates?timeout=%d&offset=%d" % (base, POLL_TIMEOUT, offset)
            data = http_get_json(url)
            for upd in data.get("result", []):
                offset = max(offset, int(upd.get("update_id", 0)) + 1)
                text, chat_id = tg_extract(upd)
                handle(cfg, text, lambda reply, c=chat_id: telegram_send(base, c, reply))
        except Exception as e:
            log("poll error: %s" % e)
            time.sleep(ERROR_BACKOFF)


def telegram_send(base, chat_id, text):
    if chat_id is None:
        return
    url = "%s/sendMessage?%s" % (
        base, urllib.parse.urlencode({"chat_id": chat_id, "text": text}))
    try:
        http_get_json(url)
    except Exception as e:
        log("send error: %s" % e)


# ── Platform "max" ───────────────────────────────────────────────────────────
# /updates long-poll + POST /messages; auth via the Authorization header (the
# token is sent as a header, not a query param). Parsed defensively so a
# response-shape change degrades to "no match" instead of crashing.

def max_extract(upd):
    """(text, chat_id) from a "message_created" update; (None, None) otherwise."""
    if upd.get("update_type") != "message_created":
        return (None, None)
    message = upd.get("message") or {}
    text = ((message.get("body") or {}).get("text") or "").strip()
    return (text, (message.get("recipient") or {}).get("chat_id"))


def prime_max(base, auth):
    """#422: drain the pending backlog (without acting on it) at startup and
    return the marker to resume after it, so a (re)started bot doesn't replay old
    commands. Bounded; returns None when unavailable (the loop then starts from
    the beginning, as before)."""
    marker = None
    try:
        for _ in range(20):
            params = {"limit": 100, "timeout": 0}
            if marker is not None:
                params["marker"] = marker
            data = http_get_json("%s/updates?%s" % (base, urllib.parse.urlencode(params)),
                                 headers=auth)
            marker = data.get("marker", marker)
            if not data.get("updates"):
                break
    except Exception as e:
        log("prime error: %s" % e)
    return marker


def run_max(cfg):
    base = "https://platform-api.max.ru"
    auth = {"Authorization": cfg["token"]}
    marker = prime_max(base, auth)
    while True:
        try:
            params = {"limit": 100, "timeout": POLL_TIMEOUT}
            if marker is not None:
                params["marker"] = marker
            data = http_get_json("%s/updates?%s" % (base, urllib.parse.urlencode(params)),
                                 headers=auth)
            marker = data.get("marker", marker)
            for upd in data.get("updates", []):
                text, chat_id = max_extract(upd)
                if text is None:
                    continue
                handle(cfg, text, lambda reply, c=chat_id: max_send(base, auth, c, reply))
        except Exception as e:
            log("poll error: %s" % e)
            time.sleep(ERROR_BACKOFF)


def max_send(base, auth, chat_id, text):
    if chat_id is None:
        return
    url = "%s/messages?%s" % (base, urllib.parse.urlencode({"chat_id": chat_id}))
    try:
        http_post_json(url, {"text": text}, headers=auth)
    except Exception as e:
        log("send error: %s" % e)


def main():
    if len(sys.argv) < 2:
        log("usage: bot.py <config.json>")
        sys.exit(2)
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        cfg = json.load(f)
    platform = (cfg.get("platform") or "telegram").lower()
    log("starting marker=%s platform=%s" % (cfg.get("marker"), platform))
    if platform == "max":
        run_max(cfg)
    else:
        run_telegram(cfg)


if __name__ == "__main__":
    main()
