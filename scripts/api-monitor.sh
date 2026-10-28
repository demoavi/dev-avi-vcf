#!/bin/bash
#
# API availability monitor (diagnostic, not part of vcf_bootstrap.sh's phases). Probes every API of the platform once per
# second (default) from the gw, in parallel, and writes a raw sample file plus a report that shows WHICH api is not always on:
# per-target availability, latency percentiles, every outage window (start, end, duration, HTTP codes) and the moments where
# several targets were down together (a shared cause, e.g. the ESX host or the storage, rather than one broken service).
#
#   bash api-monitor.sh [json file] [--duration <seconds>] [--interval <seconds>] [--out <dir>]
#   bash api-monitor.sh --report <dir>        # rebuild the report of an earlier run
#
# Defaults: json /home/ubuntu/json/deployment.json, 1800 s (30 min), 1 s, out /home/ubuntu/api-monitor/<timestamp>. Meant to be
# started with nohup on the gw and left alone: `nohup bash api-monitor.sh --duration 1800 > /dev/null 2>&1 &`. Ctrl-C / kill
# stops it cleanly and still writes the report. Output: samples.csv (ts|target|http_code|seconds|ok), report.md, monitor.log.
#
# Variables and credentials are derived like in the phase scripts (variables.sh + functions.sh, generic_password, the
# per-org password derived from gw_accounts_secret); nothing is passed on the command line. Targets whose address is not known
# (e.g. no Supervisor yet, git/harbor disabled) are skipped and listed in monitor.log. Read-only: no call changes anything,
# except that logins create sessions (re-done only when the API answers 401/403 or the token is missing).
#
# What "ok" means: the call answered within 5 s with the expected status (per target below). A timeout or refused connection is
# code 000. Each probe asks something that needs the service's own backend (not just the web server in front of it) where an
# authenticated call is possible, so "up" is not just "the port answers".
#
# Targets: vcenter, vcenter-login (only when a re-login was needed), nsx, avi, vcfa-system, vcfa-system-login, vcfa-org,
# vcfa-org-cci, vcfa-ui, supervisor, installer, esxi-<n>, vault, harbor, git, dns-gw, dns-avi, vcd (vApp use case).
#
# Do not edit this script while it is running (bash reads scripts incrementally).
#
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

duration=1800
interval=1
out=""
jsonFile="/home/ubuntu/json/deployment.json"
report_only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) duration="${2:?}"; shift 2 ;;
    --interval) interval="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    --report) report_only="${2:?}"; shift 2 ;;
    -h|--help) sed -n 2,26p "$0"; exit 0 ;;
    *) jsonFile="$1"; shift ;;
  esac
done

make_report() { # dir
  python3 -I - "$1" <<'PYEOF'
import sys, os, collections, statistics, datetime

d = sys.argv[1]
rows = collections.defaultdict(list)
with open(os.path.join(d, "samples.csv")) as f:
    for line in f:
        p = line.rstrip("\n").split("|")
        if len(p) < 5:
            continue
        try:
            rows[p[1]].append((float(p[0]), p[2], float(p[3]), p[4] == "1"))
        except ValueError:
            pass
if not rows:
    print("no samples in", d)
    sys.exit(1)

def hms(t):
    return datetime.datetime.fromtimestamp(t).strftime("%H:%M:%S")

def pct(vals, q):
    if not vals:
        return 0.0
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(round(q * (len(vals) - 1))))]

GAP = 3.0  # failures closer than this belong to the same outage
all_start = min(r[0][0] for r in rows.values())
all_end = max(r[-1][0] for r in rows.values())
outages = []  # (target, start, end, n_fail, codes)
summary = []
for name in sorted(rows):
    s = sorted(rows[name])
    n = len(s)
    bad = [x for x in s if not x[3]]
    lat = [x[2] for x in s if x[3]]
    cur = None
    own = []
    for x in s:
        if x[3]:
            continue
        if cur and x[0] - cur[1] <= GAP + 1.0:
            cur[1] = x[0]; cur[2] += 1; cur[3][x[1]] += 1
        else:
            if cur:
                own.append(cur)
            cur = [x[0], x[0], 1, collections.Counter({x[1]: 1})]
    if cur:
        own.append(cur)
    for o in own:
        outages.append((name, o[0], o[1], o[2], o[3]))
    longest = max((o[1] - o[0] + 1 for o in own), default=0)
    summary.append((name, n, len(bad), 100.0 * (n - len(bad)) / n, len(own), longest,
                    pct(lat, .5), pct(lat, .95), max(lat, default=0.0)))

