#!/bin/bash
#
# Ordered, guarded shutdown of the nested VCF platform, run ON THE GW (both use cases). Source: the recipe SHUTDOWN-STARTUP-RECIPE.md (first full run
# 2026-11-16) and the HOL Shutdown.zip order, with what that run corrected. The matching startup is vcf_startup.sh (later).
#
#   vcf_shutdown.sh <deployment json> [--dry-run] [--from <phase> | --only <phase>] [--skip-flush] [--flush-minutes N] [--poweroff-gw]
#
# What it does, in this order (phases; each prints what it found, the exit code of a phase is recorded in the status file):
#   precheck      refuses unless every VCF-A org of the spec is removed (vcfa_org.sh delete --all leaves /home/<org>/.delete); nothing else of the
#                 pipeline is running; the nested vCenter and every host answer. Exit code 2 when an org is still there.
#   inventory     VM name, power state, host (and the pre-shutdown placement the startup needs: edges!) into /home/ubuntu/platform-state/
#   vcfa          VCF Automation: scale vmsp-operator to 0, guest shutdown
#   vsp           Broadcom vcf_services_runtime_shutdown.sh on the VSP control-plane node (Broadcom Confidential: NOT in any repo, see VSP_SHUTDOWN_SCRIPT)
#   wcp           stop WCP on the vCenter (ssh root, `shell vmon-cli -k wcp`)
#   supervisor    Supervisor control-plane VM(s): vCenter refuses (NoPermission), so through the ESX host directly
#   k8s-shared    shared k8s VMs (workers, then control plane)
#   vsp-vms       the VSP VMs (after the script)
#   avi           service engines, then the controller
#   nsx           edges, then the manager(s)
#   operations    collector, VCF Operations, license
#   sddc-manager  SDDC Manager
#   vcenter       the vCenter, last; checked from its host
#   audit         every host directly: what is still powered on
#   stragglers    those: vSphere pod VMs (crxPod1Guest, no VMware Tools) are powered off (Harbor database last), the rest guest shutdown
#   flush         vSAN OSA only: elevator on, completion = the capacity disk's write counter stops growing on EVERY host (the zip's elevatorRunning does not
#                 exist on 9.1.1), ceiling --flush-minutes (default 45, like the zip; not finishing is logged, not fatal), elevator back to 0; ssh on the
#                 hosts is started for it and put back as it was
#   hosts         HARD GUARD: refuses (exit 3) while any VM is powered on or the audit was not clean; then ShutdownHost (force) on every host, staggered
#   installer     the VCF Installer VM (outside the nested vCenter)
#   ready         status.ready_for_poweroff = true. The gw cannot power itself off cleanly from here: vApp = the operator undeploys the vApp through VCD;
#                 sddc = `--poweroff-gw` schedules `shutdown -h +2`.
#
# Power operations OUTSIDE the nested vCenter (hosts, installer) depend on the use case: sddc through the underlay vCenter (govc), vApp through VCD
# (the same REST calls esxi-bootstrap.sh uses). That layer is the plat_* functions below, and nothing else in this script differs between the two.
# --dry-run changes nothing: discovery and the guards still run, every action is printed as "[dry-run] would: ...".
# Status: /home/ubuntu/json/vcf_shutdown_status.json (same shape as vcf_status.json, plus ready_for_poweroff), log: /home/ubuntu/vcf_shutdown.log.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jsonFile="$(readlink -f "${1:-}" 2> /dev/null)"
[ -f "${jsonFile}" ] || { echo "usage: vcf_shutdown.sh <deployment json> [--dry-run] [--from <phase> | --only <phase>] [--skip-flush] [--flush-minutes N] [--poweroff-gw]" >&2; exit 1; }
shift
dry_run="false"; start_from=""; only_phase=""; skip_flush="false"; flush_minutes=45; poweroff_gw="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run="true"; shift ;;
    --from) start_from="${2:?--from needs a phase}"; shift 2 ;;
    --only) only_phase="${2:?--only needs a phase}"; shift 2 ;;
    --skip-flush) skip_flush="true"; shift ;;
    --flush-minutes) flush_minutes="${2:?--flush-minutes needs a number}"; shift 2 ;;
    --poweroff-gw) poweroff_gw="true"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "${flush_minutes}" in ''|*[!0-9]*) echo "--flush-minutes is a whole number" >&2; exit 1 ;; esac

cd /home/ubuntu || exit 1
mkdir -p /home/ubuntu/json /home/ubuntu/platform-state
state_dir=/home/ubuntu/platform-state
log_file=/home/ubuntu/vcf_shutdown.log
vcf_status_file=/home/ubuntu/json/vcf_shutdown_status.json
source /home/ubuntu/bash/variables.sh < /dev/null
source "${script_dir}/functions.sh"
source "${script_dir}/vcf_status.sh"
for tool in govc jq curl sshpass; do command -v "${tool}" > /dev/null 2>&1 || { echo "ERROR: ${tool} is not installed" >&2; exit 1; }; done

