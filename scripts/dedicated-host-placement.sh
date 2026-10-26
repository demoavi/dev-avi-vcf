#!/bin/bash
#
# vApp use case only: keeps vCenter and VCF Automation on the dedicated ESX host (vms.esx.dedicated_host, named
# <basename>-mgmt-esx05, the fifth host of the management cluster) and every other VM off it, with two DRS VM-Host rules:
#   specific-VMs  MUST run on  the host group dedicated-host   (vCenter <basename>-vc01, VCF Automation <basename>-auto-platform-*)
#   other-VMs     MUST NOT run on the host group dedicated-host (every other VM, except templates, vCLS and ESX agent VMs)
#
# usage: dedicated-host-placement.sh <json file> [--place | --cron | --install-cron | --dry-run]
#   --place         first pass, called by vcenter-bootstrap.sh: creates the groups, vMotions each VM where it belongs (govc
#                   vm.migrate blocks until the vMotion is done), then creates the rules. Waits up to PLACEMENT_TIMEOUT_SEC
#                   (default 1800 s) for every VM to be in place; after that it logs an ERROR and exits 0 (never fails the
#                   pipeline, the cron keeps the groups right and DRS enforces the rules).
#   --cron          every minute (see --install-cron): refreshes the two VM groups (new VMs join other-VMs) and, if the host
#                   group or a rule is missing, recreates it. No vMotion of its own, DRS does that. If the dedicated host stays
#                   disconnected or not responding for 3 runs the two rules are disabled (otherwise a MUST rule stops
#                   vCenter and VCF Automation from restarting elsewhere) and enabled again when the host is back.
#                   Planned maintenance of that host: disable the two rules first (a host cannot enter maintenance mode
#                   while a mandatory rule pins VMs to it): govc cluster.rule.change -name <rule> -enable=false
#   --install-cron  adds the --cron entry to ubuntu's crontab (replaces an existing one).
#   --dry-run       read-only: prints what --place would change.
# Does nothing outside the vApp use case, or when the dedicated host is not in vCenter's inventory.
#
jsonFile="${1:-/home/ubuntu/json/deployment.json}"
mode="${2:---place}"
# cron's PATH is only /usr/bin:/bin, govc lives in /usr/local/bin
export PATH="${PATH}:/usr/local/bin:/usr/local/sbin"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

# PLACEMENT_ALLOW_NON_VAPP / DEDICATED_HOST_FQDN: only to test the read-only parts against another vCenter
[ "${deployment_kind}" == "vApp" ] || [ "${PLACEMENT_ALLOW_NON_VAPP:-}" == "1" ] || exit 0

host_group="dedicated-host"
specific_group="specific-VMs"
other_group="other-VMs"
rule_specific="dedicated-host-specific-vms"
rule_other="dedicated-host-other-vms"
state_dir="/home/ubuntu/.dedicated-host-placement"
place_timeout_sec="${PLACEMENT_TIMEOUT_SEC:-1800}"
dedicated_fqdn="${DEDICATED_HOST_FQDN:-${basename_sddc}-mgmt-esx05.${domain}}"

# --place talks to the team (log_notify needs the VCD session); the cron only writes its own log file
say() {
  if [ "${mode}" == "--place" ]; then log_notify "$1"
  elif [ "${mode}" == "--dry-run" ]; then log_only "[dry-run, nothing changed] $1"
  else log_only "$1"; fi
}
say_quiet() { log_only "$1"; }
# cron: a problem that stays is written once, not every minute (the marker goes away when the problem does)
say_once() {
  mkdir -p "${state_dir}"
  [ -f "${state_dir}/once_$1" ] && return 0
  touch "${state_dir}/once_$1"
  say "$2"
}
clear_once() { rm -f "${state_dir}/once_$1"; }
run() { if [ "${mode}" == "--dry-run" ]; then echo "DRY-RUN: $*"; return 0; fi; "$@"; }
[ "${mode}" == "--place" ] && vcd_login

if [ "${mode}" == "--install-cron" ]; then
  cron_line="* * * * * flock -n /tmp/dedicated-host-placement.lock ${script_dir}/dedicated-host-placement.sh ${jsonFile} --cron >> /home/ubuntu/dedicated-host-placement.log 2>&1"
  (crontab -l 2>/dev/null | grep -v 'dedicated-host-placement.sh'; echo "${cron_line}") | crontab -
  log_only "dedicated-host-placement.sh installed in ubuntu's crontab (every minute, log: /home/ubuntu/dedicated-host-placement.log)"
  exit 0
fi

if ! command -v govc > /dev/null 2>&1; then
  [ "${mode}" == "--cron" ] && say_once govc "ERROR: govc not found in PATH (${PATH}), the dedicated host groups are not maintained" || say "ERROR: govc not found in PATH"
  exit 0
fi
export GOVC_URL="${basename_sddc}-vc01.${domain}"
export GOVC_USERNAME="administrator@$(jq -c -r .sddc.vcenter.ssoDomain ${jsonFile})"
export GOVC_PASSWORD="${generic_password}"
export GOVC_DATACENTER="${basename_sddc}-dc"
export GOVC_INSECURE=true
export GOVC_PERSIST_SESSION=false
[ "${mode}" == "--cron" ] && export GOVC_PERSIST_SESSION=true
unset GOVC_CLUSTER

