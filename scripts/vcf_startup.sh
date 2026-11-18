#!/bin/bash
#
# Ordered, gated START of the nested VCF platform after a shutdown, run ON THE GW (both use cases). It is the counterpart of vcf_shutdown.sh and follows the
# order of the first real cold start of the SDDC lab (2026-11-16, SHUTDOWN-STARTUP-RECIPE.md section 4) with the corrections made by hand during that run.
#
#   vcf_startup.sh <deployment json> [--dry-run] [--from <phase> | --only <phase>] [--auto] [--force] [--no-orgs] [--vcfa-wait-minutes N]
#
# vApp: VCD starts the vApp by its Start/Stop order (the gw first, the ESX hosts about 2 minutes later); this script then starts what is inside the hosts.
# It is meant to run by itself after every boot of the gw (--auto, from the @reboot cron entry installed by the finish phase), and by hand or through the
# diagnostics channel (startup-platform) otherwise.
#
# Phases (each prints what it found; the exit code of a phase goes to the status file; every phase is safe to run again):
#   identify      this gw is the vApp it thinks it is: its direct IP is the one of the spec (otherwise exit 4: the students' tunnels point at that IP, nothing is
#                 started), the vApp is found in VCD by that IP (a vApp made from a template has its own uuid, and the name it was given is written to
#                 .vcd.vapp of the deployment json, which the other scripts use to find the VMs), ready_for_poweroff goes back to false
#   gw            what the gw itself serves: bind9, chrony, wg-quick@wg0, DNS answers, Vault active and unsealed (the vault.service ExecStartPost=+ fix is applied when missing)
#   hosts         the ESX VMs are on (VCD already started them; any that is off is started), https on every host, vSAN: members healthy, resync
#   vcenter       powered on DIRECTLY from the host that holds it (no vCenter yet); REST login, then /sdk (503 for about a minute after the login works), hosts connected
#   nsx           manager(s) on, cluster STABLE polled on the NODE ip (the VIP comes later); then the edges, put back on the host they had before the shutdown
#                 (inventory-before.json), then the fabric: every edge and host transport node UP with 0 tunnels down
#   avi           THE GATE: nothing of Avi starts before the fabric is whole (an edge with its tunnels down made the controller create an extra SE on 2026-11-16).
#                 Then controller and service engines TOGETHER, controller API, service engines OPER_UP
#   avi-trust     NSX's Avi endpoint holds the certificate the controller serves (SDDC Manager registered the default portal certificate, replaced it 45 s later and never
#                 updated NSX; after a reboot the controller serves the new one and AKO crash-loops on x509). When they differ, the endpoint is saved and patched, then the
#                 supervisor phase waits for WCP to rewrite AKO's secret and restarts the AKO pods once
#   services      SDDC Manager and the VSP VMs together (VSP recovers by itself, 5480 answers), then VCF Operations and VCF Automation together (node Ready,
#                 vmsp-operator back to 1 if it is 0)
#   supervisor    WCP started, the Supervisor VM on (WCP does it; through its host when it did not), then WCP RESTARTED once Avi is up (WCP configured its load
#                 balancer before Avi answered and does not retry: AKO crash-looped on a missing avi-secret), until kubernetes=READY and the AKO pods Running
#   k8s-shared    the shared k8s VMs (control plane, then workers), Gitea answers
#   vcfa-wait     VCF Automation settled: no pod outside Running/Completed for 10 minutes (it took 1 h 15 to 3 h 30 on 2026-11-16; ceiling --vcfa-wait-minutes, default 240)
#   orgs          vcfa_org.sh add --all (the orgs that vcfa_org.sh delete --all removed); --no-orgs skips it
#   finish        ssh on the hosts stopped again, the VMs that were on before the shutdown are on, the shutdown inventory is moved aside (the next shutdown takes a
#                 new one), the cycle-complete marker is removed, the @reboot entry is installed
#
# --auto     for the cron entry: starts only when vcf_shutdown.sh finished a cycle (platform-state/cycle-complete) and ~/.no-autostart does not exist
# --force    skips nothing of the gates; it only lets a run start without the cycle-complete marker (a hand start of a platform that was not shut down by the script)
# --dry-run  changes nothing: discovery and the guards still run, every action is printed as "[dry-run] would: ..."; waits are not performed
# Status: /home/ubuntu/json/vcf_startup_status.json (same shape as vcf_shutdown_status.json), log: /home/ubuntu/vcf_startup.log.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jsonFile="$(readlink -f "${1:-}" 2> /dev/null)"
[ -f "${jsonFile}" ] || { echo "usage: vcf_startup.sh <deployment json> [--dry-run] [--from <phase> | --only <phase>] [--auto] [--force] [--no-orgs] [--vcfa-wait-minutes N]" >&2; exit 1; }
shift
dry_run="false"; start_from=""; only_phase=""; auto="false"; force="false"; no_orgs="false"; vcfa_wait_minutes=240
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run="true"; shift ;;
    --from) start_from="${2:?--from needs a phase}"; shift 2 ;;
    --only) only_phase="${2:?--only needs a phase}"; shift 2 ;;
    --auto) auto="true"; shift ;;
    --force) force="true"; shift ;;
    --no-orgs) no_orgs="true"; shift ;;
    --vcfa-wait-minutes) vcfa_wait_minutes="${2:?--vcfa-wait-minutes needs a number}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "${vcfa_wait_minutes}" in ''|*[!0-9]*) echo "--vcfa-wait-minutes is a whole number" >&2; exit 1 ;; esac

cd /home/ubuntu || exit 1
mkdir -p /home/ubuntu/json /home/ubuntu/platform-state
state_dir=/home/ubuntu/platform-state
log_file=/home/ubuntu/vcf_startup.log
vcf_status_file=/home/ubuntu/json/vcf_startup_status.json

# --auto: only after a cycle that vcf_shutdown.sh finished, and never when the kill switch exists
if [ "${auto}" == "true" ]; then
  [ ! -e /home/ubuntu/.no-autostart ] || { echo "$(date +%H:%M:%S) vcf_startup --auto: ~/.no-autostart exists: not starting"; exit 0; }
  [ -e "${state_dir}/cycle-complete" ] || { echo "$(date +%H:%M:%S) vcf_startup --auto: no cycle-complete marker (the platform was not shut down by vcf_shutdown.sh): not starting"; exit 0; }
elif [ "${force}" != "true" ] && [ "${dry_run}" != "true" ] && [ -z "${only_phase}" ] && [ -z "${start_from}" ] && [ ! -e "${state_dir}/cycle-complete" ]; then
  echo "no cycle-complete marker in ${state_dir}: vcf_shutdown.sh did not finish a cycle on this gw. Use --force to start anyway (--dry-run, --from and --only never need it)." >&2; exit 5
fi
# one run at a time (a second one, the cron entry after a manual run, leaves quietly)
exec 9> "${state_dir}/.startup.lock"
flock -n 9 || { echo "$(date +%H:%M:%S) vcf_startup: another run holds the lock: exiting"; exit 0; }

