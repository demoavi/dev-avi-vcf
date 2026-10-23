#!/bin/bash
#
# MANUAL tool, NOT a phase of vcf_bootstrap.sh: cleans VCF Automation orgs back to a fresh state, then hands them back to
# the org-assignment API (gw-org-api) so a student can claim them again. Run it on the gw as ubuntu.
#
#   vcfa_tenant_cleaning.sh [--org <org-name>] [--yes] [--dry-run] [--no-recreate]
#
#   (no --org)    every org that is still FREE in gw-org-api (GET /orgs); orgs already assigned to a student are listed
#                 and left alone.
#   --org <name>  only that org, even when it is assigned (the warning says so).
#   --yes         skip the confirmation prompt (the warning is still printed).
#   --dry-run     print what would be done, change nothing (no claim, no deletion, no release).
#   --no-recreate do not rerun vcfa_tenant_bootstrap.sh at the end (the orgs are then released WITHOUT namespace/VKS).
#
# Per org, in this order:
#   1. Claim it so nobody else takes it meanwhile: POST /org for the free orgs (it always hands out the lowest free one),
#      a root-created /home/<org>/.assigned for --org (the API cannot target a given org; same file the API writes).
#   2. Git: ONE commit on the org's Gitea repo leaving only <git_sample_path>/<git_sample_configmap>.yaml (the repo is
#      what the org's ArgoCD syncs, so this also removes the demo apps - ArgoCD prunes them if auto-prune is on).
#   3. AKO: in each VKS cluster set deleteConfig=true in AKO's ConfigMap (AKO then deletes everything it created in
#      Avi), then wait until the org's Avi tenant has no virtual service left.
#   4. Delete every instance (deployment) of the org's VCF-A project: the VMs the blueprints created.
#   5. Delete every VKS cluster of the org's namespaces, then every namespace of the org (waits for each).
# Then, once for all cleaned orgs: rerun vcfa_tenant_bootstrap.sh (idempotent: it recreates the namespace, the VKS
# cluster, ArgoCD, cert01, blueprints... for any org that lacks them), and finally release each cleaned org
# (rm /home/<org>/.assigned). An org whose cleaning failed is NOT released: it stays claimed for you to look at.
#
# Credentials: everything comes from /home/ubuntu/bash/variables.sh (admin password = generic_password, org password
# derived like everywhere else) - nothing is hardcoded here.

case "${1:-}" in -h|--help) sed -n 2,31p "$0"; exit 0 ;; esac
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"
log_file="/home/ubuntu/vcfa_tenant_cleaning.log"
slack_webhook=""
jsonFile="${JSON_FILE:-/home/ubuntu/json/deployment.json}"   # what vcf_bootstrap.sh is launched with; vcfa_tenant_bootstrap.sh reads it
touch "${log_file}"

only_org=""; assume_yes="false"; dry_run="false"; recreate="true"
while [ $# -gt 0 ]; do
  case "$1" in
    --org) only_org="${2:-}"; [ -n "${only_org}" ] || { echo "--org needs an org name" >&2; exit 1; }; shift 2 ;;
    --yes) assume_yes="true"; shift ;;
    --dry-run) dry_run="true"; shift ;;
    --no-recreate) recreate="false"; shift ;;
    -h|--help) sed -n 2,31p "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 1 ;;
  esac
done

say() { local m="$(date "+%Y-%m-%d,%H:%M:%S"), vcfa_tenant_cleaning: $*"; echo "${m}"; echo "${m}" >> "${log_file}"; }
die() { say "ERROR: $*"; exit 1; }
# do_it <description> <command...>: runs the command, or only prints it with --dry-run
do_it() { local d="$1"; shift; if [ "${dry_run}" == "true" ]; then say "[dry-run] would: ${d}"; return 0; fi; "$@"; }

for tool in curl jq kubectl sudo base64 sha256sum; do command -v "${tool}" > /dev/null 2>&1 || die "${tool} is not installed"; done
[ -n "${org_api_username}" ] && [ -n "${org_api_password}" ] || die "the org API is not configured (spec.vms.gw.org_api): nothing to claim orgs with"
org_api_url="https://localhost:${org_api_port:-8443}"
org_api_curl() { curl -sk -m 30 -u "${org_api_username}:${org_api_password}" "$@"; }

VCFA_HOST="https://${basename_sddc}-auto-vip.${domain}"
VCFA_VERSION="9.1.0"
ACCEPT="Accept: application/json;version=${VCFA_VERSION}"
CONTENT_TYPE="Content-Type: application/json;version=${VCFA_VERSION}"
assigned_file() { echo "/home/${1}/.assigned"; }

