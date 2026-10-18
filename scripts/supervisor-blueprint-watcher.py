#!/usr/bin/env python3
"""
supervisor-blueprint-watcher - runs on the Supervisor (vm-watcher namespace, own ServiceAccount, read-only RBAC) and tells the gw
(gw-blueprint-api.py) which "app" labels exist in each org's namespace, as soon as a VirtualMachine is created,
deleted or relabelled.

It needs only NAMESPACED permissions (the Supervisor login used to deploy it cannot create ClusterRoles): the
namespaces to watch, with their org and project, come from targets.json (a ConfigMap mounted in the pod, re-read every
10 s), and each target namespace carries a Role/RoleBinding letting this ServiceAccount list and watch VirtualMachines.
One watch runs per target namespace. The FULL state is PUT, HMAC-signed, to the receiver:
  {"namespaces": [{"namespace", "organization_id", "project_id", "apps": [sorted distinct app label values]}]}
A target namespace with no labelled VM is reported with apps [] so the gw can empty its dropdown. The state is posted
again every RESYNC seconds, so a lost message or a gw restart heals by itself. A namespace whose list/watch failed is
left out of the state: an API error never produces an empty list (the gw would empty a dropdown on it).

Environment: RECEIVER_URL, RECEIVER_SECRET_FILE, RECEIVER_CA_FILE (optional, else the system store), TARGETS_FILE
(default /targets/targets.json), DEBOUNCE (default 2), RESYNC (default 300),
VM_API (default vmoperator.vmware.com/v1alpha5).
Stdlib only (runs in a plain python image).
"""

import hashlib
import hmac
import json
import os
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://{}:{}".format(os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc"),
                             os.environ.get("KUBERNETES_SERVICE_PORT", "443"))
VM_API = os.environ.get("VM_API", "vmoperator.vmware.com/v1alpha5")
RECEIVER_URL = os.environ["RECEIVER_URL"]
DEBOUNCE = float(os.environ.get("DEBOUNCE", "2"))
RESYNC = float(os.environ.get("RESYNC", "300"))
TARGETS_FILE = os.environ.get("TARGETS_FILE", "/targets/targets.json")

LOCK = threading.Lock()
VMS = {}            # (namespace, name) -> app label value or None
HEALTHY = set()     # target namespaces whose last list/watch worked
CHANGED = threading.Event()
LAST_EVENT = {"t": 0.0, "what": ""}


def log(msg):
    sys.stdout.write(time.strftime("%H:%M:%S ") + msg + "\n")
    sys.stdout.flush()


def k8s_ctx():
    ctx = ssl.create_default_context(cafile=SA_DIR + "/ca.crt")
    return ctx


