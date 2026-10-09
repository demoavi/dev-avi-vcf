#!/usr/bin/env python3
"""Org-assignment API served from the gw (vApp use case only).

  GET  /orgs  -> {"orgs": ["org-2", "org-3", ...]}   unassigned orgs
  POST /org   -> {"org_name": "org-1", "org_password": "...", <info fields>,
                  "bookmarks": [{"name": "vCenter", "url": "https://..."}, ...]}
                 where the info fields are the config's "info" object (e.g.
                 the SSO domain) and bookmarks the config's "bookmarks" list
                 (the services' URLs) - the same for every org, except that a
                 bookmark url may contain "{org_name}", which is replaced by the
                 org just assigned (URL-encoded), e.g. .../tenant/{org_name}/.
                 Assigns the lowest-numbered unassigned org and removes it
                 from /orgs; 409 {"error": "no org available"} if none left

HTTPS only (self-signed cert), HTTP basic auth on every request. An org is
"assigned" once /home/<org>/.assigned exists (created by the claim below, so
a later GET /orgs no longer lists it); there is deliberately no release.

Everything it needs is in one root-only JSON config, re-read per request:
  {"username", "password", "port", "cert", "key", "home_base",
   "info": {...}, "bookmarks": [{"name", "url"}, ...],
   "orgs": [{"name", "password"}, ...]}
rendered by gw-org-api.sh (which owns the org list/password derivation - the
same formula as gw-accounts.sh - so none of that is duplicated here).

POSTs are handled strictly one at a time (a lock around the whole claim) and
the claim itself is an O_CREAT|O_EXCL create, so two simultaneous POSTs can
never get the same org even if the lock were bypassed. GETs are concurrent.
Runs as root (it must create a file inside each org's own home dir).
"""
import base64
import hmac
import json
import os
import pwd
import re
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_PATH = sys.argv[1] if len(sys.argv) > 1 else "/etc/gw-org-api/config.json"
CLAIM_LOCK = threading.Lock()
SOCKET_TIMEOUT = 10  # seconds - a stalled client can't hold a thread forever


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def org_sort_key(name):
    m = re.search(r"(\d+)$", name)
    return (int(m.group(1)) if m else 10**9, name)


def assigned_path(cfg, name):
    return os.path.join(cfg["home_base"], name, ".assigned")


def available_orgs(cfg):
    """Configured orgs whose account home exists and has no .assigned yet."""
    out = []
    for org in sorted(cfg["orgs"], key=lambda o: org_sort_key(o["name"])):
        home = os.path.join(cfg["home_base"], org["name"])
        if os.path.isdir(home) and not os.path.exists(assigned_path(cfg, org["name"])):
            out.append(org)
    return out


def bookmarks_for(cfg, org_name):
    """The config's bookmarks with "{org_name}" in their url replaced by the
    org that was just assigned."""
    quoted = urllib.parse.quote(org_name, safe="")
    return [{**b, "url": b["url"].replace("{org_name}", quoted)} for b in cfg.get("bookmarks", [])]


def claim_next(cfg, client_ip):
    """Caller must hold CLAIM_LOCK. Returns the claimed org dict or None."""
    for org in available_orgs(cfg):
        path = assigned_path(cfg, org["name"])
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            continue  # claimed by something else since available_orgs() looked
        with os.fdopen(fd, "w") as f:
            f.write(f"assigned {time.strftime('%Y-%m-%dT%H:%M:%S%z')} to {client_ip}\n")
        if os.geteuid() == 0:
            try:
                pw = pwd.getpwnam(org["name"])
                os.chown(path, pw.pw_uid, pw.pw_gid)
            except KeyError:
                pass
        return org
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "gw-org-api"
    sys_version = ""
    timeout = SOCKET_TIMEOUT

    def log_message(self, fmt, *args):
        # request line + status only; never headers (Authorization).
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self, cfg):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            user, _, password = base64.b64decode(header[6:], validate=True).decode().partition(":")
        except Exception:
            return False
        # both compared unconditionally so a wrong username isn't faster
        ok_user = hmac.compare_digest(user.encode(), cfg["username"].encode())
        ok_pass = hmac.compare_digest(password.encode(), cfg["password"].encode())
        return ok_user and ok_pass

    def _handle(self, method):
        try:
            cfg = load_config()
        except Exception as e:
            sys.stderr.write(f"config error: {e}\n")
            return self._send(500, {"error": "server misconfigured"})
        if not self._authorized(cfg):
            return self._send(401, {"error": "unauthorized"},
                              {"WWW-Authenticate": 'Basic realm="gw-org-api"'})
        path = self.path.split("?", 1)[0].rstrip("/")
        if path == "/orgs":
            if method != "GET":
                return self._send(405, {"error": "method not allowed"}, {"Allow": "GET"})
            return self._send(200, {"orgs": [o["name"] for o in available_orgs(cfg)]})
        if path == "/org":
            if method != "POST":
                return self._send(405, {"error": "method not allowed"}, {"Allow": "POST"})
            with CLAIM_LOCK:
                org = claim_next(cfg, self.client_address[0])
            if org is None:
                return self._send(409, {"error": "no org available"})
            sys.stderr.write(f"assigned {org['name']} to {self.client_address[0]}\n")
            return self._send(200, {"org_name": org["name"], "org_password": org["password"],
                                    **cfg.get("info", {}), "bookmarks": bookmarks_for(cfg, org["name"])})
        return self._send(404, {"error": "not found"})

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        # body is never used; read (bounded) so keep-alive/clients stay sane
        n = min(int(self.headers.get("Content-Length") or 0), 65536)
        if n:
            self.rfile.read(n)
        self._handle("POST")

    do_PUT = do_DELETE = do_PATCH = lambda self: self._handle("OTHER")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def get_request(self):
        # TLS handshake is deferred into the per-connection thread (with a
        # timeout) instead of happening inside accept(), where one client
        # that connects and never speaks would stall every other client.
        sock, addr = self.socket.accept()
        sock.settimeout(SOCKET_TIMEOUT)
        return self.tls.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr


def main():
    cfg = load_config()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cfg["cert"], cfg["key"])
    srv = Server(("0.0.0.0", int(cfg["port"])), Handler)
    srv.tls = ctx
    sys.stderr.write(f"gw-org-api listening on :{cfg['port']}\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