L = []
L.append("# API availability report")
L.append("")
L.append(f"Window: {hms(all_start)} - {hms(all_end)} ({(all_end-all_start)/60:.1f} min), outage = failed samples less than {GAP:.0f} s apart.")
L.append("")
L.append("## Per target (worst availability first)")
L.append("")
L.append("| target | samples | failed | availability % | outages | longest outage (s) | p50 s | p95 s | max s |")
L.append("|---|---|---|---|---|---|---|---|---|")
for r in sorted(summary, key=lambda r: (r[3], -r[4])):
    L.append(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]:.2f} | {r[4]} | {r[5]:.0f} | {r[6]:.2f} | {r[7]:.2f} | {r[8]:.2f} |")
L.append("")
L.append("## Outages (chronological)")
L.append("")
if outages:
    L.append("| target | from | to | duration (s) | failed samples | codes |")
    L.append("|---|---|---|---|---|---|")
    for o in sorted(outages, key=lambda o: o[1]):
        codes = ", ".join(f"{k} x{v}" for k, v in o[4].most_common())
        L.append(f"| {o[0]} | {hms(o[1])} | {hms(o[2])} | {o[2]-o[1]+1:.0f} | {o[3]} | {codes} |")
else:
    L.append("None - every sample of every target was ok.")
L.append("")

# Windows where two or more targets were down at the same time (login probes are excluded: they only exist after a failure).
down = collections.defaultdict(set)
for name, s, e, n, c in outages:
    if name.endswith("-login"):
        continue
    t = int(s)
    while t <= int(e) + 0:
        down[t].add(name)
        t += 1
wins = []
for t in sorted(down):
    if len(down[t]) < 2:
        continue
    if wins and t - wins[-1][1] <= 2:
        wins[-1][1] = t; wins[-1][2] |= down[t]
    else:
        wins.append([t, t, set(down[t])])
L.append("## Shared outages (2+ targets down at once)")
L.append("")
if wins:
    L.append("| from | to | duration (s) | targets |")
    L.append("|---|---|---|---|")
    for w in wins:
        L.append(f"| {hms(w[0])} | {hms(w[1])} | {w[1]-w[0]+1} | {', '.join(sorted(w[2]))} |")
else:
    L.append("None - no two targets were down at the same time.")
L.append("")
L.append("Raw samples: samples.csv (ts|target|http_code|seconds|ok). Code 000 = timeout or connection refused (5 s limit).")
text = "\n".join(L) + "\n"
open(os.path.join(d, "report.md"), "w").write(text)
print(text)
PYEOF
}

if [ -n "${report_only}" ]; then
  make_report "${report_only}"
  exit $?
fi

source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

[ -z "${out}" ] && out="/home/ubuntu/api-monitor/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}" || exit 1
samples="${out}/samples.csv"
mlog="${out}/monitor.log"
: > "${samples}"
mlog() { echo "$(date '+%H:%M:%S') $*" | tee -a "${mlog}"; }

end_ts=$(( $(date +%s) + duration ))
CURL=(curl -sk -m 5 --connect-timeout 3)

# --- derived addresses and credentials -------------------------------------------------------------------------------
vc_host="${basename_sddc}-vc01.${domain}"
vc_user="administrator@$(jq -r '.sddc.vcenter.ssoDomain // "vsphere.local"' "${jsonFile}")"
nsx_host="${ip_nsx_vip}"
avi_host="$(echo "${ips_avi:-[]}" | jq -r '.[0] // empty')"
vcfa_host="${fqdn_vcfa:-${basename_sddc}-auto-vip.${domain}}"
vcfa_ver="9.1.0"
first_org="$(echo "${vcf_a_organizations:-[]}" | jq -r '.[0].name // empty')"
org_pw=""
[ -n "${first_org}" ] && org_pw="VMware1!$(echo -n "${gw_accounts_secret}${first_org}" | sha256sum | cut -c1-4)VMware1!"
sub="${avi_subdomain:-}"
vcd_host=$(jq -r '.vcd.host // empty' "${jsonFile}" 2>/dev/null)