say() { local m; m="$(date +%H:%M:%S) vcf_shutdown: $*"; echo "${m}"; echo "${m}" >> "${log_file}"; }
warn() { say "WARNING: $*"; }
die() { say "ERROR: $*"; exit "${2:-1}"; }
# act <description> <command...>: runs the command, or only says so with --dry-run
quiet() { "$@" > /dev/null 2>&1; }   # act "<what>" quiet <command>: the command is silent, the message of act is not
act() { local d="$1"; shift; if [ "${dry_run}" == "true" ]; then say "[dry-run] would: ${d}"; return 0; fi; say "${d}"; "$@"; }

bn="${basename_sddc}"
pw="$(jq -r .generic_password "${jsonFile}")"
sso="$(jq -r '.sddc.vcenter.ssoDomain // "vsphere.local"' "${jsonFile}")"
vc_fqdn="${bn}-vc01.${domain}"
host_ips="$(echo "${ips_esxi}" | jq -r '.[]')"
[ -n "${host_ips}" ] || die "ips_esxi is empty: no hosts to work with"
# VM name patterns (regular expressions on the VM name); override with the environment when a deployment names things differently
: "${PAT_VCFA:=^${bn}-auto-platform}" "${PAT_VSP:=^${bn}-vsp01-}" "${PAT_SUPERVISOR:=^SupervisorControlPlaneVM}" "${PAT_K8S_SHARED:=^k8s-shared-}"
: "${PAT_AVI_SE:=^vcf_Avi-se-}" "${PAT_AVI_CTRL:=^${bn}-avi-node}" "${PAT_NSX_EDGE:=^edge-[0-9]}" "${PAT_NSX_MGR:=^${bn}-nsx[0-9]}"
: "${PAT_OPS:=^${bn}-(collector|ops[0-9]|license)}" "${PAT_SDDCM:=^${bn}-sddcm$}" "${PAT_VC:=^${bn}-vc01$}"
# the Broadcom script (KB 440874) is Broadcom Confidential: it comes with the gw-tools ISO (copied to /home/ubuntu/ as ubuntu:ubuntu, mode 600, so it is run with bash, not executed), never from a repo
: "${VSP_SHUTDOWN_SCRIPT:=/home/ubuntu/vcf_services_runtime_shutdown.sh}"
export SSHPASS="${pw}"

# ---- vCenter / host / VM helpers (govc) --------------------------------------------------------------------------------------------------
vc_env() { export GOVC_URL="${vc_fqdn}" GOVC_USERNAME="administrator@${sso}" GOVC_PASSWORD="${pw}" GOVC_INSECURE=1; unset GOVC_DATACENTER; }
host_env() { export GOVC_URL="https://${1}" GOVC_USERNAME=root GOVC_PASSWORD="${pw}" GOVC_INSECURE=1; unset GOVC_DATACENTER; }
vc() { ( vc_env; "$@" ); }
onhost() { local ip="$1"; shift; ( host_env "${ip}"; "$@" ); }
# vm_paths <regex> [host ip]: inventory paths of the VMs whose NAME matches (one per line); on the vCenter, or directly on a host
vm_paths() { local re="$1" ip="${2:-}"; local f; if [ -n "${ip}" ]; then f=onhost; set -- "${ip}"; else f=vc; set --; fi
  "${f}" "$@" govc find / -type m 2> /dev/null | while IFS= read -r p; do [[ "$(basename "${p}")" =~ ${re} ]] && echo "${p}"; done; }