source /home/ubuntu/bash/variables.sh < /dev/null
source "${script_dir}/functions.sh"
source "${script_dir}/vcf_status.sh"
for tool in govc jq curl sshpass flock; do command -v "${tool}" > /dev/null 2>&1 || { echo "ERROR: ${tool} is not installed" >&2; exit 1; }; done

say() { local m; m="$(date +%H:%M:%S) vcf_startup: $*"; echo "${m}"; echo "${m}" >> "${log_file}"; }
warn() { say "WARNING: $*"; }
die() { say "ERROR: $*"; exit "${2:-1}"; }
quiet() { "$@" > /dev/null 2>&1; }
act() { local d="$1"; shift; if [ "${dry_run}" == "true" ]; then say "[dry-run] would: ${d}"; return 0; fi; say "${d}"; "$@"; }
# wait_until <what> <ceiling s> <poll s> <command...>: the command (it may print one line, shown) is run until it succeeds; 0 = ok, 1 = ceiling reached
wait_until() {
  local d="$1" ceiling="$2" poll="$3" t0 out rc last; shift 3
  if [ "${dry_run}" == "true" ]; then out=$("$@" 2>&1); rc=$?; say "[dry-run] would wait (up to $(( ceiling / 60 )) min) until: ${d}; checked once now: $([ "${rc}" == "0" ] && echo ok || echo "not yet (rc ${rc})")${out:+ (${out})}"; return 0; fi
  t0=$(date +%s); last=${t0}
  while true; do
    out=$("$@" 2>&1); rc=$?
    [ "${rc}" == "0" ] && { say "  ${d}: ok after $(( $(date +%s) - t0 ))s${out:+ (${out})}"; return 0; }
    [ $(( $(date +%s) - t0 )) -ge "${ceiling}" ] && { say "  ${d}: NOT ok after ${ceiling}s${out:+ (${out})}"; return 1; }
    [ $(( $(date +%s) - last )) -ge 120 ] && { say "  ... ${d}: still waiting (${out:-no answer yet})"; last=$(date +%s); }
    sleep "${poll}"
  done
}

bn="${basename_sddc}"
pw="$(jq -r .generic_password "${jsonFile}")"
sso="$(jq -r '.sddc.vcenter.ssoDomain // "vsphere.local"' "${jsonFile}")"
vc_fqdn="${bn}-vc01.${domain}"
host_ips="$(echo "${ips_esxi}" | jq -r '.[]')"
[ -n "${host_ips}" ] || die "ips_esxi is empty: no hosts to work with"
n_hosts=$(echo "${host_ips}" | wc -w)
ip_avi=$(echo "${ips_avi}" | jq -r '.[0]')       # variables.sh only has the plural ips_avi, like the other phases
ip_nsx_node=$(echo "${ips_nsx}" | jq -r '.[0]')
git_fqdn="${git_fqdn_prefix}.${avi_subdomain}.${domain}"
: "${PAT_VCFA:=^${bn}-auto-platform}" "${PAT_VSP:=^${bn}-vsp01-}" "${PAT_SUPERVISOR:=^SupervisorControlPlaneVM}" "${PAT_K8S_SHARED:=^k8s-shared-}"
: "${PAT_AVI_SE:=^vcf_Avi-se-}" "${PAT_AVI_CTRL:=^${bn}-avi-node}" "${PAT_NSX_EDGE:=^edge-[0-9]}" "${PAT_NSX_MGR:=^${bn}-nsx[0-9]}"
: "${PAT_OPS:=^${bn}-(collector|ops[0-9]|license)}" "${PAT_SDDCM:=^${bn}-sddcm$}" "${PAT_VC:=^${bn}-vc01$}"
export SSHPASS="${pw}"
ssh_pw="-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o ConnectTimeout=15"

# ---- vCenter / host / VM helpers (govc), the same as vcf_shutdown.sh ---------------------------------------------------------------------
vc_env() { export GOVC_URL="${vc_fqdn}" GOVC_USERNAME="administrator@${sso}" GOVC_PASSWORD="${pw}" GOVC_INSECURE=1; unset GOVC_DATACENTER; }
host_env() { export GOVC_URL="https://${1}" GOVC_USERNAME=root GOVC_PASSWORD="${pw}" GOVC_INSECURE=1; unset GOVC_DATACENTER; }
vc() { ( vc_env; "$@" ); }
onhost() { local ip="$1"; shift; ( host_env "${ip}"; "$@" ); }
vm_paths() { local re="$1" ip="${2:-}"; local f; if [ -n "${ip}" ]; then f=onhost; set -- "${ip}"; else f=vc; set --; fi
  "${f}" "$@" govc find / -type m 2> /dev/null | while IFS= read -r p; do [[ "$(basename "${p}")" =~ ${re} ]] && echo "${p}"; done; }
vm_power() { local p="$1" ip="${2:-}"; if [ -n "${ip}" ]; then onhost "${ip}" govc vm.info -json "${p}" 2> /dev/null; else vc govc vm.info -json "${p}" 2> /dev/null; fi | jq -r '.virtualMachines[0].runtime.powerState // "unknown"'; }
vc_alive() { vc govc about > /dev/null 2>&1; }
# start_group <label> <regex> [host ip]: powers on every VM whose name matches and is not on (through the vCenter, or the host given); the task is waited for by govc
start_group() {
  local label="$1" re="$2" ip="${3:-}" p n=0 started=0
  while IFS= read -r p; do [ -n "${p}" ] || continue; n=$((n + 1))
    if [ "$(vm_power "${p}" "${ip}")" == "poweredOn" ]; then say "  ${label}: $(basename "${p}") already on"; continue; fi
    started=$((started + 1))
    if [ "${dry_run}" == "true" ]; then say "[dry-run] would: power on $(basename "${p}")"; continue; fi
    say "  ${label}: power on $(basename "${p}")"
    if [ -n "${ip}" ]; then onhost "${ip}" govc vm.power -on "${p}" > /dev/null 2>&1 || warn "power on of $(basename "${p}") failed"; else vc govc vm.power -on "${p}" > /dev/null 2>&1 || warn "power on of $(basename "${p}") failed"; fi
  done < <(vm_paths "${re}" "${ip}")
  [ "${n}" == "0" ] && say "  ${label}: no VM matches ${re}$([ "${dry_run}" == "true" ] && ! vc_alive && echo " (the vCenter does not answer, normal before the vcenter phase)")"
  return 0
}

# ---- platform layer: the ESX host VMs live OUTSIDE the nested vCenter: sddc = underlay vCenter, vApp = VCD ------------------------------------
if [ "${deployment_kind}" == "vApp" ]; then
  vcd_login
  plat_name_host() { echo "${bn}-mgmt-esx0${1}"; }
  plat_state() { local resp; resp=$(curl -sk "https://${vcd_host}/api/query?type=vm&format=records&pageSize=128$(vcd_vm_filter "$1")" -H "Authorization: Bearer ${vcd_auth_token}" -H "Accept: application/*+json;version=${vcd_api_version}")
    case "$(echo "${resp}" | jq -r --arg n "$1" '[.record[]? | select(.name == $n) | .status][0] // "missing"')" in POWERED_ON) echo poweredOn ;; POWERED_OFF) echo poweredOff ;; *) echo unknown ;; esac; }
  plat_power_on() { local h; h=$(vcd_find_vm_href "$1"); [ -n "${h}" ] && curl -sk -X POST "${h}/power/action/powerOn" -H "Authorization: Bearer ${vcd_auth_token}" -H "Accept: application/*+xml;version=${vcd_api_version}" > /dev/null; }
