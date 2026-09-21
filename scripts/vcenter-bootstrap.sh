#!/bin/bash
#
# vCenter port-group creation (govc) and vSAN health alarm silencing - both pure vCenter operations, run together as one script. vSAN alarm silencing moved here (was much later, after Avi/NSX Project/VPC in the original monolith) since it has no dependency on either - its only real constraint is running before Supervisor enablement, already satisfied by running early.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"
vcd_login


#
# port groups (merged from the reference project's vcenter/vcsa.sh - content
# library creation/OVA upload deliberately dropped, same as the earlier
# Cloud Builder/9.0 branches: VCF 9.1-only scope, so the EDGE_OVERLAY
# portgroup that reference script only creates for 9.0/8.0U3b is skipped
# too. govc here talks to the newly-built nested vCenter, not an ESXi host
# directly - GOVC_CLUSTER is unset since portgroups sit on the vDS itself,
# independent of any specific cluster. Folded back in here (rather than
# staying its own 0N-*.sh) once confirmed working against a live build -
# no reason to make this one a separate manual step.
#
export GOVC_URL="${basename_sddc}-vc01.${domain}"
export GOVC_USERNAME="administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)"
export GOVC_PASSWORD="${generic_password}"
export GOVC_DATACENTER="${basename_sddc}-dc"
export GOVC_INSECURE=true
export GOVC_PERSIST_SESSION=false
unset GOVC_CLUSTER
vds_name="${basename_sddc}-vds-01"

external_vlan_id=$(jq -c -r --arg arg "EXTERNAL" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)
pg_error=$(govc dvs.portgroup.add -dvs "${vds_name}" -vlan "${external_vlan_id}" "${basename_sddc}-pg-external" 2>&1)
if [ $? -ne 0 ]; then
  log_notify "ERROR: govc dvs.portgroup.add ${basename_sddc}-pg-external failed: ${pg_error}"
else
  log_notify "portgroup ${basename_sddc}-pg-external created (vlan ${external_vlan_id})"
fi

pg_error=$(govc dvs.portgroup.add -dvs "${vds_name}" -vlan-mode=trunking "${basename_sddc}-edge-uplink1" 2>&1)
if [ $? -ne 0 ]; then
  log_notify "ERROR: govc dvs.portgroup.add ${basename_sddc}-edge-uplink1 failed: ${pg_error}"
else
  log_notify "portgroup ${basename_sddc}-edge-uplink1 created (trunking)"
fi

# vSAN health alarm silencing (merged from the reference project's
# vcenter/silent_alarm.sh + templates/silence_vsan_expect_script.sh.template)
# - needed for Tanzu/Supervisor enablement, which checks vSAN health as a
# prerequisite and would otherwise flag/block on checks a NESTED vSAN can
# never pass (controller driver/firmware/HCL support are meaningless for
# virtualized disk controllers). Retargeted from the reference's "outer
# host vCenter" (a vCenter/govc-managed physical layer this project has no
# equivalent of - everything outer-layer here is VCD-managed) to OUR own
# nested vCenter instead, which has exactly the same class of vSAN alarm
# noise. Also fixes what looks like a bug in the reference's own SSH
# invocation - it embeds a password directly into the ssh destination
# argument ("user@domain:password@host", not valid SSH syntax, and
# redundant anyway since the very next expect step still waits for an
# interactive password prompt) - with a clean `-l` username instead. The
# later `rvc user:password@host` line keeps that embedded-password form
# (RVC's own real, documented login syntax, not ssh's), but the password
# itself needs single-quoting there - confirmed live: this project's
# generic_password contains "!", and bash's interactive history expansion
# (the shell this gets typed into, via "pi shell") treats an unquoted "!"
# as a history-substitution trigger ("event not found"), silently
# preventing rvc from ever launching and leaving every subsequent
# vsan.health.silent_health_check_configure command typed into a bare
# bash prompt instead of rvc's. The reference project's own template
# already single-quotes the password for exactly this reason - this port
# had dropped those quotes.
#
export VC_ROOT_PASSWORD="${generic_password}"
export VC_SSO_USER="administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)"
export VC_HOST="${basename_sddc}-vc01.${domain}"
export VC_DC="${basename_sddc}-dc"
export VC_CLUSTER="${basename_sddc}-cluster"
expect <<'VSAN_EXPECT_EOF'
set timeout 60
set password $env(VC_ROOT_PASSWORD)
spawn ssh -tt -o StrictHostKeyChecking=no -l $env(VC_SSO_USER) $env(VC_HOST)
expect "assword:" { send "$password\r" }
expect "and>" { send "com.vmware.appliance.version1.access.shell.set --enabled true\r" }
expect "and> " { send "shell\r" }
expect " ]$ " { send "rvc $env(VC_SSO_USER):'$password'@$env(VC_HOST) -a -q\r" }
expect "> " { send "vsan.health.silent_health_check_configure -a controllerdriver $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a controllerdiskmode $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a controllerfirmware $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a controllerreleasesupport $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a controlleronhcl $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a upgradelowerhosts $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a perfsvcstatus $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "exit\n" }
expect " ]$ " { send "exit\n" }
expect "and> " { send "exit\n" }
expect eof
VSAN_EXPECT_EOF
unset VC_ROOT_PASSWORD VC_SSO_USER VC_HOST VC_DC VC_CLUSTER
log_notify "vSAN health alarm silencing applied on ${basename_sddc}-vc01.${domain}"
