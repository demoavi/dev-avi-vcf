#!/bin/bash
#
# Node-side half of the vcfa-stabilize phase: runs AS ROOT on the VCF Automation node (single-node VMSP Kubernetes
# cluster). vcfa-stabilize.sh copies it over and runs it; it can also be run by hand on the node:
#
#   bash vcfa-stabilize-node.sh status                      # read-only, prints what is and is not at target
#   bash vcfa-stabilize-node.sh apply [load_max] [wait_sec] # idempotent; waits (bounded) for load1 < load_max first
#
# Why: on the nested lab VCF-A the platform has CPU bursts (load 100-500 for ~30 s, see the scripts README) and every
# leader-elected controller that misses its lease renewal by a few seconds exits, kube-vip drops the VIPs and the pods
# restart in waves. The values below are the ones measured to hold through those bursts (no controller restart and no
# failed VIP probe through load 500) - they do not remove the bursts, they stop each burst from taking the platform down.
#
#   - kube-controller-manager / kube-scheduler / vsphere-cpi / Envoy Gateway leader election 60s/40s/6s (defaults 15/10/2)
#   - kube-vip (control-plane static pod AND the vmsp-platform service kube-vip) 60/40/6 + preserve on leadership loss
#   - etcd CPU request 2500m + hourly auto-compaction
#   - Envoy Gateway controller probes and the gateway proxies (EnvoyProxy CRs) tolerate a 100 s stall
#   - the UI deployments in prelude get a CPU request (they were BestEffort and stalled for ~15 s under load)
#
# vmsp-operator / Flux revert some of these objects (the Envoy Gateway config map, vsphere-cpi, the kube-vip
# ReleaseTemplate), so a small keeper timer re-asserts exactly those every 60 s. Static pod manifests are not reverted
# and are edited once. Every static manifest is copied to /root/manifest-bak first. Not part of this script: a VM
# CPU/memory resize (results were measured at 32 vCPU / 128 GiB), the Kyverno webhook (Kyverno rewrites it itself).
#
MODE="${1:-apply}"
LOAD_MAX="${2:-20}"
LOAD_WAIT="${3:-600}"

M="${M:-/etc/kubernetes/manifests}"
BAK="${BAK:-/root/manifest-bak}"
TMPD="${TMPD:-/root}"
KEEPER=/root/vcfa-live-keeper.sh
STATIC_CHANGED=0

say() { echo "[vcfa-stabilize-node] $(date +%T) $*"; }

# kubeconfig on the node IP instead of the control-plane VIP: the VIP is exactly what flaps while kube-vip restarts
setup_kubeconfig() {
  local node_ip
  node_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [ -n "${node_ip}" ] || node_ip=$(hostname -I | awk '{print $1}')
  sed "s#server: https://.*#server: https://${node_ip}:6443#" /etc/kubernetes/admin.conf > /root/admin-local.conf
  chmod 600 /root/admin-local.conf
  export KUBECONFIG=/root/admin-local.conf
}

wait_api() { # up to 5 min for the API server to answer again after a static pod restart
  local i
  for i in $(seq 1 60); do
    kubectl get --raw=/readyz >/dev/null 2>&1 && return 0
    sleep 5
  done
  say "WARNING: API server not ready after 300 s"
  return 1
}

wait_calm() { # bounded: the etcd restart is gentler on a calm node, but a node that never calms down must not block the build
  local waited=0 l
  while [ "${waited}" -lt "${LOAD_WAIT}" ]; do
    l=$(cut -d' ' -f1 /proc/loadavg | cut -d. -f1)
    [ "${l}" -lt "${LOAD_MAX}" ] && return 0
    sleep 15; waited=$((waited + 15))
  done
  say "load1 still >= ${LOAD_MAX} after ${LOAD_WAIT} s, applying anyway"
}

backup_manifest() { cp "$1" "${BAK}/$(basename "$1").bak.$(date +%s)"; }

# Replaces a static pod manifest in place (same inode, kubelet sees one write). Refuses an empty or missing result so a
# failed edit can never truncate a live manifest.
install_manifest() {
  if [ ! -s "$2" ]; then
    say "ERROR: edit of $1 produced no output, manifest left untouched"
    rm -f "$2"
    return 1
  fi
  cat "$2" > "$1" && STATIC_CHANGED=1
  rm -f "$2"
}

