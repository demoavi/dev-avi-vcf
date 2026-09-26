#!/bin/bash
# Runs as ubuntu (see gw-setup.sh.tpl's launch line).
export HOME=/home/ubuntu
# The real fix for govc's "open root: permission denied": govc treats
# GOVC_USERNAME/GOVC_PASSWORD as a possible file path and tries
# os.ReadFile(value) first (session.Secret() in govmomi) - with
# GOVC_USERNAME=root that's a *relative* path, so if CWD is "/" (plausible
# for a cloud-init runcmd-launched background process) it resolves to
# /root, root's 0700 home dir. As ubuntu that's EACCES, which govc
# propagates as a hard error instead of silently falling back to the
# literal "root" username (it only falls back on ENOENT). As root the same
# open() hits EISDIR instead (root can read /root's own dir entry, just not
# open it as a file), which isn't a permission error, so it silently falls
# back and never surfaced before this script ran as ubuntu. Pinning CWD
# somewhere ubuntu-writable with no coincidentally-named files sidesteps it
# entirely, regardless of whatever CWD cloud-init happened to launch us in.
cd /home/ubuntu || exit 1
jsonFile=${1}
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
templates_dir="${script_dir}/../templates"
mkdir -p /home/ubuntu/html /home/ubuntu/json
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

# VCD session, established up front - see vcd_login() in functions.sh.
# Every phase script below also calls this itself (each announces its own
# "started" via log_notify at its own top, and does its own error
# reporting) - kept here too only for this orchestrator's own two
# remaining log_notify uses: the DNS/NTP check below, and the abort path
# if a phase script fails (see the per-phase checks further down).
vcd_login

# DNS (bind9) and NTP (chrony) health check - both are set up earlier in
# gw's own cloud-init, well before this script is launched, so a failure
# here means gw's own network services never came up correctly. Moved here
# (rather than a standalone check inside cloud-init) so it can reuse
# log_notify's existing gchat + VCD metadata reporting instead of
# duplicating that logic.
if ! systemctl status bind9.service > /dev/null 2>&1; then
  log_notify "ERROR: DNS (bind9.service) is not running"
fi
if ! systemctl status chrony.service > /dev/null 2>&1; then
  log_notify "ERROR: NTP (chrony.service) is not running"
fi

#
# From here on, every remaining phase runs as its own separate, self-
# contained script (each independently sources variables.sh/functions.sh,
# calls vcd_login itself, and announces its own "started" via log_notify
# at its own top) rather than being inlined - keeps this orchestrator
# thin and each phase independently testable/re-runnable. Order matters
# and follows the original monolith's own sequence exactly (each phase's
# comments above document its own real dependencies on the ones before
# it), with three exceptions made deliberately: gw-accounts.sh now runs
# first of all (it has zero dependency on anything else in this loop -
# purely local Linux account setup on gw itself); vault-pki-bootstrap.sh
# runs right after it (it has zero dependency on the SDDC build pipeline
# and only needs to finish before configure_vcfa.sh at the very end); and vSAN
# health alarm silencing moved into vcenter-bootstrap.sh (see that
# script's own comment) rather than staying in its original, much later
# position. Demo Gateway/Ingress/workload yaml rendering also used to run
# here as its own first-phase script (vks-yaml-rendering.sh) but has
# since moved into configure_vcfa.sh's own per-org loop - the per-Kind
# hostnames it renders have to be unique PER ORG (Avi is one shared,
# provider-managed controller), so it needs org_name in scope, which only
# configure_vcfa.sh's loop has.
#
# Each call aborts the whole pipeline on a non-zero exit - a later phase
# almost always assumes an earlier one actually succeeded (e.g. NSX/Avi
# config assumes the SDDC actually got built), so silently continuing
# past a failed phase would just fail more confusingly, several phases
# later, with a much less obvious root cause.
#
for phase in gw-accounts vault-pki-bootstrap esxi-bootstrap vcf-installer-bootstrap vcenter-bootstrap nsx-bootstrap avi-bootstrap nsx-project-vpc supervisor-bootstrap configure_vcfa; do
  bash "${script_dir}/${phase}.sh" "${jsonFile}"
  phase_exit=$?
  if [ ${phase_exit} -ne 0 ]; then
    log_notify "ERROR: ${phase}.sh failed (exit code ${phase_exit}), aborting vcf_bootstrap.sh"
    exit 1
  fi
done