else
  plat_env() { export GOVC_URL="${vsphere_underlay_vcsa}" GOVC_USERNAME="${vsphere_underlay_username}" GOVC_PASSWORD="${vsphere_underlay_password}" GOVC_DATACENTER="${vsphere_underlay_datacenter}" GOVC_INSECURE=1; }
  plat_name_host() { echo "${bn}-mgmt-esx0${1}"; }
  plat_state() { ( plat_env; p=$(govc find / -type m -name "$1" | head -1); [ -n "${p}" ] && govc vm.info -json "${p}" | jq -r '.virtualMachines[0].runtime.powerState' || echo unknown ); }
  plat_power_on() { ( plat_env; p=$(govc find / -type m -name "$1" | head -1); govc vm.power -on "${p}" > /dev/null 2>&1 ); }
fi

# ---- checks used by the waits ----------------------------------------------------------------------------------------------------------------
host_https() { [ "$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://${1}/")" == "200" ]; }
vsan_ok() {   # every host: the same member count, HEALTHY (the count is logged; a count other than the number of hosts is only a warning)
  local ip out m h first=""
  for ip in ${host_ips}; do
    out=$(onhost "${ip}" govc host.esxcli vsan cluster get 2>&1)
    m=$(echo "${out}" | awk -F': *' '{k = tolower($1); gsub(/[- ]/, "", k)} k == "subclustermembercount" {print $2; exit}'); h=$(echo "${out}" | awk -F': *' '{k = tolower($1); gsub(/[- ]/, "", k)} k == "localnodehealthstate" {print $2; exit}')
    [ -n "${m}" ] && [ "${h}" == "HEALTHY" ] || { echo "${ip}: members=${m:-?} health=${h:-?}"; return 1; }
    [ -z "${first}" ] && first="${m}"; [ "${m}" == "${first}" ] || { echo "${ip}: members=${m}, another host says ${first}"; return 1; }
  done
  echo "${first} members, HEALTHY on every host"; [ "${first}" == "${n_hosts}" ] || echo "(the spec has ${n_hosts} hosts)"
}
vsan_resync_zero() {
  local ip out n
  for ip in ${host_ips}; do
    out=$(onhost "${ip}" govc host.esxcli vsan debug resync summary get 2>&1); n=$(echo "${out}" | awk -F': *' '{k = tolower($1); gsub(/[- ]/, "", k)} k ~ /numberofresyncingobjects|objectsresyncing/ {print $2; exit}')
    case "${n}" in ''|*[!0-9]*) echo "no resync counter in the answer of ${ip}, taken as 0"; continue ;; esac
    [ "${n}" == "0" ] || { echo "${ip}: ${n} object(s) resyncing"; return 1; }
  done
  echo "0 objects resyncing"
}
vc_rest_ok() { [ "$(curl -sk -m 15 -o /dev/null -w '%{http_code}' -X POST -u "administrator@${sso}:${pw}" "https://${vc_fqdn}/api/session")" == "201" ]; }
vc_host_table() { local hp; for hp in $(vc govc find / -type h 2> /dev/null); do vc govc host.info -json "${hp}" 2> /dev/null | jq -c '.hostSystems[]? | {moref: .self.value, name: .name, state: .runtime.connectionState}'; done; }   # one line per host (govc host.info without a path fails with several hosts)
vc_hosts_connected() { local n; n=$(vc_host_table | jq -s '[.[] | select(.state == "connected")] | length'); [ "${n:-0}" -ge "${n_hosts}" ] && echo "${n} connected" || { echo "${n:-0}/${n_hosts} connected"; return 1; }; }
nsx_get() { curl -sk -m 15 -u "admin:${pw}" "https://${ip_nsx_node}/$1"; }
nsx_stable() { local s; s=$(nsx_get api/v1/cluster/status | jq -r '.mgmt_cluster_status.status // "?"'); [ "${s}" == "STABLE" ] && echo "STABLE" || { echo "${s}"; return 1; }; }
fabric_ok() {   # NSX manager STABLE, every edge and host transport node UP with no tunnel down; prints why not when it is not
  local t id name st down n=0 bad=""
  nsx_stable > /dev/null || { echo "NSX manager cluster not STABLE"; return 1; }
  for t in HostNode EdgeNode; do
    for id in $(nsx_get "api/v1/transport-nodes?node_types=${t}" | jq -r '.results[]?.node_id'); do
      IFS=$'\t' read -r name st down < <(nsx_get "api/v1/transport-nodes/${id}/status" | jq -r '[(.node_display_name // "?"), (.status // "?"), (.tunnel_status.down_count // 0)] | @tsv')
      n=$((n + 1)); { [ "${st}" == "UP" ] && [ "${down}" == "0" ]; } || bad="${bad} ${name}=${st}/down=${down}"
    done
  done
  [ "${n}" -gt 0 ] || { echo "no transport node listed yet"; return 1; }
  [ -z "${bad}" ] || { echo "not UP:${bad}"; return 1; }
  echo "${n} transport nodes UP, 0 tunnels down"
}
avi_ctrl_up() { [ "$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://${ip_avi}/api/initial-data")" == "200" ]; }
avi_get() { local v; v=$(curl -sk -m 20 "https://${ip_avi}/api/initial-data" | jq -r '.version.Version // empty'); curl -sk -m 25 -b /tmp/avi_cookies.txt -H "X-CSRFToken: ${avi_csrftoken}" -H "X-Avi-Tenant: *" -H "X-Avi-Version: ${v}" -H "Referer: https://${ip_avi}" "https://${ip_avi}/$1"; }
avi_ses_up() { local total bad; avi_login > /dev/null 2>&1; total=$(avi_get "api/serviceengine-inventory?page_size=50" | jq '[.results[]?] | length'); bad=$(avi_get "api/serviceengine-inventory?page_size=50" | jq '[.results[]? | select(.runtime.oper_status.state != "OPER_UP")] | length')
  [ "${total:-0}" -gt 0 ] && [ "${bad:-1}" == "0" ] && echo "${total} service engines OPER_UP" || { echo "${total:-0} SE(s), ${bad:-?} not OPER_UP"; return 1; }; }
vsp_cp_ip() {   # the VSP control-plane node: the one whose management API lists the components (a worker answers 404)
  local cand tok code p
  while IFS= read -r p; do [ -n "${p}" ] || continue; cand=$(vc govc vm.ip -wait 10s "${p}" 2> /dev/null); [ -n "${cand}" ] || continue
    tok=$(curl -sk -m 10 -X POST "https://${cand}:5480/api/v1/auth/login" -H "Content-Type: application/json" -d "{\"username\":\"vmware-system-user\",\"password\":\"${pw}\"}" 2> /dev/null | jq -r '.accessToken // .token // empty' 2> /dev/null)
    [ -n "${tok}" ] || continue
    code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${tok}" "https://${cand}:5480/api/v1/components" 2> /dev/null)
    [ "${code}" == "200" ] && { echo "${cand}"; return 0; }
  done < <(vm_paths "${PAT_VSP}")
  return 1
}
vsp_up() { local ip; ip=$(vsp_cp_ip) && echo "control-plane node ${ip} answers" || { echo "no VSP control-plane node answers on 5480"; return 1; }; }
vcfa_ip() { local p; p=$(vm_paths "${PAT_VCFA}" | head -1); [ -n "${p}" ] && vc govc vm.ip -wait 10s "${p}" 2> /dev/null; }
vcfa_run() {   # vcfa_run <node ip> <script text>: runs it as root on the VCF Automation node with the cluster's admin kubeconfig
  local ip="$1" rs; rs=$(mktemp); { echo 'export KUBECONFIG=/etc/kubernetes/super-admin.conf'; echo "$2"; } > "${rs}"
  sshpass -e scp ${ssh_pw} "${rs}" "vmware-system-user@${ip}:/tmp/vcf_startup_vcfa.sh" > /dev/null 2>&1
  sshpass -e ssh ${ssh_pw} "vmware-system-user@${ip}" "echo '${pw}' | sudo -S -i bash /tmp/vcf_startup_vcfa.sh" 2> /dev/null | grep -vE "^\[sudo\]|Welcome|^$"
  rm -f "${rs}"
}
vcfa_node_ready() { local ip n; ip=$(vcfa_ip); [ -n "${ip}" ] || { echo "no IP yet"; return 1; }; n=$(vcfa_run "${ip}" 'kubectl get nodes --no-headers 2>/dev/null | awk '"'"'$2 == "Ready"'"'"' | wc -l'); [ "${n:-0}" -ge 1 ] && echo "node ${ip} Ready" || { echo "node ${ip} not Ready"; return 1; }; }
wcp_ssh() { sshpass -e ssh ${ssh_pw} "root@${vc_fqdn}" "$1" 2>&1 | grep -vE "^\*\*|openssh|post-quantum|^$|^VMware vCenter|^Release|^Version|^Build|^Type|Shell access|Permanently"; }
sup_ready() {   # the Supervisor as WCP sees it (config RUNNING, kubernetes READY) and the AKO pods Running
  local tok cid st n bad
  tok=$(curl -sk -m 20 -X POST -u "administrator@${sso}:${pw}" "https://${vc_fqdn}/api/session" | tr -d '"')
  cid=$(curl -sk -m 20 -H "vmware-api-session-id: ${tok}" "https://${vc_fqdn}/api/vcenter/namespace-management/clusters" | jq -r '.[0].cluster // empty')
  [ -n "${cid}" ] || { echo "no Supervisor cluster listed"; return 1; }
  st=$(curl -sk -m 20 -H "vmware-api-session-id: ${tok}" "https://${vc_fqdn}/api/vcenter/namespace-management/clusters/${cid}" | jq -r '"\(.config_status // "?")/\(.kubernetes_status // "?")"')
  [ "${st}" == "RUNNING/READY" ] || { echo "config/kubernetes status ${st}"; return 1; }
  bash /home/ubuntu/supervisor/auth_supervisor_custer.sh > /dev/null 2>&1
  n=$(kubectl --context sup-admin-01 -n vmware-system-ako get pods --no-headers 2> /dev/null | wc -l); bad=$(kubectl --context sup-admin-01 -n vmware-system-ako get pods --no-headers 2> /dev/null | awk '$3 != "Running"' | wc -l)
  [ "${n}" -gt 0 ] && [ "${bad}" == "0" ] && echo "Supervisor RUNNING/READY, ${n} AKO pods Running" || { echo "Supervisor ${st}, AKO pods: ${n} listed, ${bad} not Running"; return 1; }
}
vault_ok() { [ "$(curl -sk -m 8 -o /dev/null -w '%{http_code}' https://127.0.0.1:8200/v1/sys/health)" == "200" ]; }
sup_vm_on() { local p; p=$(vm_paths "${PAT_SUPERVISOR}" | head -1); [ -n "${p}" ] && [ "$(vm_power "${p}")" == "poweredOn" ]; }
# ---- Avi trust: NSX's Avi endpoint (alb-endpoint) must hold the certificate the controller serves; AKO's avi-secret is written from it ----------
# Found on 2026-11-18: SDDC Manager registered Avi in NSX with the default portal certificate, replaced the portal certificate 45 s later and never updated the
# endpoint; the controller only started to serve the new one after a reboot, and AKO (pinned to the old one) crash-looped with "x509: certificate signed by unknown authority".
nsx_alb_url() { echo "https://${ip_nsx_node}/policy/api/v1/infra/sites/default/enforcement-points/alb-endpoint"; }
served_cert_pem() { echo | openssl s_client -connect "${1}:${2:-443}" -servername "${1}" 2> /dev/null | openssl x509 2> /dev/null; }   # the leaf the controller presents now
cert_fp() { openssl x509 -noout -fingerprint -sha256 2> /dev/null | sed 's/.*=//'; }   # PEM on stdin
cert_line() { openssl x509 -noout -subject -dates 2> /dev/null | paste -sd ' ' -; }   # PEM on stdin
sup_get_creds() {   # SUPIP / SUPPW: the Supervisor control plane and its root password, from the vCenter; the password is never printed
  local out; out=$(wcp_ssh_raw 'shell /usr/lib/vmware-wcp/decryptK8Pwd.py' | awk '/^IP:/ {ip=$2} /^PWD:/ {p=$2} END {print ip, p}')
  read -r SUPIP SUPPW <<< "${out}"; [ -n "${SUPIP}" ] && [ -n "${SUPPW}" ]
}
sup_creds_wait() { local t0; t0=$(date +%s); while ! sup_get_creds; do [ $(( $(date +%s) - t0 )) -ge 900 ] && return 1; sleep 30; done; }   # in this shell: wait_until runs its check in a subshell and would lose SUPIP/SUPPW
wcp_ssh_raw() { sshpass -e ssh ${ssh_pw} "root@${vc_fqdn}" "$1" 2> /dev/null; }
sup_run() { SSHPASS="${SUPPW}" sshpass -e ssh ${ssh_pw} "root@${SUPIP}" "export KUBECONFIG=/etc/kubernetes/admin.conf; $1" 2>&1 | grep -vE "pq.html|post-quantum|^\*\*|banner"; }
avi_secret_trusts() {   # the CA in AKO's avi-secret verifies the certificate the controller serves (a pinned leaf or its CA both count)
  local addr="${1}" served ca rc
  served=$(mktemp); ca=$(mktemp)
  served_cert_pem "${addr}" > "${served}"
  sup_run 'kubectl -n vmware-system-ako get secret avi-secret -o jsonpath="{.data.certificateAuthorityData}" | base64 -d' > "${ca}"
  if [ -s "${served}" ] && openssl verify -partial_chain -CAfile "${ca}" "${served}" > /dev/null 2>&1; then rc=0; echo "avi-secret trusts the served certificate"
  else rc=1; echo "avi-secret CA: $(cert_line < "${ca}" | cut -c1-110)"; fi
  rm -f "${served}" "${ca}"; return "${rc}"
}
ako_diagnose() {   # why the AKO pods do not come up, from their own logs: one line per cause found
  local out; out=$(sup_run 'N=vmware-system-ako; for p in $(kubectl -n $N get pods --no-headers | awk "{print \$1}"); do kubectl -n $N logs $p --all-containers --tail=60 2>&1; done' | sed 's/\x1b\[[0-9;]*m//g')
  echo "${out}" | grep -q "x509: certificate signed by unknown authority" && say "AKO diagnosis: TLS trust: the controller's certificate is not the one AKO holds (phase avi-trust repairs NSX's copy; the Supervisor side needs its secret refreshed)"
  echo "${out}" | grep -q "HTTP code: 423" && say "AKO diagnosis: the Avi account is locked after failed logins (Avi unlocks it by itself after about 5 minutes; do not restart the AKO pods meanwhile, every restart is another login attempt)"
  echo "${out}" | grep -qE "HTTP code: 401|authentication failed|invalid token" && say "AKO diagnosis: the Avi login is refused (expired token or password of ${AVI_SA:-nsxt-alb}): re-onboard Avi in NSX or reset that user in Avi"
  return 0
}
gitea_up() { [ "$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://${git_fqdn}/")" == "200" ]; }

# ---- the phases ------------------------------------------------------------------------------------------------------------------------------
phases="identify gw hosts vcenter nsx avi avi-trust services supervisor k8s-shared vcfa-wait orgs finish"

phase_identify() {
  local running resp rec name uuid old_uuid cur
  # nothing else is running (a shutdown, a bootstrap, an org command)
  running=$(ps -eo args | grep -E "^bash .*/(vcf_bootstrap|vcf_shutdown|vcfa_org|vcfa_tenant_bootstrap|vcfa_provider_bootstrap|vcfa_tenant_cleaning)\.sh" | grep -v grep | head -1)
  [ -z "${running}" ] || { say "something else is running: ${running}"; return 1; }
  if [ "${deployment_kind}" == "vApp" ] && [ -n "${ip_gw_direct}" ]; then
    # the IP the students' WireGuard tunnels point at: a start on another one would be a platform nobody can reach, so nothing is started
    if ! ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "${ip_gw_direct}"; then
      say "IP MISMATCH: this gw does not hold ${ip_gw_direct} (the direct IP of the spec); it holds: $(ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | tr '\n' ' ')"
      say "delete this vApp and instantiate the template again with the gw NIC on ${ip_gw_direct} (Manual IP): nothing was started"
      return 4
    fi
    say "this gw holds ${ip_gw_direct}, the direct IP of the spec"
    # which vApp is this: the gw VM whose IP is ours, in a vApp (not the template that holds the same address)
    resp=$(curl -sk "https://${vcd_host}/api/query?type=vm&format=records&pageSize=128&filter=(name==gw)" -H "Authorization: Bearer ${vcd_auth_token}" -H "Accept: application/*+json;version=${vcd_api_version}")
    rec=$(echo "${resp}" | jq -c --arg ip "${ip_gw_direct}" '[.record[]? | select((.container // "") | test("/vapp-")) | select(.ipAddress == $ip)][0] // empty')
    [ -n "${rec}" ] || { say "VCD lists no vApp whose gw VM has ${ip_gw_direct}: cannot tell which vApp this is"; return 1; }
    name=$(echo "${rec}" | jq -r '.containerName'); uuid=$(echo "${rec}" | jq -r '.container | sub(".*/vapp-"; "")')
    say "this is vApp '${name}' (uuid ${uuid})"
    cur=$(jq -r '.vcd.vapp // empty' "${jsonFile}")
    if [ "${cur}" != "${name}" ]; then
      act "write the vApp name '${name}' to .vcd.vapp of ${jsonFile} (it said '${cur}': the vApp was made from a template under another name)" quiet bash -c "cp -n '${jsonFile}' '${jsonFile}.pre-vapp-name' ; jq --arg v '${name}' '.vcd.vapp = \$v' '${jsonFile}' > '${jsonFile}.tmp' && mv -f '${jsonFile}.tmp' '${jsonFile}'"
      [ "${dry_run}" == "true" ] || { vcd_vapp="${name}"; vcd_login; }
    fi
    old_uuid=$(cat "${state_dir}/vapp-uuid" 2> /dev/null)
    if [ "${old_uuid}" != "${uuid}" ]; then say "a new vApp uuid (before: ${old_uuid:-none}): this gw runs from a copy of a template; the old status and command files are history, not state"; fi
    [ "${dry_run}" == "true" ] || echo "${uuid}" > "${state_dir}/vapp-uuid"
  fi
  # the platform is being started: it is not ready for a power-off any more (the operator reads this flag)
  [ "${dry_run}" == "true" ] || ( vcf_status_file=/home/ubuntu/json/vcf_shutdown_status.json; vcf_status_update '.ready_for_poweroff = false | .ready_at = null' )
  return 0
}

phase_gw() {
  local svc bad=0 d vstat
  for svc in bind9 chrony wg-quick@wg0; do
    if [ "$(systemctl is-active "${svc}" 2> /dev/null)" == "active" ]; then say "  ${svc}: active"; else warn "${svc} is $(systemctl is-active "${svc}" 2> /dev/null)"; bad=1; fi
  done
  say "  chrony: $(chronyc tracking 2> /dev/null | awk -F': *' '/Leap status/ {print $2}')"
  d=$(dig +short +time=3 +tries=1 @127.0.0.1 "${vc_fqdn}" 2> /dev/null | head -1)
  if [ -n "${d}" ]; then say "  DNS answers: ${vc_fqdn} = ${d}"; else warn "DNS (127.0.0.1) does not answer for ${vc_fqdn}"; bad=1; fi
  # Vault: after a gw reboot it failed once because the ExecStartPost helper is root:700 and the unit runs as the vault user (203/EXEC); '=+' makes it privileged
  if [ -d /etc/systemd/system/vault.service.d ] && ! grep -qs 'ExecStartPost=+' /etc/systemd/system/vault.service.d/unseal.conf 2> /dev/null; then
    act "fix the Vault drop-in: ExecStartPost=+/usr/local/bin/vault-unseal.sh" bash -c "printf '[Service]\nExecStartPost=+/usr/local/bin/vault-unseal.sh\n' | sudo tee /etc/systemd/system/vault.service.d/unseal.conf > /dev/null; sudo systemctl daemon-reload"
  fi
  if [ "$(systemctl is-active vault 2> /dev/null)" != "active" ]; then act "start Vault (reset-failed, start)" bash -c "sudo systemctl reset-failed vault; sudo systemctl start vault"; fi
  wait_until "Vault answers health 200 (initialized, unsealed)" 180 10 vault_ok || { warn "Vault is not healthy: the per-org Vault logins of the orgs phase would be missing"; bad=1; }
  [ "${bad}" == "0" ]
}

phase_hosts() {
  local i=0 ip n
  for ip in ${host_ips}; do i=$((i + 1)); n="$(plat_name_host "${i}")"
    case "$(plat_state "${n}")" in poweredOn) say "  ${n}: on" ;; *) act "power on ${n} ($(plat_state "${n}"))" plat_power_on "${n}" ;; esac
  done
  for ip in ${host_ips}; do wait_until "host ${ip} answers on https" 900 10 host_https "${ip}" || return 1; done
  wait_until "vSAN healthy on every host" 900 15 vsan_ok || return 1
  wait_until "vSAN: nothing resyncing" 1800 30 vsan_resync_zero || warn "vSAN is still resyncing: going on, the platform tolerates it"
  return 0
}

phase_vcenter() {
  local ip hostip="" p
  if vc_alive; then say "the vCenter already answers: nothing to start"; return 0; fi
  for ip in ${host_ips}; do p=$(vm_paths "${PAT_VC}" "${ip}" | head -1); [ -n "${p}" ] && { hostip="${ip}"; break; }; done
  [ -n "${hostip}" ] || { say "the vCenter VM (${PAT_VC}) was not found on any host"; return 1; }
  say "the vCenter VM is on host ${hostip} ($(vm_power "${p}" "${hostip}"))"
  [ "$(vm_power "${p}" "${hostip}")" == "poweredOn" ] || act "power on the vCenter VM directly on ${hostip}" quiet onhost "${hostip}" govc vm.power -on "${p}"
  wait_until "vCenter REST login" 900 10 vc_rest_ok || return 1
  wait_until "vCenter /sdk answers" 600 10 vc_alive || return 1
  wait_until "all ${n_hosts} hosts connected in the vCenter" 900 15 vc_hosts_connected || return 1
}

phase_nsx() {
  local edges_tsv="${state_dir}/inventory-before.json" p want cur want_name host_table
  start_group "nsx manager" "${PAT_NSX_MGR}"
  wait_until "NSX manager cluster STABLE (node ${ip_nsx_node})" 1800 20 nsx_stable || return 1
  start_group "nsx edges" "${PAT_NSX_EDGE}"
  # the edges go back to the host they had before the shutdown (DRS put edge-02 on another host on 2026-11-16 and all its tunnels to the host TEPs were down; on its old host it was UP in 20 s)
  if [ -s "${edges_tsv}" ] && [ "${dry_run}" != "true" ]; then
    host_table=$(vc_host_table)
    while IFS= read -r p; do [ -n "${p}" ] || continue
      want=$(jq -r --arg n "$(basename "${p}")" '[.[] | select(.name == $n) | .host][0] // empty' "${edges_tsv}"); [ -n "${want}" ] || continue
      cur=$(vc govc vm.info -json "${p}" 2> /dev/null | jq -r '.virtualMachines[0].runtime.host.value // empty')
      [ "${cur}" == "${want}" ] && { say "  $(basename "${p}") is on its host from before the shutdown (${want})"; continue; }
      want_name=$(echo "${host_table}" | jq -r --arg m "${want}" 'select(.moref == $m) | .name' | head -1)
      [ -n "${want_name}" ] || { warn "no name for host ${want}: $(basename "${p}") stays on ${cur}"; continue; }
      say "  $(basename "${p}"): on ${cur}, was on ${want} (${want_name}): vMotion back"
      vc govc vm.migrate -host "${want_name}" "${p}" > /dev/null 2>&1 || warn "vMotion of $(basename "${p}") to ${want_name} failed"
    done < <(vm_paths "${PAT_NSX_EDGE}")
  else say "  edge placement: $([ "${dry_run}" == "true" ] && echo "[dry-run] would put the edges back on the hosts of ${edges_tsv}" || echo "no inventory-before.json: edges stay where DRS put them")"; fi
  wait_until "NSX fabric whole (edges and hosts UP, 0 tunnels down)" 1800 30 fabric_ok || return 1
}

phase_avi() {
  # THE GATE. Not satisfied = nothing of Avi starts (resume with --from avi)
  wait_until "the gate: NSX fabric whole" 1500 30 fabric_ok || { say "the gate is not satisfied: the Avi controller and service engines are NOT started (an Avi controller started before the fabric is whole creates an extra service engine)"; return 1; }
  start_group "avi controller" "${PAT_AVI_CTRL}"
  start_group "avi service engines" "${PAT_AVI_SE}"
  wait_until "Avi controller API answers (about 10 minutes)" 1800 30 avi_ctrl_up || return 1
  wait_until "Avi service engines OPER_UP" 1800 30 avi_ses_up || warn "not every Avi service engine is OPER_UP: going on, the Supervisor restart below needs the controller, not every SE"
  return 0
}

phase_avi_trust() {
  # NSX's alb-endpoint must carry the certificate the controller serves now. Same call that repaired 6-02 by hand on 2026-11-18 (PATCH with the new certificate and
  # the Avi admin credentials: NSX refuses a PATCH without connection_info.password). Nothing happens when they already match.
  local url ep addr served stored fp_s fp_n bak body http reply
  url="$(nsx_alb_url)"
  ep=$(curl -sk -m 30 -u "admin:${pw}" "${url}")
  if ! echo "${ep}" | jq -e '.connection_info' > /dev/null 2>&1; then
    [ "${dry_run}" == "true" ] && { say "[dry-run] NSX does not answer with an Avi endpoint now (the NSX manager is not up): would compare the stored and the served certificate"; return 0; }
    say "NSX has no Avi endpoint (alb-endpoint) or does not answer: nothing to check"; return 0
  fi
  addr=$(echo "${ep}" | jq -r '.connection_info.enforcement_point_address'); stored=$(echo "${ep}" | jq -r '.connection_info.certificate // empty')
  served=$(served_cert_pem "${addr}")
  [ -n "${served}" ] || { say "the Avi controller at ${addr} does not present a certificate"; return 1; }
  fp_s=$(echo "${served}" | cert_fp); fp_n=$(echo "${stored}" | cert_fp)
  if [ "${fp_s}" == "${fp_n}" ]; then say "NSX's Avi endpoint holds the certificate the controller serves at ${addr}: nothing to do ($(echo "${served}" | cert_line | cut -c1-90))"; return 0; fi
  say "MISMATCH at ${addr}: the controller serves   $(echo "${served}" | cert_line)"
  say "                       NSX's Avi endpoint holds $(echo "${stored}" | cert_line)"
  # what is patched in must be what the controller really serves, for this address, and valid
  echo "${served}" | openssl x509 -noout -ext subjectAltName 2> /dev/null | grep -q "${addr}" || { say "the served certificate does not list ${addr} in its subject alternative names: not touching NSX"; return 1; }
  echo "${served}" | openssl x509 -noout -checkend 0 > /dev/null 2>&1 || { say "the served certificate is expired: not touching NSX"; return 1; }
  if [ "${dry_run}" == "true" ]; then say "[dry-run] would: save the endpoint, PATCH its certificate (and username admin + the Avi admin password), read it back"; return 0; fi
  bak="${state_dir}/alb-endpoint.before-$(date +%Y%m%d%H%M%S).json"; echo "${ep}" > "${bak}"; say "saved the endpoint object to ${bak} (restore: PATCH its connection_info back, with the Avi admin password)"
  body=$(echo "${ep}" | AVIPW="${pw}" jq --arg p "${served}" '{resource_type, id, display_name, connection_info: (.connection_info | .certificate = $p | .username = "admin" | .password = env.AVIPW), _revision}')
  reply=$(echo "${body}" | curl -sk -m 90 -u "admin:${pw}" -X PATCH -H 'Content-Type: application/json' -d @- "${url}" -w '\n%{http_code}')
  http=$(echo "${reply}" | tail -1)
  [ "${http}" == "200" ] || { say "NSX refused the update (HTTP ${http}): $(echo "${reply}" | head -n -1 | jq -r '.error_message // empty' 2> /dev/null | cut -c1-200)"; return 1; }
  stored=$(curl -sk -m 30 -u "admin:${pw}" "${url}" | jq -r '.connection_info.certificate // empty')
  [ "$(echo "${stored}" | cert_fp)" == "${fp_s}" ] || { say "NSX answered 200 but the endpoint still holds another certificate"; return 1; }
  say "NSX's Avi endpoint now holds the served certificate ($(echo "${stored}" | cert_line | cut -c1-90)); WCP rewrites AKO's secret from it within about 10 minutes (the supervisor phase waits for that)"
}

phase_services() {
  start_group "sddc manager" "${PAT_SDDCM}"
  start_group "vsp" "${PAT_VSP}"
  wait_until "the VSP platform answers (it recovers by itself)" 1500 30 vsp_up || warn "the VSP platform does not answer yet: going on"
  start_group "operations" "${PAT_OPS}"
  start_group "vcf automation" "${PAT_VCFA}"
  wait_until "VCF Automation node Ready (about 5 minutes)" 1800 30 vcfa_node_ready || return 1
  if [ "${dry_run}" != "true" ]; then
    local ip rep; ip=$(vcfa_ip)
    rep=$(vcfa_run "${ip}" 'ns=$(kubectl get deploy -A --no-headers 2>/dev/null | awk '"'"'$2=="vmsp-operator" {print $1}'"'"' | head -1); [ -n "$ns" ] && kubectl get deploy vmsp-operator -n "$ns" -o jsonpath="{.spec.replicas}"')
    if [ "${rep}" == "0" ]; then act "vmsp-operator is at 0 replicas: scale to 1" vcfa_run "${ip}" 'ns=$(kubectl get deploy -A --no-headers | awk '"'"'$2=="vmsp-operator" {print $1}'"'"' | head -1); kubectl scale deployment vmsp-operator -n "$ns" --replicas=1'
    else say "  vmsp-operator replicas: ${rep:-unknown} (the platform restores it by itself)"; fi
  fi
}

phase_supervisor() {
  local st sup ip p
  st=$(wcp_ssh "shell vmon-cli -s wcp" | awk '/RunState/ {print $2}' | head -1)
  say "WCP RunState: ${st:-unknown}"
  [ "${st}" == "STARTED" ] || act "start WCP (shell vmon-cli -i wcp)" quiet wcp_ssh "shell vmon-cli -i wcp"
  # WCP powers the Supervisor VM on by itself; when it did not (it refuses power operations through the vCenter), through the host that holds it
  wait_until "the Supervisor VM is powered on" 900 30 sup_vm_on \
    || { for ip in ${host_ips}; do p=$(vm_paths "${PAT_SUPERVISOR}" "${ip}" | head -1); [ -n "${p}" ] && { act "power on the Supervisor VM through its host ${ip}" quiet onhost "${ip}" govc vm.power -on "${p}"; break; }; done; }
  # WCP configured its load balancer while Avi did not answer and does not retry: restart it now that Avi is up
  act "restart WCP once Avi is up (shell vmon-cli -r wcp)" quiet wcp_ssh "shell vmon-cli -r wcp"
  # AKO's avi-secret is rewritten by WCP from NSX's Avi endpoint (phase avi-trust): when its CA does not verify the controller's certificate yet, wait for the rewrite
  # and restart the AKO pods ONCE (each restart is another login attempt: after failed logins Avi locks the account for about 5 minutes)
  local avi_addr; avi_addr=$(curl -sk -m 30 -u "admin:${pw}" "$(nsx_alb_url)" | jq -r '.connection_info.enforcement_point_address // empty' 2> /dev/null)
  if [ "${dry_run}" == "true" ]; then say "[dry-run] would: read the Supervisor root access, wait until avi-secret's CA verifies the certificate served at ${avi_addr:-the Avi endpoint}, restart the AKO pods once"
  elif [ -n "${avi_addr}" ] && sup_creds_wait; then
    if avi_secret_trusts "${avi_addr}" > /dev/null; then say "  avi-secret already trusts the controller's certificate"
    elif wait_until "avi-secret holds a CA that verifies the controller's certificate (WCP rewrites it from NSX, about 10 minutes)" 1500 30 avi_secret_trusts "${avi_addr}"; then
      act "restart the AKO pods once, now that their secret is right" quiet sup_run 'kubectl -n vmware-system-ako delete pod --all'
    else warn "avi-secret still does not verify the controller's certificate"; fi
  else warn "cannot reach the Supervisor as root: AKO's secret is not checked"; fi
  wait_until "Supervisor kubernetes=READY and the AKO pods Running (about 11 minutes after the restart)" 2400 60 sup_ready || { [ "${dry_run}" == "true" ] || { sup_get_creds && ako_diagnose; }; return 1; }
}

phase_k8s_shared() {
  if [ "${dry_run}" != "true" ] && [ -z "$(vm_paths "${PAT_K8S_SHARED}" | head -1)" ]; then say "no shared k8s VM (${PAT_K8S_SHARED}): not enabled in this spec, nothing to start"; return 0; fi
  start_group "k8s-shared control plane" "${PAT_K8S_SHARED}cp"
  start_group "k8s-shared workers" "${PAT_K8S_SHARED}w"
  wait_until "Gitea answers (${git_fqdn})" 900 20 gitea_up || return 1
}

vcfa_unsettled() {   # pods of the VCF Automation cluster that are not Running or Completed, twice in a row 5 minutes apart is "settled": see phase_vcfa_wait
  local ip n; ip=$(vcfa_ip); [ -n "${ip}" ] || { echo "no IP"; return 1; }
  n=$(vcfa_run "${ip}" 'kubectl get pods -A --no-headers 2>/dev/null | grep -vE " Running | Completed " | wc -l')
  case "${n}" in ''|*[!0-9]*) echo "cannot read the pods"; return 1 ;; esac
  echo "${n}"; [ "${n}" == "0" ]
}
phase_vcfa_wait() {
  local t0 clean=0 n
  [ "${no_orgs}" == "true" ] && { say "--no-orgs: not waiting for VCF Automation"; return 0; }
  if [ "${dry_run}" == "true" ]; then say "[dry-run] would wait up to ${vcfa_wait_minutes} min until no VCF Automation pod is outside Running/Completed for 10 minutes"; return 0; fi
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt $(( vcfa_wait_minutes * 60 )) ]; do
    n=$(vcfa_unsettled | head -1)
    if [ "${n}" == "0" ]; then clean=$((clean + 1)); say "  VCF Automation: every pod Running/Completed (${clean}/3)"; [ "${clean}" -ge 3 ] && return 0
    else clean=0; say "  VCF Automation: ${n} pod(s) not Running/Completed after $(( ($(date +%s) - t0) / 60 )) min"; fi
    sleep 300
  done
  say "VCF Automation did not settle in ${vcfa_wait_minutes} minutes: the orgs are NOT added (resume: vcf_startup.sh <json> --from vcfa-wait)"; return 1
}