# --- probe plumbing --------------------------------------------------------------------------------------------------
# rec <target> <code> <seconds> <ok regex>: one sample line. Appends of one short line are atomic, so the loops share the file.
rec() {
  local ok=0
  [[ "$2" =~ ^($4)$ ]] && ok=1
  printf '%s|%s|%s|%s|%s\n' "$(date +%s.%N | cut -c1-14)" "$1" "$2" "$3" "${ok}" >> "${samples}"
  [ "${ok}" == "1" ]
}
# hit <target> <ok regex> <curl args...>: one timed call; leaves the response body in ${body_file}; returns 0 when ok.
hit() {
  local t="$1" okre="$2" r; shift 2
  r=$("${CURL[@]}" -o "${body_file}" -w '%{http_code} %{time_total}' "$@" 2>/dev/null)
  [ -z "${r}" ] && r="000 5.000"
  rec "${t}" "${r% *}" "${r#* }" "${okre}"
}
# every target runs in its own background loop (own variables = own session state), one call per interval
loop() { # name function
  local name="$1" fn="$2" t0 t1 rem
  body_file="${out}/.${name}.body"
  while [ "$(date +%s)" -lt "${end_ts}" ]; do
    t0=$(date +%s%N)
    "${fn}"
    t1=$(date +%s%N)
    rem=$(( interval * 1000000000 - (t1 - t0) ))
    [ "${rem}" -gt 0 ] && sleep "$(awk -v r="${rem}" 'BEGIN{printf "%.3f", r/1e9}')"
  done
}