vm_power() { local p="$1" ip="${2:-}"; if [ -n "${ip}" ]; then onhost "${ip}" govc vm.info -json "${p}" 2> /dev/null; else vc govc vm.info -json "${p}" 2> /dev/null; fi | jq -r '.virtualMachines[0].runtime.powerState // "unknown"'; }
# shutdown_group <label> <regex> <seconds> [host ip]: guest shutdown of every powered-on match at once, then wait; 0 = all off, 1 = some stayed on (tools missing / timeout)
shutdown_group() {
  local label="$1" re="$2" limit="$3" ip="${4:-}" p on="" t0 left
  while IFS= read -r p; do [ -n "${p}" ] || continue
    [ "$(vm_power "${p}" "${ip}")" == "poweredOn" ] || { say "  ${label}: $(basename "${p}") already off"; continue; }
    on="${on}${p}"$'\n'
    if [ "${dry_run}" == "true" ]; then say "[dry-run] would: guest shutdown of $(basename "${p}")"; else say "  ${label}: guest shutdown $(basename "${p}")"
      if [ -n "${ip}" ]; then onhost "${ip}" govc vm.power -s "${p}" > /dev/null 2>&1; else vc govc vm.power -s "${p}" > /dev/null 2>&1; fi; fi
  done < <(vm_paths "${re}" "${ip}")
  [ -n "${on}" ] || { say "  ${label}: nothing powered on"; return 0; }
  [ "${dry_run}" == "true" ] && return 0
  t0=$(date +%s)
  while true; do left=0
    while IFS= read -r p; do [ -n "${p}" ] || continue; [ "$(vm_power "${p}" "${ip}")" == "poweredOn" ] && left=$((left + 1)); done <<< "${on}"
    [ "${left}" == "0" ] && { say "  ${label}: all off after $(( $(date +%s) - t0 ))s"; return 0; }
    [ $(( $(date +%s) - t0 )) -gt "${limit}" ] && { warn "${label}: ${left} VM(s) still on after ${limit}s"; return 1; }
    sleep 5
  done
}
re_escape() { printf '%s' "$1" | sed 's/[][()\.^$*+?{}|]/\\&/g'; }
vc_alive() { vc govc about > /dev/null 2>&1; }

# ---- platform layer: what lives OUTSIDE the nested vCenter (the ESX host VMs, the Installer VM): sddc = underlay vCenter, vApp = VCD ------------------
if [ "${deployment_kind}" == "vApp" ]; then
  vcd_login
  plat_name_host() { echo "${bn}-mgmt-esx0${1}"; }
  plat_name_installer() { echo "vcf_installer"; }
  plat_state() { local resp; resp=$(curl -sk "https://${vcd_host}/api/query?type=vm&format=records&pageSize=128$(vcd_vm_filter "$1")" -H "Authorization: Bearer ${vcd_auth_token}" -H "Accept: application/*+json;version=${vcd_api_version}")
    case "$(echo "${resp}" | jq -r --arg n "$1" '[.record[]? | select(.name == $n) | .status][0] // "missing"')" in POWERED_ON) echo poweredOn ;; POWERED_OFF) echo poweredOff ;; *) echo unknown ;; esac; }
  plat_guest_shutdown() { local h; h=$(vcd_find_vm_href "$1"); curl -sk -X POST "${h}/power/action/shutdown" -H "Authorization: Bearer ${vcd_auth_token}" -H "Accept: application/*+xml;version=${vcd_api_version}" > /dev/null; }
else
  plat_env() { export GOVC_URL="${vsphere_underlay_vcsa}" GOVC_USERNAME="${vsphere_underlay_username}" GOVC_PASSWORD="${vsphere_underlay_password}" GOVC_DATACENTER="${vsphere_underlay_datacenter}" GOVC_INSECURE=1; }
  plat_name_host() { echo "${bn}-mgmt-esx0${1}"; }
  plat_name_installer() { echo "${bn}-${name_vcf_installer}.${domain}"; }
  plat_state() { ( plat_env; p=$(govc find / -type m -name "$1" | head -1); [ -n "${p}" ] && govc vm.info -json "${p}" | jq -r '.virtualMachines[0].runtime.powerState' || echo unknown ); }
  plat_guest_shutdown() { ( plat_env; p=$(govc find / -type m -name "$1" | head -1); govc vm.power -s "${p}" > /dev/null 2>&1 ); }
fi
plat_wait_off() { local name="$1" limit="$2" t0; t0=$(date +%s); while [ "$(plat_state "${name}")" != "poweredOff" ]; do [ $(( $(date +%s) - t0 )) -gt "${limit}" ] && return 1; sleep 5; done; return 0; }

# ---- the phases --------------------------------------------------------------------------------------------------------------------------
phases="precheck inventory vcfa vsp wcp supervisor k8s-shared vsp-vms avi nsx operations sddc-manager vcenter audit stragglers flush hosts installer ready"
audit_left=-1   # powered-on VMs found by the last audit (-1 = not audited in this run)

