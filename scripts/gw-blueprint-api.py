#!/usr/bin/env python3
"""
gw-blueprint-api - keeps the "app" dropdown of a VCF Automation blueprint in sync with the "app" labels of the
VirtualMachines in each org's Supervisor namespace.

A small read-only watcher on the Supervisor (supervisor-blueprint-watcher, namespace vm-watcher) PUTs the FULL state whenever a VM label changes
(and periodically): this service owns the VCF Automation credentials, checks every project with VCF Automation itself
(the namespace labels the watcher reads are only a hint) and rewrites inputs.<input_name>.enum of the blueprint named
<blueprint_name> in that project, releasing a new version, only when the list actually changed.

  PUT (or POST) /apps/state   HMAC-authenticated, body:
      {"namespaces": [{"namespace": "ns-1-abcde", "organization_id": "<uuid>", "project_id": "<uuid>",
                       "apps": ["app1", "latency-test"]}, ...]}
      headers: X-Timestamp: <epoch seconds>, X-Signature: hex(HMAC-SHA256(secret, "<timestamp>.<raw body>"))
      -> 202 {"accepted": <n>}, the VCF Automation update runs in the background
  GET  /healthz      unauthenticated, 200

Config (JSON, path = argv[1], re-read per request and per reconcile; root-only because it holds secrets):
  {"bind", "port", "cert", "key", "secret", "vcfa_host", "vcfa_user", "vcfa_password", "vcfa_version",
   "blueprint_name", "input_name", "verify_tls", "max_skew"}

Stdlib + PyYAML only.
"""

import hashlib
import hmac
import json
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import yaml

MAX_BODY = 1024 * 1024
SOCKET_TIMEOUT = 15
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
NS_RE = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
# Kubernetes label values: at most 63 chars of [A-Za-z0-9_.-], starting and ending alphanumeric
APP_RE = re.compile(r"^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$")

PENDING = {"state": None}
PENDING_LOCK = threading.Lock()
WAKE = threading.Event()
LAST_APPLIED = {}  # project_id -> sorted apps last confirmed (informational only)


def log(msg):
    sys.stderr.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    sys.stderr.flush()


def load_config():
    path = sys.argv[1] if len(sys.argv) > 1 else "/etc/gw-blueprint-api/config.json"
    with open(path) as f:
        cfg = json.load(f)
    for key in ("bind", "port", "cert", "key", "secret", "vcfa_host", "vcfa_user", "vcfa_password",
                "blueprint_name", "input_name"):
        if not cfg.get(key):
            raise ValueError(f"config key '{key}' is missing")
    cfg.setdefault("vcfa_version", "9.1.0")
    cfg.setdefault("verify_tls", False)
    cfg.setdefault("max_skew", 60)
    return cfg


