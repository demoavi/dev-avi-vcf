#!/bin/bash
# vSAN health alarm silencing (merged from the reference project's vcenter/silent_alarm.sh).
# Part of the split-up vcf_bootstrap.sh (see 00-lib.sh for why) - run
# standalone as:
#   bash 09-vsan-alarm.sh /home/ubuntu/json/deployment.json
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-lib.sh"
log_notify "09-vsan-alarm.sh started"
#
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
# later `rvc user:password@host` line is untouched: that embedded-password
# form is RVC's own real, documented login syntax, not ssh's.
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
expect " ]$ " { send "rvc $env(VC_SSO_USER):$password@$env(VC_HOST) -a -q\r" }
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
log_notify "VCF-I: vSAN health alarm silencing applied on ${basename_sddc}-vc01.${domain}"

log_notify "09-vsan-alarm.sh complete"