phase_precheck() {
  local o left="" running
  # 1. the orgs: removed with vcfa_org.sh delete --all (a locked account with /home/<org>/.delete is the marker of a removed org)
  for o in $(echo "${vcf_a_organizations}" | jq -r '.[].name'); do [ -e "/home/${o}/.delete" ] || left="${left} ${o}"; done
  if [ -n "${left}" ]; then
    if [ "${dry_run}" == "true" ]; then warn "orgs not removed yet:${left} (a real run refuses here, exit 2)"; else say "orgs not removed yet:${left}: run  vcfa_org.sh delete --all  first (this is the enforced order)"; return 2; fi
  else say "every org of the spec is removed (markers present)"; fi
  # 2. nothing else is running
  running=$(ps -eo args | grep -E "^bash .*/(vcf_bootstrap|vcfa_org|vcfa_tenant_bootstrap|vcfa_provider_bootstrap|vcfa_tenant_cleaning)\.sh" | grep -v grep | head -1)
  [ -z "${running}" ] || { say "something else is running: ${running}"; return 1; }
  # 3. everything answers
  vc_alive || { say "the nested vCenter ${vc_fqdn} does not answer"; return 1; }
  local ip; for ip in ${host_ips}; do [ "$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://${ip}/")" == "200" ] || { say "host ${ip} does not answer on https"; return 1; }; done
  say "nested vCenter and $(echo "${host_ips}" | wc -w) hosts answer"
}

phase_inventory() {
  local out="${state_dir}/inventory-before.json" tsv="${state_dir}/inventory-before.tsv"
  say "saving the inventory (name, power, host, guest IP) to ${out}"
  [ "${dry_run}" == "true" ] && { say "[dry-run] would write ${out}"; vc govc find / -type m 2> /dev/null | wc -l | sed 's/^/  VMs in the nested vCenter: /'; return 0; }
  # a run that stopped half way (or a repeated one) must not replace the inventory taken while the platform was fully on: the startup restores from it.
  # The marker cycle-complete is written by the ready phase and removed again by the next inventory that is taken.
  if [ -s "${out}" ] && [ ! -e "${state_dir}/cycle-complete" ]; then
    say "an earlier shutdown run did not reach the end: keeping its inventory (taken while the platform was up): $(jq 'length' "${out}") VMs"; return 0
  fi
  rm -f "${state_dir}/cycle-complete"
  vc govc find / -type m 2> /dev/null | while IFS= read -r p; do vc govc vm.info -json "${p}" 2> /dev/null | jq -c '.virtualMachines[] | {name, power: .runtime.powerState, host: .runtime.host.value, ip: (.guest.ipAddress // null), guestId: .config.guestId, template: .config.template}'; done | jq -s . > "${out}"
  # host morefs -> names, so the startup can put the edges back where they were
  # govc host.info without a path fails with several hosts ("default host resolves to multiple instances"): one call per host
  for hp in $(vc govc find / -type h 2> /dev/null); do vc govc host.info -json "${hp}" 2> /dev/null | jq -c '.hostSystems[]? | {moref: .self.value, name: .name}'; done | jq -s . > "${state_dir}/host-morefs.json"
  jq -r '.[] | select(.power == "poweredOn") | .name' "${out}" | sort > "${state_dir}/powered-on-before.txt"
  say "  $(jq 'length' "${out}") VMs, $(wc -l < "${state_dir}/powered-on-before.txt") powered on; placement of the edges: $(jq -r '[.[] | select(.name | test("^edge-")) | "\(.name)=\(.host)"] | join(" ")' "${out}")"
}

phase_vcfa() {
  local p ip rs mode="scale"
  p=$(vm_paths "${PAT_VCFA}" | head -1); [ -n "${p}" ] || { say "no VCF Automation VM found (${PAT_VCFA}): skipping"; return 0; }
  if [ "$(vm_power "${p}")" == "poweredOn" ]; then
    ip=$(vc govc vm.ip "${p}" 2> /dev/null)
    [ -n "${ip}" ] || { warn "no IP for the VCF Automation VM: vmsp-operator is not scaled down"; ip=""; }
    if [ -n "${ip}" ]; then
      [ "${dry_run}" == "true" ] && mode="check"
      rs=$(mktemp); cat > "${rs}" <<'REMOTE_EOF'
export KUBECONFIG=/etc/kubernetes/super-admin.conf
ns=$(kubectl get deploy -A --no-headers 2> /dev/null | awk '$2=="vmsp-operator" {print $1}' | head -1)
[ -n "$ns" ] || { echo "vmsp-operator not found"; exit 0; }
echo "vmsp-operator in namespace $ns: $(kubectl get deploy vmsp-operator -n "$ns" --no-headers)"
[ "$1" == "scale" ] && kubectl scale deployment vmsp-operator -n "$ns" --replicas=0
exit 0
REMOTE_EOF
      sshpass -e scp -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password "${rs}" "vmware-system-user@${ip}:/tmp/vcf_shutdown_vcfa.sh" 2>&1 | grep -vE "Permanently added|Welcome|^$"
      say "VCF Automation node ${ip}: vmsp-operator ${mode} (the platform restores it by itself after the boot)"
      sshpass -e ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o ConnectTimeout=15 "vmware-system-user@${ip}" "echo '${pw}' | sudo -S -i bash /tmp/vcf_shutdown_vcfa.sh ${mode}" 2>&1 | grep -vE "Permanently added|Welcome to Photon|^$" | sed 's/^\[sudo\] password for vmware-system-user: //' | sed 's/^/  /'
      rm -f "${rs}"
    fi
  fi
  shutdown_group "vcfa" "${PAT_VCFA}" 300
}