# --- one function per target -----------------------------------------------------------------------------------------
vcenter_token=""
p_vcenter() {
  if [ -z "${vcenter_token}" ]; then
    hit vcenter-login '200|201' -X POST -u "${vc_user}:${generic_password}" "https://${vc_host}/api/session"
    vcenter_token=$(tr -d '"' < "${body_file}" 2>/dev/null)
    [ "${#vcenter_token}" -eq 32 ] || { vcenter_token=""; return; }
  fi
  # the namespace-management service is the one the Supervisor depends on; the appliance version call is the cheap base check
  hit vcenter '200' -H "vmware-api-session-id: ${vcenter_token}" "https://${vc_host}/api/appliance/system/version"
  [[ "$(tail -n1 "${samples}" | cut -d'|' -f3)" =~ ^(401|403)$ ]] && vcenter_token=""
}
p_nsx() {
  hit nsx '200' -u "admin:${generic_password}" "https://${nsx_host}/api/v1/cluster/status"
}
avi_csrf=""; avi_ver="${avi_version:-}"
p_avi() {
  if [ -z "${avi_csrf}" ]; then
    [ -z "${avi_ver}" ] && avi_ver=$("${CURL[@]}" "https://${avi_host}/api/initial-data" 2>/dev/null | jq -r '.version.Version // empty')
    rm -f "${out}/.avi.cookies"
    "${CURL[@]}" -X POST -H 'Content-Type: application/json' -c "${out}/.avi.cookies" \
      -d "{\"username\":\"admin\",\"password\":\"${generic_password}\"}" "https://${avi_host}/login" > /dev/null 2>&1
    avi_csrf=$(awk '$6=="csrftoken"{print $7}' "${out}/.avi.cookies" 2>/dev/null)
    [ -z "${avi_csrf}" ] && { rec avi-login 000 5.000 'x'; return; }
  fi
  hit avi '200' -b "${out}/.avi.cookies" -H "X-CSRFToken: ${avi_csrf}" -H "X-Avi-Tenant: admin" -H "X-Avi-Version: ${avi_ver:-22.1.4}" \
    -H "Referer: https://${avi_host}" "https://${avi_host}/api/cluster/runtime"
  [[ "$(tail -n1 "${samples}" | cut -d'|' -f3)" =~ ^(401|403|419)$ ]] && avi_csrf=""
}
vcfa_tok=""
vcfa_provider_login() { # sets vcfa_tok; records a vcfa-system-login sample
  local r t
  t0l=$(date +%s.%N)
  r=$("${CURL[@]}" -m 10 -i -X POST "https://${vcfa_host}/cloudapi/1.0.0/sessions/provider" \
    -H "Accept: application/json;version=${vcfa_ver}" -H "Content-Type: application/json;version=${vcfa_ver}" \
    -H "Authorization: Basic $(printf '%s' "admin@system:${generic_password}" | base64 -w0)" 2>/dev/null)
  vcfa_tok=$(printf '%s' "${r}" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
  rec "${1:-vcfa-system-login}" "$([ -n "${vcfa_tok}" ] && echo 200 || echo "$(printf '%s' "${r}" | head -1 | awk '{print $2}')")" "$(awk -v a="${t0l}" -v b="$(date +%s.%N)" 'BEGIN{printf "%.3f", b-a}')" '200'
  [ -n "${vcfa_tok}" ]
}
p_vcfa_system() {
  [ -z "${vcfa_tok}" ] && { vcfa_provider_login || return; }
  hit vcfa-system '200' -H "Accept: application/json;version=${vcfa_ver}" -H "Authorization: Bearer ${vcfa_tok}" \
    "https://${vcfa_host}/cloudapi/1.0.0/orgs?pageSize=1"
  [[ "$(tail -n1 "${samples}" | cut -d'|' -f3)" == "401" ]] && vcfa_tok=""
}
org_tok=""
p_vcfa_org() {
  if [ -z "${org_tok}" ]; then
    local r t0l
    t0l=$(date +%s.%N)
    r=$("${CURL[@]}" -m 10 -i -X POST "https://${vcfa_host}/cloudapi/1.0.0/sessions" \
      -H "Accept: application/json;version=${vcfa_ver}" \
      -H "Authorization: Basic $(printf '%s' "${first_org}@${first_org}:${org_pw}" | base64 -w0)" 2>/dev/null)
    org_tok=$(printf '%s' "${r}" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
    rec vcfa-org-login "$([ -n "${org_tok}" ] && echo 200 || echo "$(printf '%s' "${r}" | head -1 | awk '{print $2}')")" \
      "$(awk -v a="${t0l}" -v b="$(date +%s.%N)" 'BEGIN{printf "%.3f", b-a}')" '200'
    [ -z "${org_tok}" ] && return
  fi
  hit vcfa-org '200' -H "Accept: application/json;version=${vcfa_ver}" -H "Authorization: Bearer ${org_tok}" \
    "https://${vcfa_host}/cloudapi/1.0.0/sessions/current"
  [[ "$(tail -n1 "${samples}" | cut -d'|' -f3)" == "401" ]] && org_tok=""
}
# org portal's Kubernetes-style API (what the VKS/namespace automation uses): provider token -> org-scoped OIDC token -> CCI call
cci_tok=""; cci_ptok=""; cci_client=""; cci_uuid=""
p_vcfa_org_cci() {
  local r
  if [ -z "${cci_tok}" ]; then
    local H=(-H "Accept: application/json;version=${vcfa_ver}")
    r=$("${CURL[@]}" -m 10 -i -X POST "https://${vcfa_host}/cloudapi/1.0.0/sessions/provider" "${H[@]}" \
      -H "Authorization: Basic $(printf '%s' "admin@system:${generic_password}" | base64 -w0)" 2>/dev/null)
    cci_ptok=$(printf '%s' "${r}" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
    [ -z "${cci_ptok}" ] && { rec vcfa-org-cci 000 5.000 'x'; return; }
    cci_client=$("${CURL[@]}" "${H[@]}" -H "Authorization: Bearer ${cci_ptok}" "https://${vcfa_host}/cloudapi/1.0.0/openIdProvider/relyingParties" \
      | jq -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
    cci_uuid=$("${CURL[@]}" "${H[@]}" -H "Authorization: Bearer ${cci_ptok}" "https://${vcfa_host}/cloudapi/1.0.0/orgs?filter=name==${first_org}" \
      | jq -r '.values[0].id // empty'); cci_uuid="${cci_uuid##*:}"
    cci_tok=$("${CURL[@]}" -m 10 -X POST "https://${vcfa_host}/oidc/oauth2/token" "${H[@]}" -H "x-vmware-vcloud-tenant-context: ${cci_uuid}" \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" --data-urlencode "scope=openid profile email phone groups vcd_idp" \
      --data-urlencode "assertion=${cci_ptok}" --data-urlencode "client_id=${cci_client}" | jq -r '.access_token // empty')
    [ -z "${cci_tok}" ] && { rec vcfa-org-cci 000 5.000 'x'; return; }
  fi
  hit vcfa-org-cci '200' -H "Authorization: Bearer ${cci_tok}" -H "Accept: application/json" \
    "https://${vcfa_host}/cci/kubernetes/apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/default-project/supervisornamespaces"
  [[ "$(tail -n1 "${samples}" | cut -d'|' -f3)" =~ ^(401|403)$ ]] && cci_tok=""
}
p_vcfa_ui() { hit vcfa-ui '200|30[0-9]|401|403' "https://${vcfa_host}/"; }
sup_ep=""
p_supervisor() {
  if [ -z "${sup_ep}" ]; then
    local tok cid
    tok=$("${CURL[@]}" -X POST -u "${vc_user}:${generic_password}" "https://${vc_host}/api/session" | tr -d '"')
    cid=$("${CURL[@]}" -H "vmware-api-session-id: ${tok}" "https://${vc_host}/api/vcenter/namespace-management/clusters" | jq -r '.[0].cluster // empty')
    [ -n "${cid}" ] && sup_ep=$("${CURL[@]}" -H "vmware-api-session-id: ${tok}" "https://${vc_host}/api/vcenter/namespace-management/clusters/${cid}" | jq -r '.api_server_cluster_endpoint // empty')
    [ -z "${sup_ep}" ] && { rec supervisor 000 5.000 'x'; return; }
    mlog "supervisor endpoint ${sup_ep}"
  fi
  # anonymous readiness of the Supervisor's Kubernetes API (401/403 = answered but anonymous access is off: still reachable)
  hit supervisor '200|401|403' "https://${sup_ep}:6443/readyz"
}
p_installer() { hit installer '200|30[0-9]|401|403' "https://${ip_vcf_installer}/"; }
p_vault() { hit vault '200|429' "https://127.0.0.1:8200/v1/sys/health"; }
p_harbor() { hit harbor '200' "https://harbor.${sub}.${domain}/api/v2.0/health"; }
p_git() { hit git '200' "https://${git_fqdn_prefix}.${sub}.${domain}/api/healthz"; }
p_vcd() { hit vcd '200' "https://${vcd_host}/api/versions"; }
dns_probe() { # target server name
  local t0l r
  t0l=$(date +%s.%N)
  r=$(dig +time=2 +tries=1 +short "@${2}" "${3}" 2>/dev/null)
  rec "$1" "$([ -n "${r}" ] && echo 200 || echo 000)" "$(awk -v a="${t0l}" -v b="$(date +%s.%N)" 'BEGIN{printf "%.3f", b-a}')" '200'
}
p_dns_gw() { dns_probe dns-gw 127.0.0.1 "${vc_host}"; }
p_dns_avi() { dns_probe dns-avi "${ip_avi_dns}" "harbor.${sub}.${domain}"; }

# --- start the loops (skip targets without an address) ---------------------------------------------------------------
pids=()
start() { # name function [reason to skip when empty: value]
  if [ -z "$3" ] && [ $# -ge 3 ]; then mlog "skipped ${1}: address not known"; return; fi
  loop "$1" "$2" &
  pids+=($!)
}
mlog "api-monitor: ${duration}s, every ${interval}s, output ${out}"
start vcenter      p_vcenter       "${vc_host}"
start nsx          p_nsx           "${nsx_host}"
start avi          p_avi           "${avi_host}"
start vcfa-system  p_vcfa_system   "${vcfa_host}"
start vcfa-org     p_vcfa_org      "${first_org}"
start vcfa-org-cci p_vcfa_org_cci  "${first_org}"
start vcfa-ui      p_vcfa_ui       "${vcfa_host}"
start supervisor   p_supervisor    "${vc_host}"
start installer    p_installer     "${ip_vcf_installer}"
[ -x "$(command -v vault)" ] || [ -n "$(ss -ltn 2>/dev/null | grep ':8200 ')" ] && start vault p_vault "x"
start harbor       p_harbor        "${sub}"
start git          p_git           "${git_fqdn_prefix}${sub}"
start dns-gw       p_dns_gw        "x"
start dns-avi      p_dns_avi       "${ip_avi_dns}"
[ "${deployment_kind}" == "vApp" ] && start vcd p_vcd "${vcd_host}"
n=0
for ip in $(echo "${ips_esxi:-[]}" | jq -r '.[]'); do
  n=$((n+1))
  eval "p_esxi${n}() { hit esxi-${n} '200|30[0-9]' 'https://${ip}/'; }"
  start "esxi-${n}" "p_esxi${n}" "${ip}"
done
mlog "started ${#pids[@]} probes"

stop_all() { kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; }
trap 'mlog "interrupted, writing the report"; stop_all; make_report "${out}" > /dev/null; mlog "report: ${out}/report.md"; exit 0' INT TERM
wait
make_report "${out}"
mlog "report: ${out}/report.md"