leader_elect_static() { # $1 = kube-controller-manager | kube-scheduler
  local f="${M}/$1.yaml" t="${TMPD}/.vcfa-stab.$$"
  [ -f "${f}" ] || { say "$1: manifest missing, skipped"; return; }
  grep -q -- '--leader-elect=true' "${f}" || { say "$1: --leader-elect=true not found, skipped"; return; }
  if grep -q -- '--leader-elect-lease-duration=60s' "${f}" && grep -q -- '--leader-elect-renew-deadline=40s' "${f}" \
     && grep -q -- '--leader-elect-retry-period=6s' "${f}"; then
    say "$1: leader election already 60s/40s/6s"; return
  fi
  [ "${MODE}" == "apply" ] || { say "$1: leader election NOT at 60s/40s/6s"; return; }
  backup_manifest "${f}"
  # the flag lines are "<indent>- --flag"; the new ones copy the indent of the --leader-elect=true line
  grep -vE -- '--leader-elect-(lease-duration|renew-deadline|retry-period)=' "${f}" | awk '
    {print}
    /--leader-elect=true/ {match($0, /^ */); i = substr($0, 1, RLENGTH)
      print i "- --leader-elect-lease-duration=60s"; print i "- --leader-elect-renew-deadline=40s"; print i "- --leader-elect-retry-period=6s"}' > "${t}"
  install_manifest "${f}" "${t}" || return
  say "$1: leader election set to 60s/40s/6s"
}

kube_vip_static() { # control-plane VIP pod: lease 60 > renew 40 must change together or kube-vip panics
  local f="${M}/kube-vip.yaml" t="${TMPD}/.vcfa-stab.$$"
  [ -f "${f}" ] || { say "kube-vip static pod: manifest missing, skipped"; return; }
  sed -E '/name: vip_leaseduration/{n;s/value: *"?[0-9]+"?/value: "60"/}; /name: vip_renewdeadline/{n;s/value: *"?[0-9]+"?/value: "40"/}; /name: vip_retryperiod/{n;s/value: *"?[0-9]+"?/value: "6"/}; /name: vip_preserve_on_leadership_loss/{n;s/value: *"?false"?/value: "true"/}' "${f}" > "${t}"
  if cmp -s "${f}" "${t}"; then say "kube-vip static pod: already at target"; rm -f "${t}"; return; fi
  if [ "${MODE}" != "apply" ]; then say "kube-vip static pod: NOT at target"; rm -f "${t}"; return; fi
  backup_manifest "${f}"
  install_manifest "${f}" "${t}" || return
  say "kube-vip static pod: lease 60/40/6 + preserve=true"
}

etcd_static() {
  local f="${M}/etcd.yaml" t="${TMPD}/.vcfa-stab.$$"
  [ -f "${f}" ] || { say "etcd: manifest missing, skipped"; return; }
  grep -q -- '--election-timeout=' "${f}" || { say "etcd: --election-timeout not found, skipped"; return; }
  if grep -A3 'requests:' "${f}" | grep -q 'cpu: 2500m' && grep -q -- '--auto-compaction-mode=periodic' "${f}" \
     && grep -q -- '--auto-compaction-retention=1h' "${f}"; then
    say "etcd: already at target"; return
  fi
  [ "${MODE}" == "apply" ] || { say "etcd: NOT at target"; return; }
  backup_manifest "${f}"
  grep -vE -- '--auto-compaction-(mode|retention)=' "${f}" | awk '
    /requests:/ {r = 1}
    r && /cpu:/ {sub(/cpu: .*/, "cpu: 2500m"); r = 0}
    {print}
    /--election-timeout=/ {match($0, /^ */); i = substr($0, 1, RLENGTH)
      print i "- --auto-compaction-mode=periodic"; print i "- --auto-compaction-retention=1h"}' > "${t}"
  install_manifest "${f}" "${t}" || return
  say "etcd: cpu request 2500m, auto-compaction periodic/1h"
}