phase_vsp() {
  local ip="" cand tok code vsp_rc
  [ "$(vm_paths "${PAT_VSP}" | wc -l)" -gt 0 ] || { say "no VSP VMs found: skipping"; return 0; }
  if [ ! -r "${VSP_SHUTDOWN_SCRIPT}" ]; then
    say "the Broadcom VSP shutdown script is missing or not readable: ${VSP_SHUTDOWN_SCRIPT} (KB 440874, Broadcom Confidential, delivered with the gw ISO, which copies it to /home/ubuntu/ with mode 600). Without it the VSP platform would be powered off without its graceful stop."
    [ "${dry_run}" == "true" ] && return 0; return 1
  fi
  # the control-plane node: the one whose management API lists the components (a worker answers 404)
  while IFS= read -r cand; do [ -n "${cand}" ] || continue; cand=$(vc govc vm.ip "${cand}" 2> /dev/null); [ -n "${cand}" ] || continue
    tok=$(curl -sk -m 10 -X POST "https://${cand}:5480/api/v1/auth/login" -H "Content-Type: application/json" -d "{\"username\":\"vmware-system-user\",\"password\":\"${pw}\"}" 2> /dev/null | jq -r '.accessToken // .token // empty' 2> /dev/null)
    [ -n "${tok}" ] || continue
    code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${tok}" "https://${cand}:5480/api/v1/components" 2> /dev/null)
    [ "${code}" == "200" ] && { ip="${cand}"; break; }
  done < <(vm_paths "${PAT_VSP}")
  [ -n "${ip}" ] || { say "no VSP control-plane node answers on 5480"; return 1; }
  say "VSP control-plane node: ${ip}"
  act "run bash ${VSP_SHUTDOWN_SCRIPT} --node-ip ${ip} --yes --skip-snapshot-check (about 4 minutes)" env VMSP_PASSWORD="${pw}" bash "${VSP_SHUTDOWN_SCRIPT}" --node-ip "${ip}" --yes --skip-snapshot-check 2>&1 | sed 's/^/    /' | tail -25
  vsp_rc=${PIPESTATUS[0]}   # right after the pipeline: any command in between (even the [ below) overwrites PIPESTATUS (this made a successful VSP script read as failed on 2026-11-17)
  [ "${dry_run}" == "true" ] && return 0
  [ "${vsp_rc}" == "0" ] || return 1
}

phase_wcp() {
  local out
  act "stop WCP on ${vc_fqdn}: shell vmon-cli -k wcp" quiet sshpass -e ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o ConnectTimeout=15 "root@${vc_fqdn}" "shell vmon-cli -k wcp"
  [ "${dry_run}" == "true" ] && return 0
  sleep 10
  out=$(sshpass -e ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o ConnectTimeout=15 "root@${vc_fqdn}" "shell vmon-cli -s wcp" 2> /dev/null | grep -E "RunState" | head -1)
  say "  ${out}"; [[ "${out}" == *STOPPED* ]] || return 1
}

phase_supervisor() {
  # the Supervisor VMs refuse power operations through vCenter (NoPermission): through the host that runs each
  local ip p any=0
  for ip in ${host_ips}; do
    while IFS= read -r p; do [ -n "${p}" ] || continue; any=1; done < <(vm_paths "${PAT_SUPERVISOR}" "${ip}")
    [ "${any}" == "1" ] && shutdown_group "supervisor@${ip}" "${PAT_SUPERVISOR}" 300 "${ip}"
    any=0
  done
  return 0
}

phase_k8s_shared() { shutdown_group "k8s-shared workers" "${PAT_K8S_SHARED}w" 180; shutdown_group "k8s-shared control plane" "${PAT_K8S_SHARED}cp" 180; }
phase_vsp_vms() { shutdown_group "vsp" "${PAT_VSP}" 300; }
phase_avi() { shutdown_group "avi service engines" "${PAT_AVI_SE}" 180; shutdown_group "avi controller" "${PAT_AVI_CTRL}" 300; }
phase_nsx() { shutdown_group "nsx edges" "${PAT_NSX_EDGE}" 180; shutdown_group "nsx manager" "${PAT_NSX_MGR}" 300; }
phase_operations() { shutdown_group "operations" "${PAT_OPS}" 300; }
phase_sddc_manager() { shutdown_group "sddc manager" "${PAT_SDDCM}" 240; }

