#!/bin/bash
#
# MANUAL tool, NOT a phase: runs vcfa_org.sh for EVERY org of the spec, one after the other. On the gw as ubuntu.
#
#   vcfa_org_all.sh delete [--yes] [--force] [--dry-run] [--json <file>]   every org of the spec that is not marked deleted yet
#                                  --force: also the orgs already handed to a student by gw-org-api (vcfa_org.sh refuses those without it)
#   vcfa_org_all.sh add    [--yes] [--dry-run] [--json <file>]   every org of the spec that is marked deleted (/home/<org>/.delete)
#   vcfa_org_all.sh status [--json <file>]                       one summary line per org of the spec (marker, namespaces, VKS clusters)
#
# The orgs come from vcf_a_organizations (the spec, which delete never edits); the state comes from the markers vcfa_org.sh delete leaves,
# so after "delete" everything is hidden and a later "add" brings back exactly those: the state needs no file of its own and travels with
# the gw's disk. Sequential on purpose (each run re-runs the watcher and the gw account phases; two at once are not supported), and it
# stops at the first org that fails, so the rest is untouched and the run can simply be started again. Not parallel: expect about
# 4 minutes per org for delete and 20-30 for add (its VKS cluster).

action="${1:-}"; shift
case "${action}" in delete|add|status) ;; *) sed -n 3,16p "$0"; exit 1 ;; esac
yes=""; dry=""; force=""; jsonFile="${JSON_FILE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) yes="--yes"; shift ;;
    --dry-run) dry="--dry-run"; shift ;;
    --force) force="--force"; shift ;;
    --json) jsonFile="${2:?--json needs a file}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -z "${jsonFile}" ] && [ -f /home/ubuntu/json/deployment.json ] && jsonFile=/home/ubuntu/json/deployment.json
[ -z "${jsonFile}" ] && jsonFile=$(ls -t /home/ubuntu/json/*_apply.json 2> /dev/null | head -1)
[ -f "${jsonFile}" ] || { echo "no deployment json found (use --json <file>)" >&2; exit 1; }

source /home/ubuntu/bash/variables.sh < /dev/null
VCFA_KEEP_DELETED=1   # the spec as it is, deleted orgs included (functions.sh would hide them)
source "${script_dir}/functions.sh"
orgs=$(echo "${vcf_a_organizations}" | jq -r '.[].name')
[ -n "${orgs}" ] || { echo "no org in the spec (vcf_a_organizations)" >&2; exit 1; }
say() { echo "$(date "+%Y-%m-%d,%H:%M:%S"), vcfa_org_all ${action}: $*" | tee -a /home/ubuntu/vcf_bootstrap.log; }
marked() { [ -e "/home/${1}/.delete" ]; }

todo=""
for o in ${orgs}; do
  case "${action}" in
    delete) marked "${o}" || todo="${todo} ${o}" ;;
    add) marked "${o}" && todo="${todo} ${o}" ;;
    status) todo="${todo} ${o}" ;;
  esac
done
todo="${todo# }"

if [ "${action}" == "status" ]; then
  for o in ${todo}; do
    line=$(bash "${script_dir}/vcfa_org.sh" status "${o}" --json "${jsonFile}" 2> /dev/null | awk -F'|' '$1 ~ /^(deleted-marker|vcfa-org|namespaces|vks-clusters)$/ {printf "%s=%s(%s) ", $1, $2, $3}')
    echo "${o}: ${line}"
  done
  exit 0
fi

# Preflight (delete): the orgs a student holds (/home/<org>/.assigned written by gw-org-api; vcfa_org.sh refuses them without --force). Without --force
# nothing at all is deleted while one exists: all or nothing, not "the orgs before the first assigned one". A marker written by an earlier delete or
# cleaning run is our own claim, not a student's (same test as vcfa_org.sh).
assigned=""
if [ "${action}" == "delete" ]; then
  for o in ${todo}; do
    id "${o}" > /dev/null 2>&1 || continue
    sudo test -e "/home/${o}/.assigned" || continue
    sudo grep -qE "to (vcfa_org delete|vcfa_tenant_cleaning)" "/home/${o}/.assigned" 2> /dev/null && continue
    assigned="${assigned} ${o} ($(sudo head -1 "/home/${o}/.assigned" 2> /dev/null | cut -c1-80))"
  done
  if [ -n "${assigned}" ] && [ -z "${force}" ]; then
    say "ERROR: assigned to a student:${assigned}. Nothing was deleted. Run again with --force to delete them anyway."
    exit 2
  fi
  [ -n "${assigned}" ] && say "WARNING: --force: deleting orgs that are assigned to a student:${assigned}"
fi
[ -n "${todo}" ] || { say "nothing to do: every org of the spec is already $([ "${action}" == "delete" ] && echo deleted || echo present) (orgs in the spec: $(echo ${orgs}))"; exit 0; }
say "orgs to ${action}, in this order: ${todo}"
done_orgs=""
for o in ${todo}; do
  say "---- ${o}"
  if bash "${script_dir}/vcfa_org.sh" "${action}" "${o}" ${yes} ${force} ${dry} --json "${jsonFile}"; then
    done_orgs="${done_orgs} ${o}"
  else
    say "ERROR: ${action} ${o} failed: stopping here. Done: ${done_orgs:-none}. Not started: the orgs after ${o} in the list above. Run the same command again to continue (an org that is assigned to a student needs --force)."
    exit 1
  fi
done
say "done: ${action} ${done_orgs# }"
exit 0