host_path=$(govc find / -type h -name "${dedicated_fqdn}" 2>/dev/null | head -1)
if [ -z "${host_path}" ]; then
  if [ "${mode}" == "--cron" ]; then
    say_once host "dedicated ESX host ${dedicated_fqdn} not found in vCenter (vCenter down, or the host is not in its inventory): groups not maintained"
  else
    say "dedicated ESX host ${dedicated_fqdn} is not in vCenter's inventory: placement skipped"
  fi
  exit 0
fi
clear_once host; clear_once govc
cluster_path=$(dirname "${host_path}")
if ! govc find / -type c 2>/dev/null | grep -qx "${cluster_path}"; then
  say "ERROR: ${dedicated_fqdn} is not a member of a cluster (${cluster_path}): placement skipped"
  exit 0
fi

# specific_paths (vCenter first, then VCF Automation) and other_paths: inventory paths, so a name that exists twice cannot be mistaken
compute_sets() {
  local p n t skip
  local -a all_vms templates vcenter_paths vcfa_paths
  specific_paths=(); other_paths=(); vcenter_paths=(); vcfa_paths=()
  mapfile -t templates < <(govc find / -type m -config.template true 2>/dev/null)
  mapfile -t all_vms < <(govc find / -type m 2>/dev/null)
  for p in "${all_vms[@]}"; do
    [ -n "${p}" ] || continue
    n="${p##*/}"
    case "${p}" in */vCLS/*|*"/ESX Agents/"*) continue ;; esac
    case "${n}" in vCLS-*) continue ;; esac
    skip=0
    for t in "${templates[@]}"; do [ "${p}" == "${t}" ] && skip=1 && break; done
    [ ${skip} -eq 1 ] && continue
    if [ "${n}" == "${basename_sddc}-vc01" ]; then vcenter_paths+=("${p}")
    elif [[ "${n}" == ${basename_sddc}-auto-platform-* ]]; then vcfa_paths+=("${p}")
    else other_paths+=("${p}"); fi
  done
  specific_paths=("${vcenter_paths[@]}" "${vcfa_paths[@]}")
}

# "<vm name><TAB><host fqdn>" for powered-on VMs among the given inventory paths
vm_hosts() {
  [ $# -gt 0 ] || return 0
  govc vm.info -r "$@" 2>/dev/null | awk '/^Name:/{sub(/^Name: */,""); n=$0} /^ *Host:/{sub(/^ *Host: */,""); print n "\t" $0}'
}

ensure_host_group() {
  govc cluster.group.ls -cluster "${cluster_path}" -name "${host_group}" > /dev/null 2>&1 && return 0
  run govc cluster.group.create -cluster "${cluster_path}" -name "${host_group}" -host "${dedicated_fqdn}" \
    && say "host group ${host_group} created (${dedicated_fqdn})"
}