phase_vcenter() {
  # the vCenter goes last; its own session dies with it, so the result is read from the hosts
  local ip p host_of="" t0
  for ip in ${host_ips}; do [ -n "$(vm_paths "${PAT_VC}" "${ip}")" ] && host_of="${ip}"; done
  [ -n "${host_of}" ] || { say "the vCenter VM was not found on any host"; return 1; }
  if [ "${dry_run}" == "true" ]; then say "[dry-run] would: guest shutdown of the vCenter VM (on host ${host_of}), then check it from that host"; return 0; fi
  p=$(vm_paths "${PAT_VC}" "${host_of}" | head -1)
  say "vCenter VM is on ${host_of}: guest shutdown"
  vc govc vm.power -s "$(vm_paths "${PAT_VC}" | head -1)" > /dev/null 2>&1
  t0=$(date +%s)
  while [ "$(vm_power "${p}" "${host_of}")" != "poweredOff" ]; do [ $(( $(date +%s) - t0 )) -gt 300 ] && { say "the vCenter VM is still on after 300s"; return 1; }; sleep 5; done
  say "  vCenter off after $(( $(date +%s) - t0 ))s"
}

audit_hosts() {
  # fills audit_left and ${state_dir}/audit-hosts.tsv: every VM still powered on, read from each host directly
  local ip p; : > "${state_dir}/audit-hosts.tsv"
  for ip in ${host_ips}; do
    onhost "${ip}" govc find / -type m 2> /dev/null | while IFS= read -r p; do onhost "${ip}" govc vm.info -json "${p}" 2> /dev/null | jq -r --arg h "${ip}" '.virtualMachines[] | select(.runtime.powerState == "poweredOn") | [$h, .name, (.config.guestId // "-")] | @tsv'; done >> "${state_dir}/audit-hosts.tsv"
  done
  audit_left=$(wc -l < "${state_dir}/audit-hosts.tsv")
}

phase_audit() { audit_hosts; say "VMs still powered on at host level: ${audit_left}"; awk -F'\t' '{print "  " $1 "  " $2 "  (" $3 ")"}' "${state_dir}/audit-hosts.tsv" | head -30; }

phase_stragglers() {
  local ip name gid first_db=""
  audit_hosts
  [ "${audit_left}" == "0" ] && { say "nothing to do: no VM is powered on"; return 0; }
  # vSphere pod VMs (crxPod1Guest) have no VMware Tools: a guest shutdown is refused, so they are powered off (a database pod last); everything else gets a guest shutdown first
  for pass in others pods db; do
    while IFS=$'\t' read -r ip name gid; do [ -n "${name}" ] || continue
      if [ "${pass}" == "others" ] && [ "${gid}" != "crxPod1Guest" ]; then shutdown_group "straggler ${name}" "^$(re_escape "${name}")\$" 180 "${ip}" || act "power off ${name} on ${ip} (no VMware Tools or timeout)" onhost "${ip}" govc vm.power -off "$(vm_paths "^$(re_escape "${name}")\$" "${ip}" | head -1)"
      elif [ "${pass}" == "pods" ] && [ "${gid}" == "crxPod1Guest" ] && [[ "${name}" != *database* ]]; then act "power off pod VM ${name} on ${ip}" onhost "${ip}" govc vm.power -off "$(vm_paths "^$(re_escape "${name}")\$" "${ip}" | head -1)"
      elif [ "${pass}" == "db" ] && [ "${gid}" == "crxPod1Guest" ] && [[ "${name}" == *database* ]]; then act "power off pod VM ${name} on ${ip} (database, last)" onhost "${ip}" govc vm.power -off "$(vm_paths "^$(re_escape "${name}")\$" "${ip}" | head -1)"; fi
    done < "${state_dir}/audit-hosts.tsv"
  done
  [ "${dry_run}" == "true" ] && return 0
  sleep 10; audit_hosts; say "after the stragglers: ${audit_left} VM(s) still powered on"; [ "${audit_left}" == "0" ] || return 1
}

esx_ssh() { sshpass -e ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=keyboard-interactive -o PubkeyAuthentication=no -o ConnectTimeout=15 "root@$1" "$2" 2>&1 | grep -vE "Permanently added|^$"; }