# The objects the operator or Flux revert: re-asserted by the keeper every 60 s (and once right away at install).
write_keeper() {
  cat > "${KEEPER}.new" <<'KEEPER_EOF'
#!/bin/bash
export KUBECONFIG=/root/admin-local.conf

# vsphere-cpi (RollingUpdate DaemonSet): leader election 60s/40s/6s
kubectl -n kube-system get ds vsphere-cpi -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -q renew-deadline || \
  kubectl -n kube-system patch ds vsphere-cpi --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--leader-elect-lease-duration=60s"},{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--leader-elect-renew-deadline=40s"},{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--leader-elect-retry-period=6s"}]' >/dev/null 2>&1

# kube-vip of the vmsp-platform service VIPs (gateway .19/.20): chart defaults 15/10/2 and preserve off drop the VIPs on every restart
RT=$(kubectl -n vmsp-platform get releasetemplate -o name 2>/dev/null | grep -i kube-vip | head -1)
if [ -n "${RT}" ]; then
  CUR=$(kubectl -n vmsp-platform get "${RT}" -o jsonpath='{.spec.helm.values.env.vip_leaseduration}/{.spec.helm.values.env.vip_renewdeadline}/{.spec.helm.values.env.vip_retryperiod}/{.spec.helm.values.env.vip_preserve_on_leadership_loss}' 2>/dev/null)
  [ "${CUR}" == "60/40/6/true" ] || kubectl -n vmsp-platform patch "${RT}" --type=merge -p '{"spec":{"helm":{"values":{"env":{"vip_preserve_on_leadership_loss":"true","vip_leaseduration":"60","vip_renewdeadline":"40","vip_retryperiod":"6"}}}}}' >/dev/null 2>&1
fi

# Envoy Gateway controller: its own leader election (default 15s lease, it exits "Completed" when the API server is late).
# The config map name carries the version; Envoy Gateway only reads it at start, so the keeper just keeps the block in place.
CM=$(kubectl -n vmsp-platform get cm -o name 2>/dev/null | grep 'configmap/envoy-gateway-config-' | head -1)
if [ -n "${CM}" ]; then
  kubectl -n vmsp-platform get "${CM}" -o jsonpath='{.data.envoy-gateway\.yaml}' > /tmp/vcfa-eg.cur 2>/dev/null
  if [ -s /tmp/vcfa-eg.cur ] && ! grep -q leaderElection /tmp/vcfa-eg.cur; then
    sed 's/^    shutdownManager:/    leaderElection:\n      leaseDuration: 60s\n      renewDeadline: 40s\n      retryPeriod: 6s\n    shutdownManager:/' /tmp/vcfa-eg.cur > /tmp/vcfa-eg.new
    grep -q leaderElection /tmp/vcfa-eg.new && \
      python3 -c 'import json,sys;print(json.dumps({"data":{"envoy-gateway.yaml":open(sys.argv[1]).read()}}))' /tmp/vcfa-eg.new > /tmp/vcfa-eg.json && \
      kubectl -n vmsp-platform patch "${CM}" --type=merge --patch-file /tmp/vcfa-eg.json >/dev/null 2>&1
  fi
fi
exit 0
KEEPER_EOF
  chmod 755 "${KEEPER}.new"
  mv -f "${KEEPER}.new" "${KEEPER}"   # atomic: the timer may be running the old file right now

  cat > /etc/systemd/system/vcfa-live-keeper.service.new <<'UNIT_EOF'
[Unit]
Description=VCF-A: re-apply the leader-election settings the operator reverts
[Service]
Type=oneshot
ExecStart=/root/vcfa-live-keeper.sh
UNIT_EOF
  # OnActiveSec makes the first run happen right after enabling: with OnBootSec/OnUnitActiveSec alone a timer enabled on a
  # node that is already up would never fire.
  cat > /etc/systemd/system/vcfa-live-keeper.timer.new <<'UNIT_EOF'
[Unit]
Description=VCF-A: run vcfa-live-keeper every 60 s
[Timer]
OnActiveSec=20s
OnUnitActiveSec=60s
Unit=vcfa-live-keeper.service
[Install]
WantedBy=timers.target
UNIT_EOF
  mv -f /etc/systemd/system/vcfa-live-keeper.service.new /etc/systemd/system/vcfa-live-keeper.service
  mv -f /etc/systemd/system/vcfa-live-keeper.timer.new /etc/systemd/system/vcfa-live-keeper.timer
  systemctl daemon-reload
  systemctl enable --now vcfa-live-keeper.timer >/dev/null 2>&1
  "${KEEPER}"
  say "keeper timer installed and run once (vsphere-cpi, kube-vip service ReleaseTemplate, Envoy Gateway config)"
}

