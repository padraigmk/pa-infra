#!/usr/bin/env python3
"""cal-hub: the host's own status page and approval desk.

Runs as root on the host, outside the cal container, so it keeps working when
Cal is down and Cal cannot answer for itself. Stdlib only.

    GET  /               status page: containers, session, scheduled jobs,
                         disk and memory, pending reboot, allowlist requests
    GET  /status.json    the same, as data
    POST /allowlist      approve or deny the pending allowlist request

Reached only through `tailscale serve` (it binds to loopback). Who is asking
comes from the Tailscale-User-Login header, which tailscale serve sets itself
and strips from incoming requests; anyone but the owner is refused. POSTs also
need the page's own Origin and a token from the page, because a web page open
on the phone could otherwise post here across sites using the phone's place on
the tailnet.

Config: /etc/cal-hub.conf (KEY=value): OWNER (tailnet login), HUB_URL.
"""

import hmac
import html
import json
import os
import re
import secrets
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

CONF = Path(os.environ.get("CAL_HUB_CONF", "/etc/cal-hub.conf"))
PENDING = Path(os.environ.get("CAL_HUB_PENDING", "/var/lib/cal-hub/allowlist-pending.json"))
APPLY = os.environ.get("CAL_HUB_APPLY", "/root/pa-infra/host/allowlist-apply.sh")
ALLOWLIST_LOG = Path("/var/log/cal-allowlist.log")
PORT = int(os.environ.get("CAL_HUB_PORT", "8770"))
CSRF = secrets.token_urlsafe(24)  # per start; the page carries it in its forms


def conf() -> dict[str, str]:
    out = {}
    try:
        for line in CONF.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip("\"'")
    except OSError:
        pass
    return out


def run(cmd: list[str], timeout: int = 20) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except (subprocess.SubprocessError, OSError) as e:
        return 1, f"{type(e).__name__}: {e}"


# --- what is checked ---------------------------------------------------------
# Each check returns (state, summary, detail): state is ok | warn | bad.


def check_containers():
    rows, state = [], "ok"
    for name in ("cal", "calproxy"):
        rc, out = run(["docker", "inspect", "-f", "{{.State.Status}} since {{.State.StartedAt}}", name])
        if rc != 0 or not out.startswith("running"):
            state = "bad"
            rows.append(f"{name}: {out.splitlines()[-1] if out else 'not found'}")
        else:
            rows.append(f"{name}: running since {out.split('since ')[1][:16].replace('T', ' ')} UTC")
    return state, "Containers", "\n".join(rows)


def check_session():
    rc, procs = run(["docker", "exec", "cal", "pgrep", "-c", "-x", "claude"])
    if rc != 0:
        return "bad", "Cal's session", "No claude process is running in the container."
    rc, screen = run(["docker", "exec", "-u", "cal", "cal", "tmux", "capture-pane", "-p", "-t", "cal:0"])
    lines = [ln.rstrip()[:110] for ln in screen.splitlines() if ln.strip()][-7:] if rc == 0 else ["(could not read the screen)"]
    return "ok", "Cal's session", "claude is running. Bottom of its screen:\n" + "\n".join(lines)


def check_jobs():
    rc, out = run(["docker", "exec", "-u", "cal", "-e", "HOME=/home/cal", "cal", "python3",
                   "/home/cal/pa/scripts/cron_doctor.py", "--check"], timeout=60)
    fails = [ln.strip() for ln in out.splitlines() if ln.strip().startswith("FAIL")]
    if fails:
        return "bad", f"Scheduled jobs: {len(fails)} failing", out
    if rc != 0:
        return "warn", "Scheduled jobs: could not check", out[-600:]
    oks = sum(1 for ln in out.splitlines() if ln.strip().startswith("ok"))
    return "ok", f"Scheduled jobs: {oks} ran as expected", out