def sign(secret, timestamp, body):
    return hmac.new(secret.encode(), timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()


def clean_state(payload):
    """Validates the posted state; returns {project_id: {"org": org_id, "apps": set(), "namespaces": [..]}} or raises."""
    if not isinstance(payload, dict) or not isinstance(payload.get("namespaces"), list):
        raise ValueError("body must be {\"namespaces\": [...]}")
    projects = {}
    for entry in payload["namespaces"]:
        if not isinstance(entry, dict):
            raise ValueError("namespace entries must be objects")
        ns, org, proj, apps = (entry.get("namespace"), entry.get("organization_id"), entry.get("project_id"),
                               entry.get("apps"))
        if not (isinstance(ns, str) and NS_RE.match(ns)):
            raise ValueError("invalid namespace name")
        if not (isinstance(org, str) and UUID_RE.match(org) and isinstance(proj, str) and UUID_RE.match(proj)):
            raise ValueError(f"invalid organization_id/project_id for namespace {ns}")
        if not isinstance(apps, list) or len(apps) > 500:
            raise ValueError(f"apps of namespace {ns} must be a list (max 500)")
        for a in apps:
            if not (isinstance(a, str) and APP_RE.match(a)):
                raise ValueError(f"invalid app label value in namespace {ns}")
        p = projects.setdefault(proj, {"org": org, "apps": set(), "namespaces": []})
        if p["org"] != org:
            raise ValueError(f"project {proj} is posted with two different organizations")
        p["apps"].update(apps)
        p["namespaces"].append(ns)
    return projects


# ---------------------------------------------------------------------------------------------------------------
# VCF Automation
# ---------------------------------------------------------------------------------------------------------------
class Vcfa:
    def __init__(self, cfg):
        self.host = cfg["vcfa_host"].rstrip("/")
        self.version = cfg["vcfa_version"]
        self.ctx = ssl.create_default_context()
        if not cfg["verify_tls"]:
            self.ctx.check_hostname = False
            self.ctx.verify_mode = ssl.CERT_NONE
        self.user, self.password = cfg["vcfa_user"], cfg["vcfa_password"]
        self.provider_token = None
        self.client_id = None

    def call(self, method, path, token=None, data=None, headers=None, form=None, want_headers=False, basic=None):
        url = self.host + "/" + path.lstrip("/")
        hdrs = {"Accept": f"application/json;version={self.version}"}
        if token:
            hdrs["Authorization"] = "Bearer " + token
        if basic:
            hdrs["Authorization"] = "Basic " + basic
        body = None
        if form is not None:
            body = urllib.parse.urlencode(form).encode()
            hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        elif data is not None:
            body = json.dumps(data).encode()
            hdrs["Content-Type"] = "application/json"
        hdrs.update(headers or {})
        req = urllib.request.Request(url, body, hdrs, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30, context=self.ctx) as r:
                raw = r.read()
                parsed = json.loads(raw) if raw.strip().startswith((b"{", b"[")) else None
                return (r.status, parsed, dict(r.headers)) if want_headers else (r.status, parsed)
        except urllib.error.HTTPError as e:
            detail = e.read()[:300].decode(errors="replace")
            raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {detail}")

    def login(self):
        import base64
        basic = base64.b64encode(f"{self.user}@system:{self.password}".encode()).decode()
        _, _, hdrs = self.call("POST", "cloudapi/1.0.0/sessions/provider", basic=basic, want_headers=True,
                               data=None, headers={"Content-Type": f"application/json;version={self.version}"})
        self.provider_token = {k.lower(): v for k, v in hdrs.items()}.get("x-vmware-vcloud-access-token")
        if not self.provider_token:
            raise RuntimeError("provider login returned no access token")
        _, rps = self.call("GET", "cloudapi/1.0.0/openIdProvider/relyingParties", self.provider_token)
        values = rps.get("values", [])
        pick = [v for v in values if v.get("clientName") == "automation-relying-party"] or \
               [v for v in values if v.get("isPublic")]
        if not pick:
            raise RuntimeError("no relying party client id found")
        self.client_id = pick[0]["clientId"]

    def org_token(self, org_uuid):
        """Org-scoped token for the org with this UUID (jwt-bearer exchange of the provider token). Fails when the org
        does not exist, which is the first validation of the org id the watcher claims."""
        _, body = self.call("POST", "oidc/oauth2/token",
                            headers={"x-vmware-vcloud-tenant-context": org_uuid},
                            form={"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                  "scope": "openid profile email phone groups vcd_idp",
                                  "assertion": self.provider_token, "client_id": self.client_id})
        token = (body or {}).get("access_token")
        if not token:
            raise RuntimeError(f"no org token for org {org_uuid}")
        return token


def reconcile_project(vcfa, cfg, project_id, info):
    # An empty list is the truth too (the last labelled VM was deleted): enum [] is a valid, releasable blueprint, and the
    # form then offers nothing to pick. The watcher only posts a state it listed successfully, so an empty list here is
    # never a transient error.
    org, apps = info["org"], sorted(info["apps"])
    token = vcfa.org_token(org)
    # an org token only sees its own org's projects: the project must belong to the org the watcher claims
    _, projects = vcfa.call("GET", "project-service/api/projects", token)
    if project_id not in [p.get("id") for p in (projects or {}).get("content", [])]:
        raise RuntimeError(f"project {project_id} is not a project of org {org}, ignoring it")
    _, bps = vcfa.call("GET", "blueprint/api/blueprints", token)
    match = [b for b in (bps or {}).get("content", [])
             if b.get("name") == cfg["blueprint_name"] and b.get("projectId") == project_id]
    if not match:
        log(f"project {project_id}: no blueprint named {cfg['blueprint_name']}, nothing to update")
        return
    bp_id = match[0]["id"]
    _, bp = vcfa.call("GET", f"blueprint/api/blueprints/{bp_id}", token)
    content = yaml.safe_load(bp["content"])
    inputs = content.get("inputs") or {}
    field = inputs.get(cfg["input_name"])
    if not isinstance(field, dict):
        raise RuntimeError(f"blueprint {cfg['blueprint_name']} has no input '{cfg['input_name']}'")
    if field.get("enum") == apps:
        LAST_APPLIED[project_id] = apps
        return
    field.pop("$dynamicEnum", None)
    field["enum"] = apps
    bp["content"] = yaml.safe_dump(content, sort_keys=False, default_flow_style=False, allow_unicode=True)
    vcfa.call("PUT", f"blueprint/api/blueprints/{bp_id}", token, data=bp)
    _, versions = vcfa.call("GET", f"blueprint/api/blueprints/{bp_id}/versions", token)
    numeric = [int(v["version"]) for v in (versions or {}).get("content", []) if str(v.get("version", "")).isdigit()]
    version = str(max(numeric) + 1) if numeric else time.strftime("%Y%m%d%H%M%S")
    vcfa.call("POST", f"blueprint/api/blueprints/{bp_id}/versions", token,
              data={"version": version, "description": "app labels from the Supervisor",
                    "changeLog": f"{cfg['input_name']} enum = {apps}", "release": True})
    LAST_APPLIED[project_id] = apps
    log(f"project {project_id} (org {org}): {cfg['blueprint_name']}.{cfg['input_name']} enum -> {apps} (version {version})")


def worker():
    while True:
        WAKE.wait()
        time.sleep(1)  # coalesce a burst of posts into one pass
        with PENDING_LOCK:
            projects, PENDING["state"] = PENDING["state"], None
            WAKE.clear()
        if not projects:
            continue
        try:
            cfg = load_config()
            vcfa = Vcfa(cfg)
            vcfa.login()
        except Exception as e:
            log(f"VCF Automation login failed: {e}")
            with PENDING_LOCK:  # keep the state for the next post/resync unless a newer one arrived
                PENDING["state"] = PENDING["state"] or projects
            continue
        for project_id, info in projects.items():
            try:
                reconcile_project(vcfa, cfg, project_id, info)
            except Exception as e:
                log(f"project {project_id}: {e}")


# ---------------------------------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "gw-blueprint-api"
    sys_version = ""

    def log_message(self, fmt, *args):
        log(f"{self.client_address[0]} {fmt % args}")

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/healthz":
            return self._send(200, {"status": "ok"})
        self._send(404, {"error": "not found"})

    def do_PUT(self):  # the full state replaces the previous one: PUT is the natural verb, POST is accepted too
        self.do_POST()

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/apps/state":
            return self._send(404, {"error": "not found"})
        try:
            cfg = load_config()
        except Exception as e:
            log(f"config error: {e}")
            return self._send(500, {"error": "server misconfigured"})
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BODY:
            return self._send(413 if n > MAX_BODY else 400, {"error": "bad body size"})
        body = self.rfile.read(n)
        ts, sig = self.headers.get("X-Timestamp", ""), self.headers.get("X-Signature", "")
        try:
            fresh = abs(time.time() - float(ts)) <= int(cfg["max_skew"])
        except ValueError:
            fresh = False
        expected = sign(cfg["secret"], ts, body)
        if not (fresh and hmac.compare_digest(expected.encode(), sig.encode())):
            return self._send(401, {"error": "unauthorized"})
        try:
            projects = clean_state(json.loads(body))
        except (ValueError, json.JSONDecodeError) as e:
            return self._send(400, {"error": str(e)})
        with PENDING_LOCK:
            PENDING["state"] = projects
        WAKE.set()
        self._send(202, {"accepted": len(projects)})


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def get_request(self):
        sock, addr = self.socket.accept()
        sock.settimeout(SOCKET_TIMEOUT)
        return self.tls.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr


def main():
    cfg = load_config()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cfg["cert"], cfg["key"])
    srv = Server((cfg["bind"], int(cfg["port"])), Handler)
    srv.tls = ctx
    threading.Thread(target=worker, daemon=True).start()
    log(f"gw-blueprint-api listening on {cfg['bind']}:{cfg['port']} (blueprint {cfg['blueprint_name']}, input {cfg['input_name']})")
    srv.serve_forever()


if __name__ == "__main__":
    main()