# Deployments / CRs the operator does not revert: patched once, idempotent.
live_objects() {
  # Envoy Gateway controller deployment: probes tolerate a stall (the controller exits cleanly and fails its probes while draining)
  local lt lf
  lt=$(kubectl -n vmsp-platform get deploy envoy-gateway -o jsonpath='{.spec.template.spec.containers[?(@.name=="envoy-gateway")].livenessProbe.timeoutSeconds}' 2>/dev/null)
  lf=$(kubectl -n vmsp-platform get deploy envoy-gateway -o jsonpath='{.spec.template.spec.containers[?(@.name=="envoy-gateway")].startupProbe.failureThreshold}' 2>/dev/null)
  if [ "${lt}" == "10" ] && [ "${lf}" == "60" ]; then
    say "envoy-gateway deployment: probes already tolerant"
  elif [ "${MODE}" == "apply" ]; then
    kubectl -n vmsp-platform get deploy envoy-gateway -o yaml > "${BAK}/envoy-gateway-deploy.yaml.$(date +%s)" 2>/dev/null
    kubectl -n vmsp-platform patch deploy envoy-gateway --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"envoy-gateway","livenessProbe":{"timeoutSeconds":10,"failureThreshold":6,"periodSeconds":20},"readinessProbe":{"timeoutSeconds":10,"failureThreshold":6,"periodSeconds":10},"startupProbe":{"httpGet":{"path":"/healthz","port":8081},"timeoutSeconds":10,"failureThreshold":60,"periodSeconds":10}}]}}}}' >/dev/null 2>&1 \
      && say "envoy-gateway deployment: probes patched" || say "WARNING: envoy-gateway deployment probe patch failed"
  else
    say "envoy-gateway deployment: probes NOT tolerant (liveness timeout='${lt}', startup failureThreshold='${lf}')"
  fi

  [ "${MODE}" == "apply" ] || return 0
  python3 - <<'PY_EOF'
import json, subprocess

def kubectl(*args):
    return subprocess.run(["kubectl", *args], capture_output=True, text=True)

# Data-plane gateway proxies (vcfa-gateway-configuration, vmsp-gateway): probe tolerance (liveness 10x, readiness 3x, timeout >= 5 s)
# and the /tmp mount of the shutdown manager - the same patch the Broadcom HOL tuner applies to these CRs.
for name in kubectl("get", "envoyproxy", "-n", "vmsp-platform", "-o", "name").stdout.split():
    obj = json.loads(kubectl("get", name, "-n", "vmsp-platform", "-o", "json").stdout or "{}")
    ed = (((obj.get("spec") or {}).get("provider") or {}).get("kubernetes") or {}).get("envoyDeployment")
    if ed is None:
        continue
    patch = ed.setdefault("patch", {"type": "StrategicMerge", "value": {}})
    spec = patch.setdefault("value", {}).setdefault("spec", {}).setdefault("template", {}).setdefault("spec", {})
    containers = spec.get("containers") or [{"name": "envoy"}, {"name": "shutdown-manager"}]
    spec["containers"] = containers
    changed = False
    for c in containers:
        if c.get("name") not in ("envoy", "shutdown-manager"):
            continue
        for key, ft in (("livenessProbe", 10), ("readinessProbe", 3), ("startupProbe", None)):
            p = c.setdefault(key, {})
            if ft is not None and (p.get("failureThreshold") or 0) < ft:
                p["failureThreshold"] = ft
                changed = True
            if (p.get("timeoutSeconds") or 0) < 5:
                p["timeoutSeconds"] = 5
                changed = True
        if c.get("name") == "shutdown-manager":
            mounts = c.setdefault("volumeMounts", [])
            if not any(m.get("mountPath") == "/tmp" for m in mounts):
                mounts.append({"name": "shutdown-manager", "mountPath": "/tmp"})
                changed = True
    if changed:
        body = json.dumps({"spec": {"provider": {"kubernetes": {"envoyDeployment": {"patch": patch}}}}})
        r = kubectl("patch", name, "-n", "vmsp-platform", "--type=merge", "-p", body)
        print(f"[vcfa-stabilize-node] {name}: probe tolerance + /tmp mount " + ("patched" if r.returncode == 0 else "FAILED: " + r.stderr.strip()))
    else:
        print(f"[vcfa-stabilize-node] {name}: already tolerant")

