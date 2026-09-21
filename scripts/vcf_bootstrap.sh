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

# VCD session, established up front (not just before the ESX power-cycle
# step) so log_notify below can use it too - see vcd_login() in
# functions.sh, called by every phase script (including this orchestrator
# itself) that wants log_notify's VCD-metadata progress reporting to work.
vcd_login

log_notify "vcf_bootstrap.sh started"

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
# contained script (each independently sources variables.sh/functions.sh
# and calls vcd_login itself) rather than being inlined - keeps this
# orchestrator thin and each phase independently testable/re-runnable.
# Order matters and follows the original monolith's own sequence exactly
# (each phase's comments above document its own real dependencies on the
# ones before it), with two exceptions made deliberately: vault-pki-
# bootstrap.sh now runs first (it has zero dependency on the SDDC build
# pipeline and only needs to finish before configure_vcfa.sh at the very
# end); and vSAN health alarm silencing moved into vcenter-bootstrap.sh
# (see that script's own comment) rather than staying in its original,
# much later position. Demo Gateway/Ingress/workload yaml rendering also
# used to run here as its own first-phase script (vks-yaml-rendering.sh)
# but has since moved into configure_vcfa.sh's own per-org loop - the
# per-Kind hostnames it renders have to be unique PER ORG (Avi is one
# shared, provider-managed controller), so it needs org_name in scope,
# which only configure_vcfa.sh's loop has.
#
bash "${script_dir}/vault-pki-bootstrap.sh" "${jsonFile}"
bash "${script_dir}/esxi-bootstrap.sh" "${jsonFile}"
bash "${script_dir}/vcf-installer-bootstrap.sh" "${jsonFile}"
bash "${script_dir}/vcenter-bootstrap.sh" "${jsonFile}"
bash "${script_dir}/nsx-bootstrap.sh" "${jsonFile}"
bash "${script_dir}/avi-bootstrap.sh" "${jsonFile}"
bash "${script_dir}/nsx-project-vpc.sh" "${jsonFile}"
bash "${script_dir}/supervisor-bootstrap.sh" "${jsonFile}"

log_notify "vcf_bootstrap.sh complete (SDDC build + vCenter port groups + NSX config + Avi deployment + Avi configuration + Avi upgrade + NSX Project/VPC + vSAN alarm silencing + Supervisor enablement - full pipeline, no remaining standalone stages)"

#
# VCFA org provisioning - split into its own script (configure_vcfa.sh),
# run as its own process rather than inlined here, matching the reference
# project's own separate configure_vcfa.sh. Entirely optional - that
# script is already a no-op throughout if spec.sddc.vcf_a is unset. Must
# run after vault-pki-bootstrap.sh above (not just after it in file
# order) - the org-provisioning loop reads Vault's root token for per-org
# vault_integration setup, so Vault has to already be up; this is
# guaranteed here since vault-pki-bootstrap.sh is a synchronous call that
# already completed before we ever reach this line.
#
bash "${script_dir}/configure_vcfa.sh" "${jsonFile}"