phase_flush() {
  local ip esa cap t0 el all_quiet n d quiet_polls=4 quiet_ops=100 poll=30 ceiling=$((flush_minutes * 60))
  declare -A ssh_was last quiet capdev
  [ "${skip_flush}" == "true" ] && { say "flush skipped (--skip-flush): the first start will replay the write buffer"; return 0; }
  [ "${flush_minutes}" -gt 0 ] || { say "flush skipped (--flush-minutes 0)"; return 0; }
  if [ "${dry_run}" == "true" ]; then say "[dry-run] would: start ssh on the hosts, check OSA/ESA, enable the elevator, watch the capacity-disk write counters up to ${flush_minutes} min, set the elevator back to 0, put ssh back as it was"; return 0; fi
  for ip in ${host_ips}; do ssh_was[$ip]=$(onhost "${ip}" govc host.info -json 2> /dev/null | jq -r '.hostSystems[0].config.service.service[]? | select(.key == "TSM-SSH") | .running'); onhost "${ip}" govc host.service start TSM-SSH > /dev/null 2>&1; done
  sleep 4
  esa=$(esx_ssh "$(echo "${host_ips}" | head -1)" "esxcli vsan cluster get" | grep -i "ESA Enabled" | head -1)
  if [[ "${esa}" == *true* ]]; then say "vSAN ESA: no flush needed"; for ip in ${host_ips}; do [ "${ssh_was[$ip]}" == "true" ] || onhost "${ip}" govc host.service stop TSM-SSH > /dev/null 2>&1; done; return 0; fi
  say "vSAN OSA: enabling the elevator on every host (ceiling ${flush_minutes} min)"
  for ip in ${host_ips}; do
    capdev[$ip]=$(esx_ssh "${ip}" "esxcli vsan storage list" | awk '/^[^ ]/ {dev=$1} /Is Capacity Tier: true/ {print dev; exit}')
    esx_ssh "${ip}" "echo y | vsish -e set /config/LSOM/intOpts/plogRunElevator 1 > /dev/null 2>&1"
    say "  ${ip}: capacity device ${capdev[$ip]:-NOT FOUND}, elevator $(esx_ssh "${ip}" 'vsish -e get /config/LSOM/intOpts/plogRunElevator' | grep 'Current value' | tr -d ' ')"
    last[$ip]=$(esx_ssh "${ip}" "esxcli storage core device stats get -d ${capdev[$ip]}" | grep "Write Operations" | grep -v Failed | head -1 | sed 's/.*: *//'); quiet[$ip]=0
  done
  t0=$(date +%s); all_quiet=0
  while [ $(( $(date +%s) - t0 )) -lt "${ceiling}" ]; do
    sleep "${poll}"; all_quiet=1; el=$(( $(date +%s) - t0 )); line=""
    for ip in ${host_ips}; do
      n=$(esx_ssh "${ip}" "esxcli storage core device stats get -d ${capdev[$ip]}" | grep "Write Operations" | grep -v Failed | head -1 | sed 's/.*: *//'); d=$(( ${n:-0} - ${last[$ip]:-0} )); last[$ip]="${n}"
      if [ "${d}" -le "${quiet_ops}" ]; then quiet[$ip]=$(( ${quiet[$ip]} + 1 )); else quiet[$ip]=0; fi
      [ "${quiet[$ip]}" -ge "${quiet_polls}" ] || all_quiet=0
      line="${line} ${ip##*.}:+${d}"
    done
    say "  flush ${el}s: capacity-disk writes in ${poll}s:${line}"
    [ "${all_quiet}" == "1" ] && [ "${el}" -ge 300 ] && break
  done
  if [ "${all_quiet}" == "1" ]; then say "FLUSH DONE after $(( $(date +%s) - t0 ))s"; else warn "flush not quiet at the ${flush_minutes}-minute ceiling (like the zip, we go on: the write buffer is persistent and is replayed at the next start)"; fi
  for ip in ${host_ips}; do esx_ssh "${ip}" "echo y | vsish -e set /config/LSOM/intOpts/plogRunElevator 0 > /dev/null 2>&1"; say "  ${ip}: elevator back to $(esx_ssh "${ip}" 'vsish -e get /config/LSOM/intOpts/plogRunElevator' | grep 'Current value' | tr -d ' ')"
    [ "${ssh_was[$ip]}" == "true" ] || onhost "${ip}" govc host.service stop TSM-SSH > /dev/null 2>&1; done
  return 0
}