# UI tier in prelude: BestEffort (no requests) gets cpu.weight 1 and stalls ~15 s under load -> give it a CPU request.
ui_names = ("nginx-httpd-app", "proxy-service", "health-status-app")
items = json.loads(kubectl("get", "deploy", "-n", "prelude", "-o", "json").stdout or '{"items": []}')["items"]
for it in items:
    name = it["metadata"]["name"]
    if not (name in ui_names or name.endswith("-ui-app")):
        continue
    cs = it["spec"]["template"]["spec"].get("containers") or []
    if not cs or (cs[0].get("resources", {}).get("requests") or {}).get("cpu"):
        continue
    body = json.dumps({"spec": {"template": {"spec": {"containers": [{"name": cs[0]["name"], "resources": {"requests": {"cpu": "200m", "memory": "64Mi"}}}]}}}})
    r = kubectl("patch", "deploy", name, "-n", "prelude", "--type=strategic", "-p", body)
    print(f"[vcfa-stabilize-node] prelude/{name}: cpu request 200m " + ("added" if r.returncode == 0 else "FAILED: " + r.stderr.strip()))
PY_EOF
}

status() {
  echo "load: $(cut -d' ' -f1-3 /proc/loadavg)"
  for c in kube-controller-manager kube-scheduler; do
    echo "${c}: $(grep -oE 'leader-elect-(lease-duration|renew-deadline|retry-period)=[0-9a-z]+' "${M}/${c}.yaml" 2>/dev/null | tr '\n' ' ')"
  done
  echo "etcd: $(grep -A3 'requests:' "${M}/etcd.yaml" 2>/dev/null | grep cpu | tr -d ' ') $(grep -oE 'auto-compaction-[a-z]+=[0-9a-z]+' "${M}/etcd.yaml" 2>/dev/null | tr '\n' ' ')"
  echo "kube-vip static: $(grep -A1 -E 'name: vip_(leaseduration|renewdeadline|retryperiod|preserve_on_leadership_loss)' "${M}/kube-vip.yaml" 2>/dev/null | grep value | tr -d ' ' | tr '\n' ' ')"
  echo "vsphere-cpi args: $(kubectl -n kube-system get ds vsphere-cpi -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)"
  echo "kube-vip service env: $(kubectl -n vmsp-platform get releasetemplate -o name 2>/dev/null | grep -i kube-vip | head -1 | xargs -r -I{} kubectl -n vmsp-platform get {} -o jsonpath='{.spec.helm.values.env}' 2>/dev/null)"
  echo "envoy-gateway lease: $(kubectl -n vmsp-platform get lease 5b9825d2.gateway.envoyproxy.io -o jsonpath='{.spec.leaseDurationSeconds}' 2>/dev/null)s (60 once the pod restarted after the config block was added)"
  echo "keeper timer: $(systemctl is-active vcfa-live-keeper.timer 2>/dev/null)"
}

main() {
  mkdir -p "${BAK}"
  setup_kubeconfig
  case "${MODE}" in
    status) status ;;
    apply)
      say "applying (load1 gate ${LOAD_MAX}, max wait ${LOAD_WAIT} s)"
      wait_calm
      live_objects
      write_keeper
      # static pods last: kube-vip / controller-manager / scheduler restart on their own, etcd is edited last so the API
      # server restarts once
      kube_vip_static
      leader_elect_static kube-controller-manager
      leader_elect_static kube-scheduler
      [ "${STATIC_CHANGED}" -eq 1 ] && { sleep 15; wait_api; }
      STATIC_CHANGED=0
      etcd_static
      [ "${STATIC_CHANGED}" -eq 1 ] && { sleep 20; wait_api; }
      status
      ;;
    *) echo "usage: $0 status|apply [load_max] [wait_sec]"; exit 2 ;;
  esac
}

# Sourced by a test harness: functions only. Run directly: do the work.
if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  main
fi