# name, then the wanted members' inventory paths; changes the group only when its members differ
ensure_vm_group() {
  local name=$1; shift
  local -a want=()
  local want_names have_names p
  # cluster.group.create/change only accept a bare VM name (no inventory path, no moref: tested, even for VMs inside folders);
  # VM names are unique in this inventory
  for p in "$@"; do want+=("${p##*/}"); done
  [ ${#want[@]} -gt 0 ] || return 0
  if ! govc cluster.group.ls -cluster "${cluster_path}" -name "${name}" > /dev/null 2>&1; then
    run govc cluster.group.create -cluster "${cluster_path}" -name "${name}" -vm "${want[@]}" \
      && say "VM group ${name} created (${#want[@]} VMs)"
    return 0
  fi
  want_names=$(printf '%s\n' "${want[@]}" | sed 's#.*/##' | sort)
  have_names=$(govc cluster.group.ls -cluster "${cluster_path}" -name "${name}" 2>/dev/null | sed 's#.*/##' | sort)
  [ "${want_names}" == "${have_names}" ] && return 0
  run govc cluster.group.change -cluster "${cluster_path}" -name "${name}" "${want[@]}" \
    && say "VM group ${name} updated (${#want[@]} VMs)"
}

# rule name, VM group, then -host-affine-group (MUST run on) or -host-anti-affine-group (MUST NOT run on)
ensure_rule() {
  local name=$1 vm_group=$2 flag=$3
  govc cluster.rule.ls -cluster "${cluster_path}" -name "${name}" > /dev/null 2>&1 && return 0
  run govc cluster.rule.create -cluster "${cluster_path}" -name "${name}" -enable -mandatory -vm-host \
    -vm-group "${vm_group}" "${flag}" "${host_group}" && say "DRS rule ${name} created (${vm_group} ${flag#-host-})"
}

ensure_all() {
  compute_sets
  ensure_host_group
  ensure_vm_group "${specific_group}" "${specific_paths[@]}"
  ensure_vm_group "${other_group}" "${other_paths[@]}"
  ensure_rule "${rule_specific}" "${specific_group}" -host-affine-group
  ensure_rule "${rule_other}" "${other_group}" -host-anti-affine-group
}

set_rules_enabled() {
  local enabled=$1 rule
  for rule in "${rule_specific}" "${rule_other}"; do
    govc cluster.rule.ls -cluster "${cluster_path}" -name "${rule}" > /dev/null 2>&1 \
      && govc cluster.rule.change -cluster "${cluster_path}" -name "${rule}" -enable="${enabled}"
  done
}

if [ "${mode}" == "--cron" ]; then
  mkdir -p "${state_dir}"
  host_state="$(govc object.collect -s "${host_path}" runtime.connectionState 2>/dev/null) maintenance=$(govc object.collect -s "${host_path}" runtime.inMaintenanceMode 2>/dev/null)"
  if [ "${host_state}" != "connected maintenance=false" ]; then
    # also covers vCenter not answering (empty state): only act after 3 runs in a row
    bad_runs=$(( $(cat "${state_dir}/bad_runs" 2>/dev/null || echo 0) + 1 ))
    echo "${bad_runs}" > "${state_dir}/bad_runs"
    if [ ${bad_runs} -ge 3 ] && [ ! -f "${state_dir}/rules_disabled" ] && [[ "${host_state}" != " maintenance=" ]]; then
      set_rules_enabled false && touch "${state_dir}/rules_disabled"
      say "ERROR: ${dedicated_fqdn} is not usable (${host_state}), the two DRS rules are disabled until it is back"
    fi
    exit 0
  fi
  echo 0 > "${state_dir}/bad_runs"
  if [ -f "${state_dir}/rules_disabled" ]; then
    set_rules_enabled true && rm -f "${state_dir}/rules_disabled"
    say "${dedicated_fqdn} is back, the two DRS rules are enabled again"
  fi
  ensure_all
  exit 0
fi

# ---- --place / --dry-run ----
drs=$(govc object.collect -json "${cluster_path}" configurationEx 2>/dev/null | jq -r '.. | objects | select(has("defaultVmBehavior")) | "\(.enabled) \(.defaultVmBehavior)"' | head -1)
[ "${drs}" == "true fullyAutomated" ] || say "WARNING: DRS on ${cluster_path} is '${drs:-unknown}', not 'true fullyAutomated': the rules will not move VMs by themselves"

compute_sets
ensure_host_group
ensure_vm_group "${specific_group}" "${specific_paths[@]}"
ensure_vm_group "${other_group}" "${other_paths[@]}"

# Explicit vMotion first (the rules come last, so DRS does not race these moves): other VMs off the dedicated host, then
# vCenter and VCF Automation onto it. govc vm.migrate returns when the vMotion is done.
mapfile -t other_hosts < <(govc find "${cluster_path}" -type h 2>/dev/null | grep -vxF "${host_path}")
next_target=0
deadline=$(( $(date +%s) + place_timeout_sec ))
placed="false"
while true; do
  compute_sets
  declare -A path_of=()
  for p in "${specific_paths[@]}" "${other_paths[@]}"; do path_of["${p##*/}"]="${p}"; done
  misplaced=0
  while IFS=$'\t' read -r vm_name vm_host; do
    [ "${vm_host}" == "${dedicated_fqdn}" ] || continue
    misplaced=$((misplaced+1))
    target="${other_hosts[$((next_target % ${#other_hosts[@]}))]}"; next_target=$((next_target+1))
    say_quiet "moving ${vm_name} off ${dedicated_fqdn} to ${target##*/}"
    run govc vm.migrate -host "${target}" "${path_of[${vm_name}]}" || say_quiet "WARNING: vMotion of ${vm_name} failed, will retry"
  done < <(vm_hosts "${other_paths[@]}")
  while IFS=$'\t' read -r vm_name vm_host; do
    [ "${vm_host}" == "${dedicated_fqdn}" ] && continue
    misplaced=$((misplaced+1))
    say_quiet "moving ${vm_name} from ${vm_host} onto ${dedicated_fqdn}"
    run govc vm.migrate -host "${host_path}" "${path_of[${vm_name}]}" || say_quiet "WARNING: vMotion of ${vm_name} failed, will retry"
  done < <(vm_hosts "${specific_paths[@]}")
  if [ ${misplaced} -eq 0 ]; then placed="true"; break; fi
  [ "${mode}" == "--dry-run" ] && break
  [ $(date +%s) -ge ${deadline} ] && break
  sleep 30
done

ensure_rule "${rule_specific}" "${specific_group}" -host-affine-group
ensure_rule "${rule_other}" "${other_group}" -host-anti-affine-group
if [ "${mode}" == "--dry-run" ]; then
  echo "DRY-RUN: ${#specific_paths[@]} specific VMs, ${#other_paths[@]} other VMs, ${misplaced} would be moved"
elif [ "${placed}" == "true" ]; then
  say "dedicated host placement done: vCenter and VCF Automation are on ${dedicated_fqdn}, no other VM is"
else
  say "ERROR: dedicated host placement not finished after ${place_timeout_sec} s (${misplaced} VM(s) still misplaced): the groups and rules are in place, the cron and DRS keep working on it"
fi
exit 0
