#!/bin/bash
#
# VCF Automation stabilization phase (soft-fail). Runs right after vcf-installer-bootstrap.sh, i.e. as soon as the SDDC
# build has delivered VCF Automation and before anything else talks to it (nothing between this phase and
# vcfa_provider_bootstrap.sh uses VCF-A). Opens an SSH session to the single VCF-A node and runs vcfa-stabilize-node.sh
# there: leader-election / kube-vip / probe / etcd settings that keep the platform's own CPU bursts (load 100-500 for
# ~30 s on the nested lab) from restarting every controller and dropping the VIPs. What and why: see the header of
# vcfa-stabilize-node.sh and the scripts README.
#
# Soft-fail: any problem (node not found, SSH refused, remote error) is logged and the phase exits 0, because the
# pipeline works without it - only the platform's resilience to its own bursts depends on it. The health gate at the
# top of vcfa_provider_bootstrap.sh then waits for the platform to be calm before the provider work starts.
#
# Environment knobs (not CR fields): vcfa_stabilize=false skips the phase, vcfa_ssh_user (default vmware-system-user, the
# node's sudo-capable login), vcfa_stabilize_load_max (default 20) / vcfa_stabilize_load_wait_sec (default 600): the node
# script waits that long for load1 to drop below the limit and then applies anyway.
#
# Access: the node is one of the addresses of the VCF-A IP pool (spec.vcf_automation.ip_pool; the control-plane VIP takes
# one of them too, so the node is the one that answers SSH and has the static pod manifests). Login is the VCF-A
# admin password (generic_password, the same one the installer spec hands to VCF Automation). The password goes through
# sshpass' environment variable and sudo's stdin, never on a command line.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

log_file="/home/ubuntu/vcf_bootstrap.log"
touch "${log_file}"
slack_webhook=""

warn() { log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vcfa-stabilize: $1" "${log_file}" "${slack_webhook}" "${google_webhook}"; }

if [ "${vcfa_stabilize:-true}" != "true" ]; then
  warn "skipped (vcfa_stabilize=false)"
  exit 0
fi
command -v sshpass >/dev/null 2>&1 || { warn "sshpass is not installed, skipped"; exit 0; }

ssh_user="${vcfa_ssh_user:-vmware-system-user}"
export SSHPASS="${generic_password}"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive)

# Runs a command as root on <ip>: ssh as ${ssh_user}, sudo reads its password from stdin.
node_root() { # ip command...
  local ip="$1"; shift
  printf '%s\n' "${SSHPASS}" | sshpass -e ssh "${ssh_opts[@]}" "${ssh_user}@${ip}" "sudo -S -p '' $*" 2>&1 | grep -vaE 'Welcome to Photon|Last login'
  return "${PIPESTATUS[1]}"
}

#
# Find the node: the pool address that answers SSH and carries the control-plane static pod manifests. Nodes are counted by
# machine, not by address: the control-plane VIP (kube-vip, a /32 on the node's NIC) answers SSH as the very node that holds it,
# so two pool addresses can be one node. Per machine id the node's own address is kept (the VIP only if nothing else answers),
# because the VIP can move.
#
declare -A node_ip_of_id node_is_vip
for ip in $(echo "${pool_ip_vcf_auto:-[]}" | jq -r '.[]'); do
  node_root "${ip}" "test -f /etc/kubernetes/manifests/etcd.yaml" >/dev/null 2>&1 || continue
  machine_id=$(node_root "${ip}" "cat /etc/machine-id" 2>/dev/null | tr -d '[:space:]')
  [ -n "${machine_id}" ] || machine_id="address-${ip}"
  is_vip="false"
  node_root "${ip}" "ip -4 -o addr show" 2>/dev/null | grep -q " ${ip}/32" && is_vip="true"
  if [ -z "${node_ip_of_id[${machine_id}]:-}" ] || { [ "${node_is_vip[${machine_id}]}" == "true" ] && [ "${is_vip}" == "false" ]; }; then
    node_ip_of_id[${machine_id}]="${ip}"
    node_is_vip[${machine_id}]="${is_vip}"
  fi
done
nodes=$(echo ${node_ip_of_id[@]})
node_count=${#node_ip_of_id[@]}
if [ "${node_count}" -eq 0 ]; then
  warn "no VCF Automation node found in the pool ${pool_ip_vcf_auto:-?} (SSH as ${ssh_user} with the admin password failed, or the node has no control-plane manifests), skipped - the platform runs without the stabilization"
  exit 0
fi
if [ "${node_count}" -gt 1 ]; then
  warn "${node_count} control-plane nodes found (${nodes}), only the single-node layout is supported, skipped"
  exit 0
fi

warn "VCF Automation node ${nodes}, applying the stabilization (static pod edits restart the API server for ~2 minutes)"
if ! sshpass -e scp "${ssh_opts[@]}" "${script_dir}/vcfa-stabilize-node.sh" "${ssh_user}@${nodes}:/tmp/vcfa-stabilize-node.sh" >> "${log_file}" 2>&1; then
  warn "copying the node script to ${nodes} failed, skipped"
  exit 0
fi
node_root "${nodes}" "bash /tmp/vcfa-stabilize-node.sh apply ${vcfa_stabilize_load_max:-20} ${vcfa_stabilize_load_wait_sec:-600}" >> "${log_file}" 2>&1
node_rc=$?
node_root "${nodes}" "rm -f /tmp/vcfa-stabilize-node.sh" >/dev/null 2>&1
if [ ${node_rc} -ne 0 ]; then
  warn "the node script exited ${node_rc}, see ${log_file} above for its output, continuing"
else
  warn "done on ${nodes}"
fi
exit 0