def check_host():
    rows, state = [], "ok"
    rc, df = run(["df", "-h", "--output=pcent,avail", "/"])
    if rc == 0 and len(df.splitlines()) > 1:
        pcent, avail = df.splitlines()[1].split()
        rows.append(f"Disk: {pcent} used, {avail} free")
        if int(pcent.rstrip("%")) >= 90:
            state = "bad"
        elif int(pcent.rstrip("%")) >= 80:
            state = "warn"
    mem = {ln.split(":")[0]: int(ln.split()[1]) for ln in Path("/proc/meminfo").read_text().splitlines()[:5]}
    free_pct = 100 * mem.get("MemAvailable", 0) // max(mem.get("MemTotal", 1), 1)
    rows.append(f"Memory: {free_pct}% available")
    if free_pct < 10:
        state = "warn" if state == "ok" else state
    rows.append("Load: " + " ".join(Path("/proc/loadavg").read_text().split()[:3]))
    if Path("/var/run/reboot-required").exists():
        state = "warn" if state == "ok" else state
        rows.append(f"Reboot needed (running kernel {os.uname().release}) to finish installed updates")
    return state, "Host", "\n".join(rows)


def check_usage():
    # Written by Cal's status line; shows how much of the Claude plan is used.
    f = Path("/home/padraig/cal-home/.claude/statusline-last.json")
    try:
        limits = json.loads(f.read_text()).get("rate_limits") or {}
        age_min = int((time.time() - f.stat().st_mtime) / 60)
    except (OSError, ValueError):
        return None
    parts = []
    for key, label in (("five_hour", "5-hour"), ("seven_day", "week")):
        if key in limits:
            parts.append(f"{label}: {round(limits[key].get('used_percentage', 0))}% used")
    if not parts:
        return None
    worst = max(limits[k].get("used_percentage", 0) for k in limits if isinstance(limits[k], dict))
    return ("warn" if worst >= 85 else "ok"), "Claude usage", ", ".join(parts) + f" (as of {age_min} min ago)"


def pending() -> dict | None:
    try:
        return json.loads(PENDING.read_text())
    except (OSError, ValueError):
        return None


def check_allowlist():
    rc, tail = run(["tail", "-n", "4", str(ALLOWLIST_LOG)])
    p = pending()
    if p:
        return "warn", "Allowlist: a request is waiting", "Cal asked to open: " + " ".join(p["lines"]) + "\n\nRecent:\n" + tail
    return "ok", "Allowlist: nothing waiting", "Recent:\n" + tail


CHECKS = [check_allowlist, check_containers, check_session, check_jobs, check_host, check_usage]


def status() -> dict:
    items = []
    for check in CHECKS:
        try:
            result = check()
        except Exception as e:  # one broken check must not take the page down
            result = ("warn", check.__name__.replace("check_", "").title(), f"check failed: {e}")
        if result:
            items.append(dict(zip(("state", "summary", "detail"), result)))
    order = {"bad": 0, "warn": 1, "ok": 2}
    return {"at": time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime()),
            "worst": min((i["state"] for i in items), key=order.get, default="ok"),
            "items": items, "pending": pending()}


# --- page --------------------------------------------------------------------

PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light dark">
<title>Cal status</title><style>
body{font:16px/1.45 system-ui,sans-serif;max-width:40rem;margin:0 auto;padding:1rem}
h1{font-size:1.3rem;margin:.2rem 0 .1rem} .at{color:#888;margin:0 0 1rem;font-size:.9rem}
.item{border:1px solid #8884;border-left:6px solid #2e9a5f;border-radius:8px;padding:.6rem .8rem;margin:.6rem 0}
.item.warn{border-left-color:#d49a12}.item.bad{border-left-color:#d8432e}
.item h2{font-size:1rem;margin:0} pre{white-space:pre-wrap;word-break:break-word;font-size:.8rem;margin:.4rem 0 0;color:#888}
.ask{border:2px solid #d49a12;border-radius:10px;padding:.8rem;margin:.8rem 0}
.ask ul{margin:.4rem 0;padding-left:1.2rem;font-family:ui-monospace,monospace}
button{font:inherit;font-weight:600;padding:.55rem 1.4rem;border-radius:8px;border:1px solid #8886;margin:.4rem .5rem 0 0}
button.yes{background:#1d6fb8;color:#fff;border-color:transparent} .note{font-weight:600}
</style></head><body><h1>Cal status</h1><p class="at">%(at)s · <a href="/">refresh</a></p>%(note)s%(ask)s%(items)s</body></html>"""


def render(s: dict, note: str = "") -> str:
    e = html.escape
    ask = ""
    if s["pending"]:
        p = s["pending"]
        ask = (
            '<div class="ask"><b>Cal wants to open these domains to its outbound network:</b><ul>'
            + "".join(f"<li>{e(ln)}</li>" for ln in p["lines"])
            + f'</ul><small>Asked {e(p.get("at", ""))}. A leading dot means the domain and all its subdomains.</small>'
            f'<form method="post" action="/allowlist"><input type="hidden" name="csrf" value="{CSRF}">'
            f'<input type="hidden" name="hash" value="{e(p["hash"])}">'
            '<button class="yes" name="verdict" value="approve">Approve</button>'
            '<button name="verdict" value="deny">Deny</button></form></div>'
        )
    items = "".join(
        f'<div class="item {e(i["state"])}"><h2>{e(i["summary"])}</h2><pre>{e(i["detail"])}</pre></div>' for i in s["items"]
    )
    return PAGE % {"at": e(s["at"]), "note": f'<p class="note">{e(note)}</p>' if note else "", "ask": ask, "items": items}


class Handler(BaseHTTPRequestHandler):
    server_version = "cal-hub"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.headers.get("Tailscale-User-Login", "-"), fmt % args))

    def reply(self, code: int, body: str, ctype: str = "text/html; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
        self.end_headers()
        self.wfile.write(data)

    def owner(self) -> bool:
        want = conf().get("OWNER", "")
        got = self.headers.get("Tailscale-User-Login", "")
        if want and hmac.compare_digest(got.lower(), want.lower()):
            return True
        self.reply(403, "This page is only for the owner of this machine.", "text/plain; charset=utf-8")
        return False

    def do_GET(self):
        if not self.owner():
            return
        path = urlparse(self.path).path
        if path == "/":
            self.reply(200, render(status()))
        elif path == "/status.json":
            self.reply(200, json.dumps(status()), "application/json")
        else:
            self.reply(404, "not found", "text/plain")

    def do_POST(self):
        if not self.owner():
            return
        hub = conf().get("HUB_URL", "").rstrip("/")
        if urlparse(self.path).path != "/allowlist":
            return self.reply(404, "not found", "text/plain")
        if not hub or self.headers.get("Origin", "") != hub:
            return self.reply(403, "bad origin", "text/plain")
        length = int(self.headers.get("Content-Length") or 0)
        if length > 4000:
            return self.reply(413, "too large", "text/plain")
        form = parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        get = lambda k: (form.get(k) or [""])[0]
        if not hmac.compare_digest(get("csrf"), CSRF):
            return self.reply(403, "This page was open across a restart. Go back, refresh and try again.", "text/plain")
        verdict, digest = get("verdict"), get("hash")
        if verdict not in ("approve", "deny") or not re.fullmatch(r"[0-9a-f]{64}", digest):
            return self.reply(400, "bad request", "text/plain")
        rc, out = run([APPLY, "--approved" if verdict == "approve" else "--deny", digest], timeout=120)
        last = out.splitlines()[-1] if out else ""
        note = ("Approved. " if verdict == "approve" else "Denied. ") + last if rc == 0 else f"That did not go through: {last}"
        self.reply(200, render(status(), note))


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