#
# 1. Which orgs: the configured ones, minus (without --org) those a student already holds.
#
all_orgs=$(echo "${vcf_a_organizations}" | jq -r '.[].name')
free_orgs=$(org_api_curl "${org_api_url}/orgs" | jq -r '.orgs[]?') || die "GET /orgs on ${org_api_url} failed"
if [ -n "${only_org}" ]; then
  echo "${all_orgs}" | grep -qx "${only_org}" || die "${only_org} is not one of this deployment's orgs ($(echo ${all_orgs}))"
  targets="${only_org}"
  was_assigned="false"; [ -e "$(assigned_file "${only_org}")" ] && was_assigned="true"
else
  targets="${free_orgs}"
  held=$(comm -23 <(echo "${all_orgs}" | sort) <(echo "${free_orgs}" | sort) | tr '\n' ' ')
fi
[ -n "${targets}" ] || die "no org to clean (every org is already assigned? use --org <name> to force one)"

echo
echo "################################################################################"
echo "# WARNING - DESTRUCTIVE: for each org below this DELETES, with no way back:"
echo "#   - everything in its Git repo except the sample ConfigMap,"
echo "#   - everything AKO created in Avi (virtual services...) for its VKS cluster(s),"
echo "#   - all the instances deployed from its VCF Automation blueprints (VMs),"
echo "#   - its VKS cluster(s) and ALL its supervisor namespaces (and what they hold)."
echo "# The namespace and VKS cluster are then recreated and the org is released to students."
echo "#"
echo "# Orgs to clean: $(echo ${targets})"
if [ -n "${only_org}" ]; then
  [ "${was_assigned}" == "true" ] && echo "# NOTE: ${only_org} is ALREADY ASSIGNED to a student: their work in it will be destroyed."
else
  echo "# Left alone (already assigned to a student): ${held:-none}"
fi
[ "${dry_run}" == "true" ] && echo "# (--dry-run: nothing will actually be changed)"
echo "################################################################################"
if [ "${assume_yes}" != "true" ]; then
  [ -r /dev/tty ] || die "no terminal to ask for confirmation on (use --yes)"
  read -r -p "Type 'yes' to continue: " answer < /dev/tty
  [ "${answer}" == "yes" ] || { echo "aborted, nothing changed"; exit 0; }
fi
say "started: orgs=$(echo ${targets}) dry_run=${dry_run} recreate=${recreate}"

#
# Claim the orgs (free ones: through the API, so its own bookkeeping stays the only writer).
#
claimed=""
if [ -n "${only_org}" ]; then
  if [ "${was_assigned}" == "false" ]; then
    do_it "claim ${only_org} (create $(assigned_file "${only_org}"))" \
      sudo bash -c "set -o noclobber; echo \"assigned \$(date +%Y-%m-%dT%H:%M:%S%z) to vcfa_tenant_cleaning\" > '$(assigned_file "${only_org}")'" \
      || die "could not claim ${only_org}"
  fi
  claimed="${only_org}"
else
  for _ in ${targets}; do
    if [ "${dry_run}" == "true" ]; then say "[dry-run] would: POST /org to claim the next free org"; continue; fi
    got=$(org_api_curl -X POST "${org_api_url}/org" | jq -r '.org_name // empty')
    [ -n "${got}" ] || { say "WARNING: POST /org returned no org (someone claimed one meanwhile?)"; continue; }
    claimed="${claimed} ${got}"
  done
  [ "${dry_run}" == "true" ] && claimed="${targets}"
fi
[ -n "${claimed}" ] || die "no org could be claimed"
say "claimed: $(echo ${claimed})"

