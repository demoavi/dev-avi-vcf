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
shift
# Optional manual control: --from <phase> runs that phase and every phase after it, --only <phase> runs that one phase.
# Both ignore sddc.stop_before_phase (below), which only applies to an automatic run.
start_from=""
only_phase=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) start_from="${2:-}"; shift; shift ;;
    --only) only_phase="${2:-}"; shift; shift ;;
    *) echo "usage: vcf_bootstrap.sh <json file> [--from <phase> | --only <phase>]" >&2; exit 2 ;;
  esac
done
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
# purely local Linux account setup on gw itself), immediately followed by
# gw-org-api.sh (vApp only, opt-in: the org-assignment API that hands out
# the accounts gw-accounts.sh just created); vault-pki-bootstrap.sh
# runs right after it (it has zero dependency on the SDDC build pipeline
# and only needs to finish before vcfa_tenant_bootstrap.sh, which reads
# its root token); and vSAN health alarm silencing moved into
# vcenter-bootstrap.sh (see that script's own comment) rather than staying
# in its original, much later position. Demo Gateway/Ingress/workload yaml
# rendering also used to run here as its own first-phase script
# (vks-yaml-rendering.sh) but has since moved into
# vcfa_provider_bootstrap.sh's own per-org loop - the per-Kind hostnames
# it renders have to be unique PER ORG (Avi is one shared, provider-
# managed controller), so it needs org_name in scope, which only that
# script's loop has. Per-org Avi tenant-admin accounts (former
# avi-accounts.sh) and the vCenter per-org SSO account/namespace-visibility
# scoping (former "readonly" SSO account section of vcenter-bootstrap.sh)
# have both moved into vcfa_tenant_bootstrap.sh's own final per-org loop
# instead - both need each org's Avi tenant/namespace to already exist,
# which only that script (not vcfa_provider_bootstrap.sh) can guarantee
# without a separate existence-poll as their own phase. The two VCFA
# scripts were themselves one single configure_vcfa.sh until 2026-09-28 -
# split along this same provider-portal/org-portal line once it grew past
# 1800 lines (see vcfa_provider_bootstrap.sh's own header for the split
# rationale and cross-script variable dependencies).
#
# Each call aborts the whole pipeline on a non-zero exit - a later phase
# almost always assumes an earlier one actually succeeded (e.g. NSX/Avi
# config assumes the SDDC actually got built), so silently continuing
# past a failed phase would just fail more confusingly, several phases
# later, with a much less obvious root cause.
#
# supervisor-bootstrap runs before k8s-bootstrap/git-bootstrap on purpose: it creates Harbor and pushes the ISO-delivered
# images (Gitea's among them), which git-bootstrap then pulls from Harbor instead of the Internet. Nothing in the
# Supervisor depends on the k8s cluster.
# gw-blueprint-api (gw-local, both use cases) runs right after gw-org-api: it needs nothing from the SDDC build, and it
# creates the HMAC secret and certificate the Supervisor side needs. supervisor-blueprint-watcher runs LAST: it needs the
# org namespaces and their labels (vcfa_tenant_bootstrap) and the uploaded blueprints, so the watcher's first post already
# finds them and fills the dropdown (the blueprint rewrite itself is gw-blueprint-api's runtime job, not a step).
# vcfa-stabilize (soft-fail) runs right after vcf-installer-bootstrap: VCF Automation exists from then on and nothing talks to it
# until vcfa_provider_bootstrap, whose first step is a health gate that waits for the platform to be calm again.
phases="gw-accounts gw-org-api gw-blueprint-api vault-pki-bootstrap esxi-bootstrap vcf-installer-bootstrap vcfa-stabilize vcenter-bootstrap nsx-bootstrap avi-bootstrap nsx-project-vpc supervisor-bootstrap k8s-bootstrap git-bootstrap vcfa_provider_bootstrap vcfa_tenant_bootstrap supervisor-blueprint-watcher"

# stop_before_phase (CR sddc.stop_before_phase, "" = off) pauses an automatic run before that phase - e.g. while something that phase
# needs is not ready yet. A typo would silently never stop, so every phase name given is checked before anything runs.
[ "${stop_before_phase:-}" == "null" ] && stop_before_phase=""
for phase_name in "${stop_before_phase:-}" "${start_from}" "${only_phase}"; do
  [ -z "${phase_name}" ] && continue
  case " ${phases} " in
    *" ${phase_name} "*) ;;
    *) log_notify "ERROR: unknown phase '${phase_name}' (stop_before_phase, --from or --only); phases: ${phases}"; exit 1 ;;
  esac
done

started="false"
[ -z "${start_from}" ] && started="true"
for phase in ${phases}; do
  if [ -n "${only_phase}" ]; then
    [ "${phase}" == "${only_phase}" ] || continue
  else
    if [ "${started}" != "true" ]; then
      [ "${phase}" == "${start_from}" ] && started="true" || continue
    fi
    if [ -z "${start_from}" ] && [ "${phase}" == "${stop_before_phase:-}" ]; then
      log_notify "vcf_bootstrap.sh paused before ${phase}.sh (stop_before_phase=${phase}). Resume: cd ${script_dir} && bash vcf_bootstrap.sh ${jsonFile} --from ${phase} (or --only <phase> for a single phase)"
      exit 0
    fi
  fi
  bash "${script_dir}/${phase}.sh" "${jsonFile}"
  phase_exit=$?
  if [ ${phase_exit} -ne 0 ]; then
    log_notify "ERROR: ${phase}.sh failed (exit code ${phase_exit}), aborting vcf_bootstrap.sh"
    exit 1
  fi
done