phase_orgs() {
  local d=(); [ "${no_orgs}" == "true" ] && { say "--no-orgs: not adding the orgs"; return 0; }
  [ "${dry_run}" == "true" ] && d=(--dry-run)
  say "vcfa_org.sh add --all (the orgs that vcfa_org.sh delete --all removed; about 10 to 30 minutes each)"
  bash "${script_dir}/vcfa_org.sh" add --all --yes "${d[@]}" --json "${jsonFile}" 2>&1 | sed -u 's/^/    /' | tee -a "${log_file}"   # sed -u: a buffered sed held the lines back for hours
  return "${PIPESTATUS[0]}"
}

phase_finish() {
  local ip n=0 off=0 name line
  # ssh on the hosts was started for the vSAN flush of the shutdown: it was put back as it was, check that it is stopped
  for ip in ${host_ips}; do
    if [ "$(onhost "${ip}" govc host.info -json 2> /dev/null | jq -r '.hostSystems[0].config.service.service[]? | select(.key == "TSM-SSH") | .running')" == "true" ]; then act "stop ssh (TSM-SSH) on ${ip}" quiet onhost "${ip}" govc host.service stop TSM-SSH; fi
  done
  # what was on before the shutdown is on again (names of the vSphere pods change: only counted)
  if [ -s "${state_dir}/powered-on-before.txt" ] && vc_alive; then
    vc govc find / -type m 2> /dev/null | while IFS= read -r p; do [ "$(vc govc vm.info -json "${p}" 2> /dev/null | jq -r '.virtualMachines[0].runtime.powerState')" == "poweredOn" ] && basename "${p}"; done | sort > "${state_dir}/powered-on-after.txt"
    off=$(comm -23 "${state_dir}/powered-on-before.txt" "${state_dir}/powered-on-after.txt" | wc -l)
    say "powered on before the shutdown: $(wc -l < "${state_dir}/powered-on-before.txt"), now: $(wc -l < "${state_dir}/powered-on-after.txt"), not on now: ${off}"
    comm -23 "${state_dir}/powered-on-before.txt" "${state_dir}/powered-on-after.txt" | head -20 | sed 's/^/    not on: /'
  fi
  [ "${dry_run}" == "true" ] && { say "[dry-run] would: move inventory-before.* aside, remove cycle-complete, install the @reboot entry"; return 0; }
  # the next shutdown takes a NEW inventory (phase_inventory keeps an old one while cycle-complete is missing: it would keep this one)
  for f in inventory-before.json inventory-before.tsv; do [ -e "${state_dir}/${f}" ] && mv -f "${state_dir}/${f}" "${state_dir}/${f%.*}-restored-$(date +%Y%m%d%H%M).${f##*.}"; done
  rm -f "${state_dir}/cycle-complete"
  date +%Y-%m-%dT%H:%M:%S%z > "${state_dir}/startup-done"
  # the automatic start after a boot: installed once the first start worked, so a template captured from this vApp carries it
  line="@reboot sleep 120; bash ${script_dir}/vcf_startup.sh ${jsonFile} --auto >> /home/ubuntu/vcf_startup.log 2>&1"
  crontab -l 2> /dev/null | grep -qF "vcf_startup.sh" || { ( crontab -l 2> /dev/null; echo "${line}" ) | crontab - 2> /dev/null && say "installed the @reboot entry (kill switch: touch ~/.no-autostart)"; }
  say "the platform is started"
}