phase_hosts() {
  local ip i=0
  # HARD GUARD: nothing may be powered on in any host; checked again here, whatever the earlier phases said
  audit_hosts
  if [ "${audit_left}" != "0" ] && [ "${dry_run}" == "true" ] && [ "${only_phase}" != "hosts" ]; then
    # a full dry-run shut nothing down, so VMs are on by construction: say so, and go on to show the rest of the plan (the guard itself is tested by a real run or by --only hosts --dry-run)
    say "[dry-run] ${audit_left} VM(s) are powered on now because nothing was shut down; in a real run the earlier phases stop them and this guard refuses (exit 3) if any is left"
  elif [ "${audit_left}" != "0" ]; then say "REFUSING to power off the hosts: ${audit_left} VM(s) are still powered on:"; awk -F'\t' '{print "  " $1 "  " $2}' "${state_dir}/audit-hosts.tsv" | head -10; return 3; fi
  [ "${audit_left}" == "0" ] && say "guard passed: no VM is powered on on any host"
  for ip in ${host_ips}; do i=$((i + 1))
    act "ShutdownHost (force) ${ip}" quiet onhost "${ip}" govc host.shutdown -f "*"
    [ "${dry_run}" == "true" ] || sleep 5
  done
  [ "${dry_run}" == "true" ] && { say "[dry-run] would: wait for the host VMs to be powered off ($(plat_name_host 1) ...)"; return 0; }
  i=0; for ip in ${host_ips}; do i=$((i + 1)); plat_wait_off "$(plat_name_host "${i}")" 300 && say "  $(plat_name_host "${i}") powered off" || { warn "$(plat_name_host "${i}") is not powered off after 300s"; return 1; }; done
}

phase_installer() {
  local n; n="$(plat_name_installer)"
  [ "$(plat_state "${n}")" == "poweredOn" ] || { say "installer VM ${n}: $(plat_state "${n}")"; return 0; }
  act "guest shutdown of the Installer VM ${n}" plat_guest_shutdown "${n}"
  [ "${dry_run}" == "true" ] && return 0
  plat_wait_off "${n}" 300 && say "  ${n} powered off" || { warn "${n} is not powered off after 300s"; return 1; }
}

phase_ready() {
  say "READY FOR POWER-OFF of the gw$([ "${deployment_kind}" == "vApp" ] && echo " (the operator undeploys the vApp through VCD)")"
  [ "${dry_run}" == "true" ] && return 0
  touch "${state_dir}/cycle-complete"
  vcf_status_update '.ready_for_poweroff = true | .ready_at = $now'
  if [ "${poweroff_gw}" == "true" ]; then say "--poweroff-gw: shutdown -h in 2 minutes"; sudo shutdown -h +2 "vcf_shutdown.sh: platform is down, gw power-off" > /dev/null 2>&1; fi
}

# ---- runner (same shape as vcf_bootstrap.sh) -----------------------------------------------------------------------------------------------
for ph in "${start_from}" "${only_phase}"; do [ -z "${ph}" ] && continue; case " ${phases} " in *" ${ph} "*) ;; *) die "unknown phase '${ph}'; phases: ${phases}" ;; esac; done
[ "${dry_run}" == "true" ] || { vcf_status_uploader="${script_dir}/vapp-diagnostics-upload.sh"; vcf_status_uploader_json="${jsonFile}"; [ "${deployment_kind}" == "vApp" ] && [ -n "${diagnostics_repo:-}" ] && [ -f "${vcf_status_uploader}" ] || { vcf_status_uploader=""; }; }
run_mode="full"; [ -n "${start_from}" ] && run_mode="from:${start_from}"; [ -n "${only_phase}" ] && run_mode="only:${only_phase}"; [ "${dry_run}" == "true" ] && run_mode="${run_mode}+dry-run"
if [ "${dry_run}" != "true" ]; then vcf_status_run_start "${phases}" "${run_mode}" "${jsonFile}"; trap vcf_status_exit EXIT; vcf_status_update '.ready_for_poweroff = false'; fi
say "vcf_shutdown.sh ${run_mode} on a ${deployment_kind} gw, ${bn}, hosts: $(echo ${host_ips} | tr '\n' ' ')"
started="false"; [ -z "${start_from}" ] && started="true"; idx=0
for phase in ${phases}; do
  idx=$((idx + 1))
  if [ -n "${only_phase}" ]; then [ "${phase}" == "${only_phase}" ] || continue
  elif [ "${started}" != "true" ]; then [ "${phase}" == "${start_from}" ] && started="true" || continue; fi
  say "==== phase ${idx}/$(echo ${phases} | wc -w): ${phase}"
  [ "${dry_run}" == "true" ] || { vcf_status_phase_start "${phase}" "${idx}"; t0=$(date +%s); }
  "phase_${phase//-/_}"; rc=$?
  [ "${dry_run}" == "true" ] || vcf_status_phase_end "${phase}" "${rc}" "$(( $(date +%s) - t0 ))" "bash ${script_dir}/vcf_shutdown.sh ${jsonFile} --from ${phase}"
  if [ "${rc}" -ne 0 ]; then say "phase ${phase} failed (exit code ${rc}): stopping. Resume: bash ${script_dir}/vcf_shutdown.sh ${jsonFile} --from ${phase}"; exit "${rc}"; fi
done
[ "${dry_run}" == "true" ] || vcf_status_run_end
say "done"
exit 0