#
# VCF-A access (same derivations as vcfa_tenant_bootstrap.sh)
#
vcfa_login
vcfa_api GET "cloudapi/v1/supervisors" ""
vcfa_api GET "cloudapi/1.0.0/openIdProvider/relyingParties" ""
client_id=$(echo ${response_body} | jq -c -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
[ -n "${client_id}" ] && [ "${client_id}" != "null" ] || die "could not determine the automation relying party clientId"

get_org_token() { # org -> org_token (fresh each time: they are short lived)
  vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${1}" ""
  local org_id=$(echo ${response_body} | jq -c -r --arg arg "${1}" '.values[] | select(.name == $arg) | .id')
  [ -n "${org_id}" ] || return 1
  org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
    -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_id##*:}" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "scope=openid profile email phone groups vcd_idp" \
    --data-urlencode "assertion=${vcfa_token}" \
    --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
  [ -n "${org_token}" ] && [ "${org_token}" != "null" ]
}

ns_api_base="apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/default-project/supervisornamespaces"
ip_avi=$(echo ${ips_avi} | jq -r '.[0]')   # derived like the other phases do (variables.sh only has the plural ips_avi)

# wait_until <description> <timeout seconds> <command...>: polls every 15 s until the command succeeds
wait_until() {
  local d="$1" t="$2" waited=0; shift 2
  while ! "$@"; do
    [ ${waited} -ge ${t} ] && { say "WARNING: timed out after ${t}s waiting for: ${d}"; return 1; }
    sleep 15; waited=$((waited + 15))
  done
}

#
# 2. Git: one commit leaving only the sample
#
git_reset_repo() { # org
  local org="$1" password="VMware1!$(echo -n "${gw_accounts_secret}${1}" | sha256sum | cut -c1-4)VMware1!"
  local k8s_dir="${K8S_WORK_DIR:-/home/ubuntu/k8s}" kubeconfig="${K8S_WORK_DIR:-/home/ubuntu/k8s}/${k8s_cluster_name}.kubeconfig"
  [ "${git_enabled}" == "true" ] || { say "${org}: git is not enabled, skipping the Git reset"; return 0; }
  [ -s "${kubeconfig}" ] || { say "WARNING: ${org}: no ${kubeconfig}, cannot reach the Git server - skipping the Git reset"; return 0; }
  local git_fqdn="${git_fqdn_prefix}.${avi_subdomain}.${domain}" git_scheme="https" git_vip
  kubectl --kubeconfig "${kubeconfig}" get clusterissuer "${k8s_cluster_issuer}" > /dev/null 2>&1 || git_scheme="http"
  git_vip=$(kubectl --kubeconfig "${kubeconfig}" -n "${git_namespace}" get gateway "${git_gateway_name}" -o jsonpath='{.status.addresses[0].value}' 2> /dev/null)
  [ -n "${git_vip}" ] || { say "WARNING: ${org}: the Git Gateway has no address - skipping the Git reset"; return 0; }
  # the org's own login (it owns the repo; the same password as everywhere)
  gcurl() { curl -sk -m 30 --resolve "${git_fqdn}:443:${git_vip}" --resolve "${git_fqdn}:80:${git_vip}" \
    -u "${org}:${password}" -H "Content-Type: application/json" -H "Accept: application/json" "$@"; }
  local api="${git_scheme}://${git_fqdn}/api/v1/repos/${org}/${git_repo_name}"
  local sample="${git_sample_path}/${git_sample_configmap}.yaml"
  local tree
  tree=$(gcurl "${api}/git/trees/main?recursive=true&per_page=1000") || { say "WARNING: ${org}: cannot read the repo"; return 1; }
  echo "${tree}" | jq -e '.tree' > /dev/null 2>&1 || { say "WARNING: ${org}: no tree on branch main of ${org}/${git_repo_name} ($(echo "${tree}" | jq -r '.message // empty'))"; return 1; }
  local sample_yaml
  sample_yaml=$(printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  from: gitea\n  org: %s\n' "${git_sample_configmap}" "${org}")
  local sample_sha; sample_sha=$(echo "${tree}" | jq -r --arg p "${sample}" '.tree[] | select(.path == $p and .type == "blob") | .sha')
  local ops
  ops=$(echo "${tree}" | jq -c --arg p "${sample}" --arg c "$(printf '%s\n' "${sample_yaml}" | base64 -w0)" --arg s "${sample_sha}" '
      [ .tree[] | select(.type == "blob" and .path != $p) | {operation: "delete", path: .path, sha: .sha} ]
      + [ if $s == "" then {operation: "create", path: $p, content: $c} else {operation: "update", path: $p, content: $c, sha: $s} end ]')
  say "${org}: Git commit on ${org}/${git_repo_name}: $(echo "${ops}" | jq '[.[] | select(.operation == "delete")] | length') file(s) removed, ${sample} (re)written"
  do_it "commit the reset on ${org}/${git_repo_name}" bash -c '
    code=$(jq -n --argjson f "$1" "{files: \$f, message: \"Reset to the sample content only\", branch: \"main\"}" |
      curl -sk -m 60 --resolve "$5:443:$6" --resolve "$5:80:$6" -u "$2" -H "Content-Type: application/json" -o /dev/null -w "%{http_code}" -X POST "$3/contents" -d @-)
    [ "${code}" == "201" ] || [ "${code}" == "200" ] || { echo "HTTP ${code}"; exit 1; }' _ "${ops}" "${org}:${password}" "${api}" "" "${git_fqdn}" "${git_vip}" \
    || { say "WARNING: ${org}: the Git commit failed"; return 1; }
}

#
# 3. AKO deleteConfig in a VKS cluster, then wait for Avi to be empty for the org's tenant
#
avi_vs_count() { # tenant -> number of virtual services (0 when the tenant does not exist)
  local r; r=$(curl -sk -m 30 -b /tmp/avi_cookies.txt -H "X-CSRFToken: ${avi_csrftoken}" -H "X-Avi-Tenant: ${1}" -H "X-Avi-Version: ${avi_version}" \
    -H "Referer: https://${ip_avi}" "https://${ip_avi}/api/virtualservice?page_size=1")
  echo "${r}" | jq -r '.count // 0' 2> /dev/null || echo 0
}
avi_empty() { [ "$(avi_vs_count "$1")" == "0" ]; }

set_ako_delete_config() { # org kubeconfig-file
  local org="$1" kc="$2" found
  # the key is "deleteConfig" in AKO's ConfigMap (AKOSettings.deleteConfig in the Helm values): found by content, not by name
  found=$(kubectl --kubeconfig "${kc}" get configmap -A -o json 2> /dev/null | jq -r '.items[] | select(.data.deleteConfig != null) | "\(.metadata.namespace) \(.metadata.name) \(.data.deleteConfig)"')
  [ -n "${found}" ] || { say "WARNING: ${org}: no ConfigMap with a deleteConfig key in this VKS cluster (AKO not installed?) - Avi objects, if any, stay"; return 1; }
  echo "${found}" | while read -r cm_ns cm_name cm_value; do
    say "${org}: AKO ConfigMap ${cm_ns}/${cm_name}: deleteConfig=${cm_value} -> true"
    do_it "patch ${cm_ns}/${cm_name} deleteConfig=true" \
      kubectl --kubeconfig "${kc}" -n "${cm_ns}" patch configmap "${cm_name}" --type merge -p '{"data":{"deleteConfig":"true"}}' > /dev/null
  done
}

#
# the per-org cleaning
#
clean_org() {
  local org="$1" ns_name vks_name endpoint ns_list n
  say "=== ${org}: cleaning"
  get_org_token "${org}" || { say "ERROR: ${org}: no org-scoped token"; return 1; }

  git_reset_repo "${org}" || return 1

  # namespaces of the org (default-project), and the VKS cluster(s) in each
  cci_api GET "${ns_api_base}" "" "${org_token}" || { say "ERROR: ${org}: cannot list the namespaces"; return 1; }
  ns_list=$(echo ${response_body} | jq -r '.items[].metadata.name')
  local vks_pairs="" kubeconfigs=""
  for ns_name in ${ns_list}; do
    cci_api GET "${ns_api_base}/${ns_name}" "" "${org_token}"
    endpoint=$(echo ${response_body} | jq -r '.status.namespaceEndpointURL // empty')
    [ -n "${endpoint}" ] || continue
    ns_k8s_api GET "${endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters" "" "${org_token}" || continue
    for vks_name in $(echo ${response_body} | jq -r '.items[].metadata.name'); do
      vks_pairs="${vks_pairs} ${ns_name}:${vks_name}:${endpoint}"
    done
  done

  # AKO cleanup in every VKS cluster, then wait for Avi
  local pair kc
  if [ -n "${vks_pairs}" ]; then
    bash /home/ubuntu/supervisor/auth_supervisor_custer.sh > /dev/null 2>&1
    for pair in ${vks_pairs}; do
      ns_name="${pair%%:*}"; vks_name="${pair#*:}"; vks_name="${vks_name%%:*}"
      kc="/tmp/${org}-${vks_name}-cleaning-kubeconfig.yaml"
      ( umask 077; kubectl --context sup-admin-01 get secret "${vks_name}-kubeconfig" -n "${ns_name}" -o jsonpath='{.data.value}' 2> /dev/null | base64 -d > "${kc}" )
      if [ -s "${kc}" ]; then set_ako_delete_config "${org}" "${kc}"; else say "WARNING: ${org}: no admin kubeconfig for ${vks_name}: AKO cannot be cleaned there"; fi
      rm -f "${kc}"
    done
    if [ "${dry_run}" != "true" ]; then
      avi_login
      say "${org}: waiting (max 15 min) for the Avi tenant ${org} to have no virtual service left"
      wait_until "Avi tenant ${org} empty" 900 avi_empty "${org}" \
        || { say "ERROR: ${org}: Avi still has $(avi_vs_count "${org}") virtual service(s) for the tenant - not deleting the VKS cluster (AKO could not clean up)"; return 1; }
    fi
  fi

  # instances of the org's blueprints
  blueprint_api GET "project-service/api/projects" "" "${org_token}"
  local project_id; project_id=$(echo ${response_body} | jq -r '.content[0].id // empty')
  if [ -n "${project_id}" ]; then
    blueprint_api GET "deployment/api/deployments?projects=${project_id}&size=200" "" "${org_token}"
    local dep_ids; dep_ids=$(echo ${response_body} | jq -r '.content[]?.id')
    for n in ${dep_ids}; do
      say "${org}: deleting deployment ${n}"
      do_it "DELETE deployment ${n}" blueprint_api DELETE "deployment/api/deployments/${n}" "" "${org_token}" || say "WARNING: ${org}: deleting deployment ${n} failed (${response_code})"
    done
    if [ -n "${dep_ids}" ] && [ "${dry_run}" != "true" ]; then
      deployments_gone() { get_org_token "${org}"; blueprint_api GET "deployment/api/deployments?projects=${project_id}&size=1" "" "${org_token}" \
        && [ "$(echo ${response_body} | jq -r '.totalElements // (.content | length)')" == "0" ]; }
      wait_until "deployments of ${org} gone" 1800 deployments_gone || return 1
    fi
  else
    say "${org}: no VCF-A project found, no deployments to delete"
  fi

  # VKS clusters, then namespaces
  get_org_token "${org}"
  for pair in ${vks_pairs}; do
    ns_name="${pair%%:*}"; vks_name="${pair#*:}"; endpoint="${vks_name#*:}"; vks_name="${vks_name%%:*}"
    say "${org}: deleting VKS cluster ${vks_name} (${ns_name})"
    do_it "DELETE VKS cluster ${vks_name}" ns_k8s_api DELETE "${endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters/${vks_name}" "" "${org_token}" \
      || { say "ERROR: ${org}: deleting VKS cluster ${vks_name} failed (${response_code})"; return 1; }
    if [ "${dry_run}" != "true" ]; then
      vks_gone() { get_org_token "${org}"; ns_k8s_api GET "${endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters/${vks_name}" "" "${org_token}"; [ "${response_code}" == "404" ]; }
      wait_until "VKS cluster ${vks_name} gone" 2400 vks_gone || return 1
    fi
  done
  for ns_name in ${ns_list}; do
    say "${org}: deleting namespace ${ns_name}"
    do_it "DELETE namespace ${ns_name}" cci_api DELETE "${ns_api_base}/${ns_name}" "" "${org_token}" \
      || { say "ERROR: ${org}: deleting namespace ${ns_name} failed (${response_code})"; return 1; }
    if [ "${dry_run}" != "true" ]; then
      ns_gone() { get_org_token "${org}"; cci_api GET "${ns_api_base}/${ns_name}" "" "${org_token}"; [ "${response_code}" == "404" ]; }
      wait_until "namespace ${ns_name} gone" 1200 ns_gone || return 1
    fi
  done
  say "=== ${org}: cleaned"
}

cleaned=""; failed=""
for org in ${claimed}; do
  if clean_org "${org}"; then cleaned="${cleaned} ${org}"; else failed="${failed} ${org}"; fi
done

#
# Recreate (namespace, VKS cluster, ArgoCD...) for the cleaned orgs, then release them
#
if [ -n "${cleaned}" ] && [ "${recreate}" == "true" ]; then
  say "rerunning vcfa_tenant_bootstrap.sh to recreate the namespace and VKS cluster (it covers every org; the ones that already have them are left alone)"
  if [ "${dry_run}" == "true" ]; then
    say "[dry-run] would: bash ${script_dir}/vcfa_tenant_bootstrap.sh"
  elif ! bash "${script_dir}/vcfa_tenant_bootstrap.sh" "${jsonFile}"; then
    say "ERROR: vcfa_tenant_bootstrap.sh failed - NOT releasing any org (cleaned:$(echo ${cleaned}))"
    exit 1
  fi
fi
for org in ${cleaned}; do
  do_it "release ${org} (rm $(assigned_file "${org}"))" sudo rm -f "$(assigned_file "${org}")" && say "${org}: released"
done
say "done. cleaned and released:${cleaned:- none}; FAILED and still claimed:${failed:- none}"
[ -z "${failed}" ]