# ---- runner (same shape as vcf_shutdown.sh) --------------------------------------------------------------------------------------------------
for ph in "${start_from}" "${only_phase}"; do [ -z "${ph}" ] && continue; case " ${phases} " in *" ${ph} "*) ;; *) die "unknown phase '${ph}'; phases: ${phases}" ;; esac; done
[ "${dry_run}" == "true" ] || { vcf_status_uploader="${script_dir}/vapp-diagnostics-upload.sh"; vcf_status_uploader_json="${jsonFile}"; [ "${deployment_kind}" == "vApp" ] && [ -n "${diagnostics_repo:-}" ] && [ -f "${vcf_status_uploader}" ] || { vcf_status_uploader=""; }; }
run_mode="full"; [ -n "${start_from}" ] && run_mode="from:${start_from}"; [ -n "${only_phase}" ] && run_mode="only:${only_phase}"; [ "${dry_run}" == "true" ] && run_mode="${run_mode}+dry-run"; [ "${auto}" == "true" ] && run_mode="${run_mode}+auto"
if [ "${dry_run}" != "true" ]; then vcf_status_run_start "${phases}" "${run_mode}" "${jsonFile}"; trap vcf_status_exit EXIT; fi
say "vcf_startup.sh ${run_mode} on a ${deployment_kind} gw, ${bn}, hosts: $(echo ${host_ips} | tr '\n' ' ')"
started="false"; [ -z "${start_from}" ] && started="true"; idx=0
for phase in ${phases}; do
  idx=$((idx + 1))
  if [ -n "${only_phase}" ]; then [ "${phase}" == "${only_phase}" ] || continue
  elif [ "${started}" != "true" ]; then [ "${phase}" == "${start_from}" ] && started="true" || continue; fi
  say "==== phase ${idx}/$(echo ${phases} | wc -w): ${phase}"
  [ "${dry_run}" == "true" ] || { vcf_status_phase_start "${phase}" "${idx}"; t0=$(date +%s); }
  "phase_${phase//-/_}"; rc=$?
  [ "${dry_run}" == "true" ] || vcf_status_phase_end "${phase}" "${rc}" "$(( $(date +%s) - t0 ))" "bash ${script_dir}/vcf_startup.sh ${jsonFile} --from ${phase}"
  if [ "${rc}" -ne 0 ]; then say "phase ${phase} failed (exit code ${rc}): stopping. Resume: bash ${script_dir}/vcf_startup.sh ${jsonFile} --from ${phase}"; exit "${rc}"; fi
done
[ "${dry_run}" == "true" ] || vcf_status_run_end
say "done"
exit 0