def k8s_request(path, timeout=30):
    with open(SA_DIR + "/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout, context=k8s_ctx())


def load_targets():
    with open(TARGETS_FILE) as f:
        return {t["namespace"]: (t["organization_id"], t["project_id"]) for t in json.load(f)}


def list_vms(ns):
    with k8s_request(f"/apis/{VM_API}/namespaces/{ns}/virtualmachines") as r:
        data = json.load(r)
    vms = {(ns, i["metadata"]["name"]): (i["metadata"].get("labels") or {}).get("app") for i in data.get("items", [])}
    return vms, data["metadata"]["resourceVersion"]


def build_state(targets):
    with LOCK:
        snapshot, healthy = dict(VMS), set(HEALTHY)
    apps = {ns: set() for ns in targets}
    for (ns, _), app in snapshot.items():
        if app and ns in apps:
            apps[ns].add(app)
    return [{"namespace": ns, "organization_id": org, "project_id": proj, "apps": sorted(apps[ns])}
            for ns, (org, proj) in sorted(targets.items()) if ns in healthy]


def post_state(state):
    with open(os.environ["RECEIVER_SECRET_FILE"]) as f:
        secret = f.read().strip()
    body = json.dumps({"namespaces": state}, sort_keys=True).encode()
    ts = str(int(time.time()))
    sig = hmac.new(secret.encode(), ts.encode() + b"." + body, hashlib.sha256).hexdigest()
    ctx = ssl.create_default_context(cafile=os.environ.get("RECEIVER_CA_FILE") or None)
    req = urllib.request.Request(RECEIVER_URL, body, {"Content-Type": "application/json", "X-Timestamp": ts,
                                                      "X-Signature": sig}, method="PUT")
    with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
        return r.status


def watch_namespace(ns, stop):
    """Keeps VMS current for one namespace: list, then watch from the list's resourceVersion; relist on error/410."""
    while not stop.is_set():
        try:
            vms, rv = list_vms(ns)
            with LOCK:
                for key in [k for k in VMS if k[0] == ns]:
                    VMS.pop(key)
                VMS.update(vms)
                HEALTHY.add(ns)
            LAST_EVENT.update(t=time.time(), what=f"list {ns}")
            CHANGED.set()
            log(f"{ns}: listed {len(vms)} VirtualMachines (resourceVersion {rv})")
            while not stop.is_set():
                path = (f"/apis/{VM_API}/namespaces/{ns}/virtualmachines?watch=true&allowWatchBookmarks=true"
                        f"&resourceVersion={rv}&timeoutSeconds=60")
                with k8s_request(path, timeout=90) as r:
                    for line in r:
                        ev = json.loads(line)
                        typ, obj = ev["type"], ev["object"]
                        if typ == "ERROR":
                            raise RuntimeError("watch error: " + json.dumps(obj)[:200])
                        rv = obj["metadata"].get("resourceVersion", rv)
                        if typ == "BOOKMARK":
                            continue
                        key = (ns, obj["metadata"]["name"])
                        app = (obj["metadata"].get("labels") or {}).get("app")
                        with LOCK:
                            before = VMS.get(key, "<absent>")
                            if typ == "DELETED":
                                VMS.pop(key, None)
                            else:
                                VMS[key] = app
                            changed = before != VMS.get(key, "<absent>")
                        if changed:
                            LAST_EVENT.update(t=time.time(), what=f"{typ} {ns}/{key[1]} app={app}")
                            log(f"event {typ} {ns}/{key[1]} app={app}")
                            CHANGED.set()
                        if stop.is_set():
                            return
        except Exception as e:
            with LOCK:
                HEALTHY.discard(ns)
            log(f"{ns}: {e} - relisting in 5s")
            stop.wait(5)


def manage_watchers():
    """Starts/stops one watch thread per target namespace as targets.json changes."""
    running = {}
    while True:
        try:
            targets = load_targets()
        except Exception as e:
            log(f"cannot read {TARGETS_FILE}: {e}")
            time.sleep(10)
            continue
        for ns in targets:
            if ns not in running:
                stop = threading.Event()
                t = threading.Thread(target=watch_namespace, args=(ns, stop), daemon=True)
                running[ns] = (t, stop)
                t.start()
                log(f"watching {ns} (org {targets[ns][0][:8]}, project {targets[ns][1][:8]})")
        for ns in [n for n in running if n not in targets]:
            running.pop(ns)[1].set()
            with LOCK:
                HEALTHY.discard(ns)
                for key in [k for k in VMS if k[0] == ns]:
                    VMS.pop(key)
            log(f"no longer watching {ns}")
            CHANGED.set()
        time.sleep(10)


def main():
    threading.Thread(target=manage_watchers, daemon=True).start()
    last_posted, last_post_time, backoff = None, 0.0, 2.0
    while True:
        CHANGED.wait(timeout=30)
        if CHANGED.is_set():
            time.sleep(DEBOUNCE)  # coalesce a burst (e.g. several VMs created together)
            CHANGED.clear()
        try:
            state = build_state(load_targets())
        except Exception as e:
            log(f"cannot build the state ({e}), not posting")
            continue
        if not state:
            continue
        due = time.time() - last_post_time >= RESYNC
        if state == last_posted and not due:
            continue
        try:
            code = post_state(state)
            since = time.time() - LAST_EVENT["t"] if LAST_EVENT["t"] else 0
            log(f"posted state ({sum(len(s['apps']) > 0 for s in state)}/{len(state)} namespaces with apps) -> HTTP {code}"
                f"{'' if state != last_posted else ' [resync]'}; {since:.1f}s after '{LAST_EVENT['what']}'")
            last_posted, last_post_time, backoff = state, time.time(), 2.0
        except Exception as e:
            log(f"post failed: {e} - retry in {backoff:.0f}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)
            CHANGED.set()


if __name__ == "__main__":
    main()
