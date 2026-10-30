#!/bin/bash
#
# MANUAL tool, NOT a phase of vcf_bootstrap.sh: adds, deletes or inspects ONE VCF-A org on a running deployment, with the same
# steps the bootstrap phases do for every org - forward for `add`, in reverse order for `delete`. Run it on the gw as ubuntu.
#
#   vcfa_org.sh status <org>
#   vcfa_org.sh add    <org> [--yes] [--dry-run] [--no-isolate-others]
#   vcfa_org.sh recreate-vks <org> [--yes] [--dry-run]   delete the org's VKS cluster(s) and create a new one (named <org>-vks-<id>)
#   vcfa_org.sh isolate <org> [--dry-run]    only the vCenter isolation between <org> and every other org (see below)
#   vcfa_org.sh delete <org> [--yes] [--dry-run] [--force]   (--force: also an org already handed to a student by gw-org-api)
#   common: [--json <file>]   the deployment json the pipeline was started with (default $JSON_FILE, else
#                             /home/ubuntu/json/deployment.json, else the newest /home/ubuntu/json/*_apply.json)
#
# status   one line per object, "item|present|absent|partial|detail": spec, gw account and home folders, Vault login, Avi DNS
#          domains / tenant / user, Gitea user and repo, Harbor user, vCenter SSO user and its permissions, VCF-A org / vDC /
#          regional networking / org user, the org's namespaces, VKS clusters and deployments, the NSX project. Read-only.
#
# add      the per-org part of the phases, in the bootstrap order (the org must be in the spec: spec.sddc.vcf_a templates):
#            gw-accounts      the org's Linux account when the other orgs have one (vApp: gw-accounts.sh, WireGuard included)
#            gw-org-api       vApp only: gw-org-api.sh again, so the org is handed out
#            vault-pki        the org's read-only userpass login
#            avi-bootstrap    the org's three Avi DNS service domains (<org>, <org>-vks, <org>-gitops)
#            git-bootstrap    the org's Gitea user, private repo and sample ConfigMap
#            vcfa_provider    vcfa_provider_bootstrap.sh limited to this org (org, vDC, networking, Avi setting, org user, files)
#            vcfa_tenant      vcfa_tenant_bootstrap.sh limited to this org (namespace, Vault, VKS cluster, ArgoCD, blueprints,
#                             vCenter / Avi / Harbor accounts), then the vCenter NoAccess entries the OTHER orgs need on the new
#                             namespace (see below)
#            watcher          supervisor-blueprint-watcher.sh again, so it follows the new namespace
#
# delete   the same steps in reverse: Harbor / Avi / vCenter accounts, deployments, AKO cleanup (waits for the Avi tenant to be
#          empty), VKS clusters, namespaces, watcher refresh, then VCF-A (regional networking, vDC, org user, the org itself), Avi
#          tenant leftovers, Gitea user, Avi DNS domains, Vault login, rendered files. The gw account is NOT removed: it is locked
#          (nologin, expired), its home is cleaned and /home/<org>/.delete is left in it; every phase, gw-org-api and the WireGuard
#          peers then ignore the org although it is still in the spec, until `add` removes the marker and unlocks the account.
#          Everything it removes is only that org's; the other orgs are not touched.
#
# recreate-vks  the org stays (account, namespace, VCF-A, Git, Vault, Avi domains, vCenter isolation). Removed: its deployments,
#          AKO's Avi objects (waits for the Avi tenant to be empty), the VKS cluster(s); the namespace is kept. Then
#          vcfa_tenant_bootstrap.sh limited to the org creates the new cluster, which is named <org>-vks-<id> (generateName), so VM names
#          start with "<org>-vks-" (what a DRS VM group can match), and redoes what depends on it: pod security, cert, ArgoCD, the
#          kubeconfig in /home/<org>/.kube/config.
#
# Scope and limits:
#   - Only orgs defined in the spec can be added. A deleted org that is still in the spec stays gone while its marker
#     /home/<org>/.delete exists (gw accounts only: on a gw without accounts the next vcf_bootstrap.sh run recreates it).
#     Running delete again on an org deleted by an older version of this script (no marker) marks it.
#   - vCenter isolation: an org's SSO user must not see another org's namespace. vCenter shows every namespace to a user that has any
#     grant above it, so each pair needs an explicit NoAccess entry (the bootstrap sets them for all orgs in one run). `add` therefore
#     also writes, for the new org's namespace, a NoAccess entry for every OTHER org's SSO user (and one for the new org's user on
#     each other org's namespace) - the only change `add` makes to another org's data. `--no-isolate-others` skips it; `isolate`
#     does just that and `status` shows whether it is in place ("vcenter-isolation").
#   - supervisor-blueprint-watcher.sh is run again after add and delete (it re-applies the same objects for the other orgs).
#   - Refuses to run while vcf_bootstrap.sh or one of its phases is running. delete asks for "yes" (--yes skips the prompt).
#   - --dry-run prints what would be done and changes nothing.
#
# Credentials and addresses come from /home/ubuntu/bash/variables.sh like in every phase; nothing is hardcoded.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n 2,56p "$0"; }
action="${1:-}"; org="${2:-}"
case "${action}" in status|add|delete|isolate|recreate-vks) ;; -h|--help|"") usage; exit 0 ;; *) echo "unknown action: ${action}" >&2; usage >&2; exit 1 ;; esac
case "${org}" in ""|-*) echo "an org name is needed: vcfa_org.sh ${action} <org>" >&2; exit 1 ;; esac
shift 2
keep_namespaces="false"; assume_yes="false"; force="false"; dry_run="false"; isolate_others="true"; jsonFile="${JSON_FILE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) assume_yes="true"; shift ;;
    --force) force="true"; shift ;;
    --dry-run) dry_run="true"; shift ;;
    --no-isolate-others) isolate_others="false"; shift ;;
    --json) jsonFile="${2:?--json needs a file}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -z "${jsonFile}" ] && [ -f /home/ubuntu/json/deployment.json ] && jsonFile=/home/ubuntu/json/deployment.json
[ -z "${jsonFile}" ] && jsonFile=$(ls -t /home/ubuntu/json/*_apply.json 2>/dev/null | head -1)
[ -f "${jsonFile}" ] || { echo "no deployment json found (use --json <file>)" >&2; exit 1; }

source /home/ubuntu/bash/variables.sh < /dev/null
VCFA_KEEP_DELETED=1   # functions.sh hides deleted orgs (/home/<org>/.delete) from the phases; this script has to see them (not exported)
source "${script_dir}/functions.sh"
log_file="/home/ubuntu/vcfa_org.log"; slack_webhook=""
touch "${log_file}"
say() { local m="$(date "+%Y-%m-%d,%H:%M:%S"), vcfa_org ${action} ${org}: $*"; echo "${m}"; echo "${m}" >> "${log_file}"; }
die() { say "ERROR: $*"; exit 1; }
warn() { say "WARNING: $*"; }
# ok_say: a completion message, not printed by --dry-run (nothing was done)
ok_say() { [ "${dry_run}" == "true" ] || say "$@"; }
# do_it <description> <command...>: runs the command, or only prints it with --dry-run
do_it() { local d="$1"; shift; if [ "${dry_run}" == "true" ]; then say "[dry-run] would: ${d}"; return 0; fi; "$@"; }
# wait_until <description> <timeout seconds> <command...>: polls every 10 s until the command succeeds
wait_until() {
  local d="$1" t="$2" waited=0; shift 2
  [ "${dry_run}" == "true" ] && return 0
  while ! "$@"; do
    [ ${waited} -ge ${t} ] && { warn "timed out after ${t}s waiting for: ${d}"; return 1; }
    sleep 10; waited=$((waited + 10))
  done
}
for tool in curl jq kubectl govc sudo base64 sha256sum; do command -v "${tool}" > /dev/null 2>&1 || die "${tool} is not installed"; done

org_password="VMware1!$(echo -n "${gw_accounts_secret}${org}" | sha256sum | cut -c1-4)VMware1!"
org_item=$(echo "${vcf_a_organizations}" | jq -c --arg o "${org}" '.[] | select(.name == $o)')
sso_domain="$(jq -c -r .sddc.vcenter.ssoDomain "${jsonFile}")"
vc_host="${basename_sddc}-vc01.${domain}"
vm_ns_root="/${basename_sddc}-dc/vm/Namespaces"
pool_ns_root="/${basename_sddc}-dc/host/${basename_sddc}-cluster/Resources/Namespaces"
ip_avi=$(echo "${ips_avi}" | jq -r '.[0]')
vault_secret_file="${vault_secret_file_path:-/home/ubuntu/vault/secret.json}"
git_fqdn="${git_fqdn_prefix}.${avi_subdomain}.${domain}"
harbor_url="https://harbor.${avi_subdomain}.${domain}"
tmpdir=$(mktemp -d); trap 'rm -rf "${tmpdir}"' EXIT

#
# ---- access to every system ----------------------------------------------------------------------------------------------
#
VCFA_HOST="https://${basename_sddc}-auto-vip.${domain}"
VCFA_VERSION="9.1.0"
ACCEPT="Accept: application/json;version=${VCFA_VERSION}"
CONTENT_TYPE="Content-Type: application/json;version=${VCFA_VERSION}"
vcfa_ready=""
vcfa_init() { # provider login, relying-party client id, org id/uuid of ${org} (empty when the org does not exist)
  [ -n "${vcfa_ready}" ] && return 0
  vcfa_login
  vcfa_api GET "cloudapi/1.0.0/openIdProvider/relyingParties" ""
  client_id=$(echo ${response_body} | jq -c -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
  vcfa_api GET "cloudapi/v1/supervisors" ""
  supervisor_name=$(echo ${response_body} | jq -c -r '.values[0].name')
  vcfa_ready=1
}
org_lookup() { # sets org_id / org_uuid ("" when absent)
  vcfa_init
  vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org}" ""
  org_id=$(echo ${response_body} | jq -c -r --arg arg "${org}" '.values[] | select(.name == $arg) | .id')
  org_uuid="${org_id##*:}"
}
get_org_token() { # fresh each time (short lived); needs org_id
  org_lookup
  [ -n "${org_id}" ] || return 1
  org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" --data-urlencode "scope=openid profile email phone groups vcd_idp" \
    --data-urlencode "assertion=${vcfa_token}" --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
  [ -n "${org_token}" ] && [ "${org_token}" != "null" ]
}
avi_ready=""
avi_init() {
  [ -n "${avi_ready}" ] && return 0
  avi_login
  [ -n "${avi_version:-}" ] || avi_version=$(curl -sk -m 20 "https://${ip_avi}/api/initial-data" | jq -r '.version.Version // empty')
  avi_ready=1
}
avi_get() { avi_init; curl -sk -m 30 -b /tmp/avi_cookies.txt -H "X-CSRFToken: ${avi_csrftoken}" -H "X-Avi-Tenant: admin" -H "X-Avi-Version: ${avi_version}" -H "Referer: https://${ip_avi}" "https://${ip_avi}/$1"; }
govc_env() {
  export GOVC_URL="${vc_host}" GOVC_USERNAME="administrator@${sso_domain}" GOVC_PASSWORD="${generic_password}" GOVC_INSECURE=true GOVC_PERSIST_SESSION=false
  unset GOVC_CLUSTER
}
# vCenter permissions of an org's SSO user: "role|entity|propagate" for every explicit entry on the Supervisor namespace roots, the
# Supervisor folder and every namespace (vm folder and resource pool). govc has no "all entities" listing, so the paths are built.
vc_entries() { # org
  govc_env
  local sup_folder paths ns tok
  sup_folder=$(govc ls "${vm_ns_root}" 2> /dev/null | grep -v "/vm-watcher$" | head -1)
  tok=$(curl -sk -m 20 -X POST -u "administrator@${sso_domain}:${generic_password}" "https://${vc_host}/api/session" | tr -d '"')
  paths="${vm_ns_root} ${pool_ns_root} ${sup_folder}"
  for ns in $(curl -sk -m 20 -H "vmware-api-session-id: ${tok}" "https://${vc_host}/api/vcenter/namespaces/instances" | jq -r '.[].namespace'); do
    paths="${paths} ${sup_folder}/${ns} ${pool_ns_root}/${ns}"
  done
  # shellcheck disable=SC2086
  govc permissions.ls -a=false ${paths} 2> /dev/null | awk -v p="${1}" 'NR > 1 && tolower($3) ~ ("\\\\" tolower(p) "$") {print $1 "|" $2 "|" $4}'
}
harbor_curl() { curl -sk -m 30 -u "admin:${generic_password}" -H 'Content-Type: application/json' "$@"; }
gitea_api() { # method path [json] -> body in ${tmpdir}/gitea.json, code on stdout
  local data="${3:-}"
  if [ -n "${data}" ]; then
    curl -sk -m 60 -u "${git_admin_user}:${generic_password}" -H "Content-Type: application/json" -H "Accept: application/json" -o "${tmpdir}/gitea.json" -w '%{http_code}' -X "$1" "https://${git_fqdn}/api/v1/$2" -d "${data}"
  else
    curl -sk -m 60 -u "${git_admin_user}:${generic_password}" -H "Accept: application/json" -o "${tmpdir}/gitea.json" -w '%{http_code}' -X "$1" "https://${git_fqdn}/api/v1/$2"
  fi
}
vault_cmd() { # <vault subcommand> <args...>: the flag has to come right after the subcommand
  local sub="$1"; shift
  VAULT_ADDR="https://127.0.0.1:8200" VAULT_TOKEN="$(sudo cat "${vault_secret_file}" | jq -r .root_token)" vault "${sub}" -tls-skip-verify "$@"
}
# a private kubeconfig for the Supervisor (vSphere session through /wcp/login): the gw's own kubectl / vcf contexts are not touched
sup_kc=""
sup_kubeconfig() {
  [ -n "${sup_kc}" ] && return 0
  local tok cid ep sess
  tok=$(curl -sk -m 20 -X POST -u "administrator@${sso_domain}:${generic_password}" "https://${vc_host}/api/session" | tr -d '"')
  cid=$(curl -sk -m 20 -H "vmware-api-session-id: ${tok}" "https://${vc_host}/api/vcenter/namespace-management/clusters" | jq -r '.[0].cluster // empty')
  ep=$(curl -sk -m 20 -H "vmware-api-session-id: ${tok}" "https://${vc_host}/api/vcenter/namespace-management/clusters/${cid}" | jq -r '.api_server_cluster_endpoint // empty')
  [ -n "${ep}" ] || return 1
  sess=$(curl -sk -m 20 -X POST -u "administrator@${sso_domain}:${generic_password}" "https://${ep}/wcp/login" | jq -r '.session_id // empty')
  [ -n "${sess}" ] || return 1
  ( umask 077; printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: sup\n  cluster: {server: "https://%s:6443", insecure-skip-tls-verify: true}\nusers:\n- name: u\n  user: {token: "%s"}\ncontexts:\n- name: c\n  context: {cluster: sup, user: u}\ncurrent-context: c\n' "${ep}" "${sess}" > "${tmpdir}/sup.kubeconfig" )
  sup_kc="${tmpdir}/sup.kubeconfig"
}
supkc() { sup_kubeconfig && kubectl --kubeconfig "${sup_kc}" --request-timeout=30s "$@"; }

ns_api_base="apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/default-project/supervisornamespaces"
org_dirs() { echo "/home/${org} /home/ubuntu/${org}"; }
other_orgs() { echo "${vcf_a_organizations}" | jq -r --arg o "${org}" '.[] | select(.name != $o) | .name'; }
org_has_account() { id "${org}" > /dev/null 2>&1; }
others_have_accounts() { local o; for o in $(other_orgs); do [ -e "/home/${o}/.delete" ] && continue; id "${o}" > /dev/null 2>&1 && return 0; done; return 1; }
org_is_deleted() { [ -e "/home/${org}/.delete" ]; }   # marker left by delete (home is o+x, so ubuntu can test it)

# names of the vCenter namespaces of an org (<org>-ns-xxxxx), from the vCenter API
vc_org_namespaces() { # org
  local tok; tok=$(curl -sk -m 20 -X POST -u "administrator@${sso_domain}:${generic_password}" "https://${vc_host}/api/session" | tr -d '"')
  curl -sk -m 20 -H "vmware-api-session-id: ${tok}" "https://${vc_host}/api/vcenter/namespaces/instances" | jq -r --arg p "${1}-ns-" '.[].namespace | select(startswith($p))'
}
vc_sso_user_exists() { govc_env; govc sso.user.ls 2> /dev/null | awk '{print $1}' | grep -qx "$1"; }
# pairs (viewer org, namespace) that lack the NoAccess entry: <org>'s namespaces for every other org, and every other org's namespaces for <org>
isolation_gaps() { # -> lines "viewer namespace"
  local o ns viewer entries
  for o in $(other_orgs); do
    for ns in $(vc_org_namespaces "${org}"); do
      vc_sso_user_exists "${o}" || continue
      entries=$(vc_entries "${o}"); echo "${entries}" | grep -q "^NoAccess|.*/${ns}|" || echo "${o} ${ns}"
    done
    vc_sso_user_exists "${org}" || continue
    entries=$(vc_entries "${org}")
    for ns in $(vc_org_namespaces "${o}"); do
      echo "${entries}" | grep -q "^NoAccess|.*/${ns}|" || echo "${org} ${ns}"
    done
  done
}
st_isolation() {
  local gaps; vc_sso_user_exists "${org}" || [ -n "$(vc_org_namespaces "${org}")" ] || { st vcenter-isolation absent ""; return 0; }
  gaps=$(isolation_gaps)
  if [ -z "${gaps}" ]; then st vcenter-isolation present "NoAccess in place between ${org} and the other orgs"; else st vcenter-isolation partial "missing: $(echo "${gaps}" | awk '{print $1 "->" $2}' | tr '\n' ' ')"; fi
}

#
# ---- status: one line per object -------------------------------------------------------------------------------------------
#
st() { echo "$1|$2|$3"; } # item|state|detail
do_status() {
  local v n c
  if [ -n "${org_item}" ]; then st spec present "template entry in vcf_a_organizations ($(echo "${org_item}" | jq -c '{vks: .vks_cluster.enabled, argocd: .vks_cluster.argocd.enabled, avi: .enable_avi}'))"; else st spec absent "not in vcf_a_organizations"; fi
  if org_has_account; then st gw-account present "uid $(id -u "${org}")$(org_is_deleted && echo ", $(sudo passwd -S "${org}" 2> /dev/null | awk '{print "state " $2}')")"; else st gw-account absent ""; fi
  if org_is_deleted; then st deleted-marker present "/home/${org}/.delete: $(sudo cat "/home/${org}/.delete" 2> /dev/null | head -1)"; else st deleted-marker absent ""; fi
  for v in $(org_dirs); do if sudo test -d "${v}"; then st "dir ${v}" present "$(sudo find "${v}" -type f 2>/dev/null | wc -l) file(s)"; else st "dir ${v}" absent ""; fi; done
  if vault_cmd read "auth/userpass/users/${org}" > /dev/null 2>&1; then st vault-user present ""; else st vault-user absent ""; fi
  avi_init
  v=$(avi_get "api/ipamdnsproviderprofile?name=dns-avi" | jq -r --arg o "${org}" --arg d "${domain}" '[.results[0].internal_profile.dns_service_domain[]?.domain_name | select(. == ($o + "." + $d) or . == ($o + "-vks." + $d) or . == ($o + "-gitops." + $d))] | length')
  case "${v}" in 3) st avi-dns-domains present "3 of 3";; 0) st avi-dns-domains absent "0 of 3";; *) st avi-dns-domains partial "${v} of 3";; esac
  v=$(avi_get "api/tenant?name=${org}" | jq -r '.results[0].uuid // empty'); [ -n "${v}" ] && st avi-tenant present "${v}" || st avi-tenant absent ""
  v=$(avi_get "api/user?name=${org}" | jq -r '.results[0].uuid // empty'); [ -n "${v}" ] && st avi-user present "${v}" || st avi-user absent ""
  c=$(gitea_api GET "users/${org}"); [ "${c}" == "200" ] && st gitea-user present "id $(jq -r .id "${tmpdir}/gitea.json")" || st gitea-user absent "HTTP ${c}"
  c=$(gitea_api GET "repos/${org}/${git_repo_name}"); [ "${c}" == "200" ] && st gitea-repo present "${org}/${git_repo_name}" || st gitea-repo absent "HTTP ${c}"
  v=$(harbor_curl "${harbor_url}/api/v2.0/users/search?username=${org}" | jq -r --arg u "${org}" '[.[]? | select(.username == $u)][0].user_id // empty'); [ -n "${v}" ] && st harbor-user present "id ${v}" || st harbor-user absent ""
  govc_env
  if govc sso.user.ls 2> /dev/null | awk '{print $1}' | grep -qx "${org}"; then st vcenter-sso-user present "${org}@${sso_domain}"; else st vcenter-sso-user absent ""; fi
  n=$(vc_entries "${org}" | wc -l); [ "${n}" -gt 0 ] && st vcenter-permissions present "${n} entr(ies)" || st vcenter-permissions absent ""
  st_isolation
  org_lookup
  if [ -z "${org_id}" ]; then
    st vcfa-org absent ""; st vcfa-vdc absent ""; st vcfa-regional-networking absent ""; st vcfa-org-user absent ""; st namespaces absent ""; st vks-clusters absent ""; st nsx-project absent ""
    return 0
  fi
  st vcfa-org present "${org_id} enabled=$(vcfa_api GET "cloudapi/1.0.0/orgs/${org_id}" "" && echo ${response_body} | jq -r .isEnabled)"
  vcfa_api GET "cloudapi/v1/virtualDatacenters?filter=name==${org}_region-1" ""; v=$(echo ${response_body} | jq -r --arg n "${org}_region-1" '.values[]? | select(.name == $n) | .id'); [ -n "${v}" ] && st vcfa-vdc present "${v}" || st vcfa-vdc absent ""
  vcfa_api GET "cloudapi/v1/regionalNetworkingSettings?filter=orgRef.name==${org}" ""; v=$(echo ${response_body} | jq -r --arg o "${org}" '.values[]? | select(.orgRef.name == $o) | "\(.id) \(.status)"'); [ -n "${v}" ] && st vcfa-regional-networking present "${v}" || st vcfa-regional-networking absent ""
  vcfa_api GET "cloudapi/1.0.0/users" "" 2 5 "x-vmware-vcloud-tenant-context: ${org_uuid}"; v=$(echo ${response_body} | jq -r --arg o "${org}" '.values[]? | select(.username == $o) | .id'); [ -n "${v}" ] && st vcfa-org-user present "${v}" || st vcfa-org-user absent ""
  v=$(curl -sk -u "admin:${generic_password}" "https://${ip_nsx_vip}/policy/api/v1/orgs/default/projects/${org_uuid}" | jq -r '.id // empty'); [ -n "${v}" ] && st nsx-project present "${v}" || st nsx-project absent ""
  if get_org_token; then
    cci_api GET "${ns_api_base}" "" "${org_token}"
    local ns_list; ns_list=$(echo ${response_body} | jq -r '.items[]?.metadata.name')
    if [ -n "${ns_list}" ]; then st namespaces present "$(echo ${ns_list})"; else st namespaces absent ""; fi
    local ns endpoint vks_list=""
    for ns in ${ns_list}; do
      cci_api GET "${ns_api_base}/${ns}" "" "${org_token}"; endpoint=$(echo ${response_body} | jq -r '.status.namespaceEndpointURL // empty'); [ -n "${endpoint}" ] || continue
      ns_k8s_api GET "${endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns}/clusters" "" "${org_token}" && vks_list="${vks_list} ${ns}/$(echo ${response_body} | jq -r '[.items[]?.metadata.name] | join(",")')"
    done
    if [ -n "$(echo ${vks_list} | tr -d ' /')" ]; then st vks-clusters present "$(echo ${vks_list})"; else st vks-clusters absent ""; fi
    blueprint_api GET "project-service/api/projects" "" "${org_token}"; v=$(echo ${response_body} | jq -r '.content[0].id // empty')
    if [ -n "${v}" ]; then blueprint_api GET "deployment/api/deployments?projects=${v}&size=1" "" "${org_token}"; st deployments present "$(echo ${response_body} | jq -r '.totalElements // 0') deployment(s)"; fi
  else
    st namespaces unknown "no org token"
  fi
}

#
# ---- safety --------------------------------------------------------------------------------------------------------------
#
check_idle() {
  local busy
  # only real script runs: "bash .../<phase>.sh" (not an ssh command line that merely mentions a name)
  # (this script's own pid and its subshells, which carry the same command line, are left out)
  busy=$(ps -eo pid=,ppid=,args= | awk -v me=$$ '$1 != me && $2 != me && $3 == "bash" && $4 ~ /(vcf_bootstrap|vcfa_provider_bootstrap|vcfa_tenant_bootstrap|vcfa_tenant_cleaning|supervisor-bootstrap|avi-bootstrap|k8s-bootstrap|git-bootstrap|vcfa_org)\.sh$/' | head -3)
  [ -z "${busy}" ] || { echo "${busy}"; die "a bootstrap phase or another vcfa_org.sh is running (above): not changing anything"; }
}

#
# ---- one phase script, limited to / without this org -----------------------------------------------------------------------
#
run_phase() { # phase mode(only|exclude|all)
  local phase="$1" mode="$2"
  say "phase ${phase}.sh ($([ "${mode}" == only ] && echo "limited to ${org}" || { [ "${mode}" == exclude ] && echo "without ${org}" || echo "unchanged, all orgs"; }))"
  [ "${dry_run}" == "true" ] && { say "[dry-run] would: bash ${script_dir}/${phase}.sh ${jsonFile}"; return 0; }
  case "${mode}" in
    only) VCFA_ORG_ONLY="${org}" bash "${script_dir}/${phase}.sh" "${jsonFile}" ;;
    exclude) VCFA_ORG_EXCLUDE="${org}" bash "${script_dir}/${phase}.sh" "${jsonFile}" ;;
    *) bash "${script_dir}/${phase}.sh" "${jsonFile}" ;;
  esac
}

#
# ---- add -----------------------------------------------------------------------------------------------------------------------
#
add_gw_account() {
  if [ "${deployment_kind}" == "vApp" ]; then
    run_phase gw-accounts all; run_phase gw-org-api all
  elif others_have_accounts; then
    # the account, its WireGuard keys and the gw's wg0.conf peers are rebuilt from ALL orgs (a run limited to one org would drop the others' peers)
    run_phase gw-accounts all; run_phase gw-org-api all   # gw-org-api.sh skips itself when spec gw.org_api is not set
  else
    say "the other orgs have no gw account (sddc gw built before gw-accounts ran there): none created, files stay under /home/ubuntu/${org}; run gw-accounts.sh to enable accounts and WireGuard"
  fi
}
add_vault() {
  vault_cmd read "auth/userpass/users/${org}" > /dev/null 2>&1 && { say "Vault login ${org} already exists"; return 0; }
  [ "${dry_run}" == "true" ] && { say "[dry-run] would: create the Vault userpass login ${org}"; return 0; }
  printf '%s' "${org_password}" | vault_cmd write "auth/userpass/users/${org}" password=- policies="${vault_student_policy_name}" > /dev/null && say "Vault login ${org} created" || warn "Vault login ${org} failed"
}
# the profile's service domains: set <org>'s three present or absent, leaving everything else as it is
avi_dns_domains() { # add|remove
  avi_init
  local prof uuid body new
  prof=$(avi_get "api/ipamdnsproviderprofile?name=dns-avi")
  uuid=$(echo "${prof}" | jq -r '.results[0].uuid // empty'); [ -n "${uuid}" ] || { warn "Avi DNS profile dns-avi not found"; return 1; }
  body=$(echo "${prof}" | jq -c '.results[0]')
  new=$(echo "${body}" | jq -c --arg o "${org}" --arg d "${domain}" --arg m "$1" '
    ([$o + "." + $d, $o + "-vks." + $d, $o + "-gitops." + $d]) as $mine
    | .internal_profile.dns_service_domain |= (map(select(.domain_name as $n | ($mine | index($n)) | not))
        + (if $m == "add" then ($mine | map({domain_name: ., pass_through: true})) else [] end))')
  if [ "${new}" == "${body}" ]; then say "Avi DNS domains of ${org} already $([ "$1" == add ] && echo present || echo absent)"; return 0; fi
  [ "${dry_run}" == "true" ] && { say "[dry-run] would: $1 the three Avi DNS service domains of ${org} in dns-avi"; return 0; }
  ( avi_api 3 3 PUT "${new}" "api/ipamdnsproviderprofile/${uuid}" ) && say "Avi DNS domains of ${org}: $1 done" || warn "updating the Avi DNS profile failed"
}
add_git() {
  local c sample_file sample_yaml
  c=$(gitea_api GET "users/${org}")
  if [ "${c}" == "200" ]; then say "Gitea user ${org} already exists"; else
    [ "${dry_run}" == "true" ] && { say "[dry-run] would: create the Gitea user ${org} and its repo"; return 0; }
    c=$(gitea_api POST "admin/users" "$(jq -n --arg pw "${org_password}" --arg u "${org}" --arg e "${org}@${domain}" '{username: $u, email: $e, password: $pw, must_change_password: false, send_notify: false, visibility: "private"}')")
    [ "${c}" == "201" ] || { warn "creating the Gitea user failed (HTTP ${c})"; return 1; }
    say "Gitea user ${org} created"
  fi
  c=$(gitea_api GET "repos/${org}/${git_repo_name}")
  if [ "${c}" != "200" ] && [ "${dry_run}" != "true" ]; then
    c=$(gitea_api POST "admin/users/${org}/repos" "$(jq -n --arg r "${git_repo_name}" --arg d "Private repository of the VCF-A org ${org}" '{name: $r, description: $d, private: true, auto_init: true, default_branch: "main", readme: "Default"}')")
    [ "${c}" == "201" ] || { warn "creating the repo failed (HTTP ${c})"; return 1; }
    say "repo ${org}/${git_repo_name} created"
  fi
  sample_file="${git_sample_path}/${git_sample_configmap}.yaml"
  c=$(gitea_api GET "repos/${org}/${git_repo_name}/contents/${sample_file}?ref=main")
  if [ "${c}" == "404" ] && [ "${dry_run}" != "true" ]; then
    sample_yaml=$(printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  from: gitea\n  org: %s\n' "${git_sample_configmap}" "${org}")
    c=$(gitea_api POST "repos/${org}/${git_repo_name}/contents/${sample_file}" "$(jq -n --arg c "$(printf '%s\n' "${sample_yaml}" | base64 -w0)" --arg m "Sample ConfigMap synced by ArgoCD" '{content: $c, message: $m, branch: "main"}')")
    [ "${c}" == "201" ] && say "sample ${sample_file} committed" || warn "committing the sample failed (HTTP ${c})"
  fi
}
# NoAccess entries missing between this org and the others (see isolation_gaps): written with the same two calls vcfa_tenant_bootstrap.sh uses
add_isolation() {
  govc_env
  local gaps viewer ns sup_folder
  gaps=$(isolation_gaps)
  [ -z "${gaps}" ] && { say "vCenter isolation: already in place"; return 0; }
  sup_folder=$(govc ls "${vm_ns_root}" 2> /dev/null | grep -v "/vm-watcher$" | head -1)
  echo "${gaps}" | while read -r viewer ns; do
    [ "${dry_run}" == "true" ] && { say "[dry-run] would: NoAccess for ${viewer}@${sso_domain} on ${ns}"; continue; }
    govc permissions.set -principal "${viewer}@${sso_domain}" -role NoAccess -propagate=true "${sup_folder}/${ns}" \
      && govc permissions.set -principal "${viewer}@${sso_domain}" -role NoAccess -propagate=true "${pool_ns_root}/${ns}" \
      && say "vCenter: ${viewer}@${sso_domain} has NoAccess on ${ns}" || warn "NoAccess for ${viewer} on ${ns} failed"
  done
}
do_add() {
  [ -n "${org_item}" ] || die "${org} is not in the spec (vcf_a_organizations): add it to spec.sddc.vcf_a first"
  check_idle
  say "adding ${org} (json ${jsonFile})"
  gw_unmark_deleted
  add_gw_account
  add_vault
  avi_dns_domains add
  add_git
  run_phase vcfa_provider_bootstrap only || die "vcfa_provider_bootstrap.sh failed"
  run_phase vcfa_tenant_bootstrap only || die "vcfa_tenant_bootstrap.sh failed"
  if [ "${isolate_others}" == "true" ]; then add_isolation; else
    say "NOTE: no vCenter NoAccess entries written (--no-isolate-others): the orgs can see each other's namespaces in vCenter"
  fi
  run_phase supervisor-blueprint-watcher all
  say "done"
}

#
# ---- delete --------------------------------------------------------------------------------------------------------------------
#
del_harbor() {
  local id; id=$(harbor_curl "${harbor_url}/api/v2.0/users/search?username=${org}" | jq -r --arg u "${org}" '[.[]? | select(.username == $u)][0].user_id // empty')
  [ -n "${id}" ] || { say "Harbor user ${org}: none"; return 0; }
  do_it "delete the Harbor user ${org} (id ${id})" harbor_curl -X DELETE "${harbor_url}/api/v2.0/users/${id}" -o /dev/null && ok_say "Harbor user ${org} deleted"
}
del_avi_user() {
  avi_init
  local uuid; uuid=$(avi_get "api/user?name=${org}" | jq -r '.results[0].uuid // empty')
  [ -n "${uuid}" ] || { say "Avi user ${org}: none"; return 0; }
  [ "${dry_run}" == "true" ] && { say "[dry-run] would: delete the Avi user ${org}"; return 0; }
  ( avi_api 3 3 DELETE "" "api/user/${uuid}" ) && ok_say "Avi user ${org} deleted" || warn "deleting the Avi user failed"
}
del_vcenter() {
  govc_env
  local p="${org}@${sso_domain}" path
  for path in $(vc_entries "${org}" | cut -d'|' -f2 | sort -u); do
    do_it "remove the permissions of ${p} on ${path}" govc permissions.remove -principal "${p}" "${path}" > /dev/null 2>&1
  done
  if govc sso.user.ls 2> /dev/null | awk '{print $1}' | grep -qx "${org}"; then
    do_it "delete the vCenter SSO user ${org}" govc sso.user.rm "${org}" && ok_say "vCenter SSO user ${org} and its permissions removed"
  else say "vCenter SSO user ${org}: none"; fi
}
# virtual services of the org's Avi tenant. The control-plane VIP of each VKS cluster (marker GatewayName = the cluster's name) belongs to
# the Supervisor, which removes it with the cluster: it does not count as something AKO inside the cluster still has to clean up.
vks_names_json="[]"
avi_vs_count() {
  avi_init
  curl -sk -m 30 -b /tmp/avi_cookies.txt -H "X-CSRFToken: ${avi_csrftoken}" -H "X-Avi-Tenant: ${org}" -H "X-Avi-Version: ${avi_version}" -H "Referer: https://${ip_avi}" "https://${ip_avi}/api/virtualservice?page_size=200" \
    | jq -r --argjson vks "${vks_names_json}" '[(.results // [])[] | select(any(.markers[]?; .key == "GatewayName" and ((.values[0] // "") | IN($vks[]))) | not)] | length' 2> /dev/null || echo 0
}
avi_empty() { [ "$(avi_vs_count)" == "0" ]; }
avi_vs_total() { avi_init; curl -sk -m 30 -b /tmp/avi_cookies.txt -H "X-CSRFToken: ${avi_csrftoken}" -H "X-Avi-Tenant: ${org}" -H "X-Avi-Version: ${avi_version}" -H "Referer: https://${ip_avi}" "https://${ip_avi}/api/virtualservice?page_size=1" | jq -r '.count // 0' 2> /dev/null || echo 0; }
del_workloads() { # deployments, AKO cleanup, VKS clusters, namespaces
  get_org_token || { say "no org token: the org has no workloads left to delete"; return 0; }
  cci_api GET "${ns_api_base}" "" "${org_token}" || { warn "cannot list the namespaces"; return 1; }
  local ns_list ns endpoint vks pair vks_pairs="" kc n project_id dep_ids
  ns_list=$(echo ${response_body} | jq -r '.items[]?.metadata.name')
  for ns in ${ns_list}; do
    cci_api GET "${ns_api_base}/${ns}" "" "${org_token}"; endpoint=$(echo ${response_body} | jq -r '.status.namespaceEndpointURL // empty'); [ -n "${endpoint}" ] || continue
    ns_k8s_api GET "${endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns}/clusters" "" "${org_token}" || continue
    for vks in $(echo ${response_body} | jq -r '.items[]?.metadata.name'); do vks_pairs="${vks_pairs} ${ns}|${vks}|${endpoint}"; done
  done
  # AKO: deleteConfig=true so AKO removes what it created in Avi, then wait until the org's Avi tenant has no virtual service
  if [ -n "${vks_pairs}" ]; then
    vks_names_json=$(for pair in ${vks_pairs}; do IFS='|' read -r ns vks endpoint <<< "${pair}"; echo "${vks}"; done | jq -R . | jq -sc .)
    for pair in ${vks_pairs}; do
      IFS='|' read -r ns vks endpoint <<< "${pair}"
      kc="${tmpdir}/${org}-${vks}.kubeconfig"
      ( umask 077; supkc get secret "${vks}-kubeconfig" -n "${ns}" -o jsonpath='{.data.value}' 2> /dev/null | base64 -d > "${kc}" )
      if [ -s "${kc}" ]; then
        kubectl --kubeconfig "${kc}" --request-timeout=30s get configmap -A -o json 2> /dev/null | jq -r '.items[] | select(.data.deleteConfig != null) | "\(.metadata.namespace) \(.metadata.name)"' | while read -r cm_ns cm_name; do
          do_it "AKO ${cm_ns}/${cm_name}: deleteConfig=true" kubectl --kubeconfig "${kc}" -n "${cm_ns}" patch configmap "${cm_name}" --type merge -p '{"data":{"deleteConfig":"true"}}' > /dev/null
        done
      else warn "no admin kubeconfig for ${vks}: AKO cannot be cleaned there"; fi
    done
    say "waiting (15 min at most) for the Avi tenant ${org} to have no virtual service left"
    wait_until "Avi tenant ${org} empty" 900 avi_empty || { warn "Avi still has $(avi_vs_count) virtual service(s) of workloads for ${org}: not deleting the VKS cluster"; return 1; }
  fi
  # instances (deployments) of the org's blueprints
  blueprint_api GET "project-service/api/projects" "" "${org_token}"
  project_id=$(echo ${response_body} | jq -r '.content[0].id // empty')
  if [ -n "${project_id}" ]; then
    blueprint_api GET "deployment/api/deployments?projects=${project_id}&size=200" "" "${org_token}"
    dep_ids=$(echo ${response_body} | jq -r '.content[]?.id')
    for n in ${dep_ids}; do do_it "delete the deployment ${n}" blueprint_api DELETE "deployment/api/deployments/${n}" "" "${org_token}" || warn "deleting deployment ${n} failed (${response_code})"; done
    if [ -n "${dep_ids}" ]; then
      deployments_gone() { get_org_token; blueprint_api GET "deployment/api/deployments?projects=${project_id}&size=1" "" "${org_token}" && [ "$(echo ${response_body} | jq -r '.totalElements // (.content | length)')" == "0" ]; }
      wait_until "deployments of ${org} gone" 1800 deployments_gone || return 1
    fi
  fi
  # VKS clusters, then the namespaces
  get_org_token
  for pair in ${vks_pairs}; do
    IFS='|' read -r ns vks endpoint <<< "${pair}"
    say "deleting the VKS cluster ${vks} (${ns})"
    do_it "DELETE VKS cluster ${vks}" ns_k8s_api DELETE "${endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns}/clusters/${vks}" "" "${org_token}" || { warn "deleting ${vks} failed (${response_code})"; return 1; }
    vks_gone() { get_org_token; ns_k8s_api GET "${endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns}/clusters/${vks}" "" "${org_token}"; [ "${response_code}" == "404" ]; }
    wait_until "VKS cluster ${vks} gone" 2400 vks_gone || return 1
  done
  [ "${keep_namespaces}" == "true" ] && return 0
  # virtual machines still in the namespaces (not created by a deployment, or left behind by one). The VKS clusters are gone by now, so
  # their node VMs are not among them; deleting the namespace with a VM in it can leave it stuck in Terminating
  local vms vm
  for ns in ${ns_list}; do
    get_org_token
    cci_api GET "${ns_api_base}/${ns}" "" "${org_token}"; endpoint=$(echo ${response_body} | jq -r '.status.namespaceEndpointURL // empty'); [ -n "${endpoint}" ] || continue
    ns_k8s_api GET "${endpoint}" "apis/vmoperator.vmware.com/v1alpha5/namespaces/${ns}/virtualmachines" "" "${org_token}" || { warn "cannot list the virtual machines of ${ns} (${response_code})"; continue; }
    vms=$(echo ${response_body} | jq -r '.items[]?.metadata.name')
    [ -n "${vms}" ] || continue
    for vm in ${vms}; do
      say "deleting the virtual machine ${vm} (${ns})"
      do_it "DELETE virtual machine ${vm}" ns_k8s_api DELETE "${endpoint}" "apis/vmoperator.vmware.com/v1alpha5/namespaces/${ns}/virtualmachines/${vm}" "" "${org_token}" || warn "deleting ${vm} failed (${response_code})"
    done
    vms_gone() { get_org_token; ns_k8s_api GET "${endpoint}" "apis/vmoperator.vmware.com/v1alpha5/namespaces/${ns}/virtualmachines" "" "${org_token}" && [ "$(echo ${response_body} | jq -r '.items | length')" == "0" ]; }
    wait_until "virtual machines of ${ns} gone" 900 vms_gone || return 1
  done
  for ns in ${ns_list}; do
    say "deleting the namespace ${ns}"
    do_it "DELETE namespace ${ns}" cci_api DELETE "${ns_api_base}/${ns}" "" "${org_token}" || { warn "deleting ${ns} failed (${response_code})"; return 1; }
    ns_gone() { get_org_token; cci_api GET "${ns_api_base}/${ns}" "" "${org_token}"; [ "${response_code}" == "404" ]; }
    wait_until "namespace ${ns} gone" 1200 ns_gone || return 1
  done
}
# certificates left in the org's Avi tenant (AKO's Gateway CA, the Vault intermediate): VCF-A deletes the tenant when the Avi setting is switched
# off, and Avi refuses ("Cannot delete, object is referred by SSLKeyAndCertificate ...") while any is left, so the setting stays active=true
# and the regional networking cannot be deleted. Only objects owned by the tenant itself are removed. Two passes, a cert may refer to another.
avi_clear_tenant_certs() {
  avi_init
  local tuuid pass u n certs
  tuuid=$(avi_get "api/tenant?name=${org}" | jq -r '.results[0].uuid // empty'); [ -n "${tuuid}" ] || return 0
  for pass in 1 2; do
    certs=$(curl -sk -m 30 -b /tmp/avi_cookies.txt -H "X-CSRFToken: ${avi_csrftoken}" -H "X-Avi-Tenant: ${org}" -H "X-Avi-Version: ${avi_version}" -H "Referer: https://${ip_avi}" "https://${ip_avi}/api/sslkeyandcertificate?page_size=200" \
      | jq -r --arg t "${tuuid}" '.results[]? | select((.tenant_ref // "") | endswith("/" + $t)) | "\(.uuid) \(.name)"')
    [ -n "${certs}" ] || return 0
    while read -r u n; do
      [ -n "${u}" ] || continue
      if [ "${dry_run}" == "true" ]; then say "[dry-run] would: delete the Avi certificate ${n} of tenant ${org}"
      else ( avi_api 2 3 DELETE "" "api/sslkeyandcertificate/${u}" "${org}" ) > /dev/null 2>&1 && ok_say "Avi certificate ${n} of tenant ${org} deleted" || [ "${pass}" == "1" ] || warn "deleting the Avi certificate ${n} failed"; fi
    done <<< "${certs}"
    [ "${dry_run}" == "true" ] && return 0
  done
}
del_vcfa_org() { # regional networking (Avi setting, NSX project), vDC, org user, the org
  org_lookup
  [ -n "${org_id}" ] || { say "VCF-A org ${org}: none"; return 0; }
  local id v
  vcfa_api GET "cloudapi/v1/regionalNetworkingSettings?filter=orgRef.name==${org}" ""
  id=$(echo ${response_body} | jq -r --arg o "${org}" '.values[]? | select(.orgRef.name == $o) | .id')
  if [ -n "${id}" ]; then
    # the service engine group(s) assigned to the org (provider-seg) go first: while one is assigned VCF-A refuses to switch the Avi
    # setting off ("Service Engine Group(s) assigned") and so to delete the regional networking, the vDC and the org
    local seg_assign
    vcfa_api GET "cloudapi/v1/loadBalancer/aviServiceEngineGroupsAssignments?filter=orgRef.name==${org}" ""
    for seg_assign in $(echo ${response_body} | jq -r --arg o "${org}" '.values[]? | select(.orgRef.name == $o) | .id'); do
      do_it "DELETE the service engine group assignment ${seg_assign}" vcfa_api DELETE "cloudapi/v1/loadBalancer/aviServiceEngineGroupsAssignments/${seg_assign}" "" 3 10 \
        && ok_say "service engine group assignment ${seg_assign} of ${org} removed" || warn "removing the service engine group assignment failed (${response_code}): ${response_body}"
    done
    [ "${dry_run}" == "true" ] || sleep 5
    avi_clear_tenant_certs
    # the Avi load-balancer setting has to be switched off first, with exactly this body: a PUT that repeats the mode and limits is
    # refused ("Service Engine Group(s) assigned"); VCF-A then also releases the org's Avi tenant
    do_it "switch off the Avi setting of the regional networking ${id}" vcfa_api PUT "cloudapi/v1/regionalNetworkingSettings/${id}/aviSetting" '{"active":false}' 2 5 || warn "switching off the Avi setting failed (${response_code}): ${response_body}"
    [ "${dry_run}" == "true" ] || sleep 10
    do_it "DELETE regionalNetworkingSettings ${id}" vcfa_api DELETE "cloudapi/v1/regionalNetworkingSettings/${id}" "" 3 10 || { warn "deleting the regional networking failed (${response_code}): ${response_body}"; return 1; }
    rns_gone() { vcfa_api GET "cloudapi/v1/regionalNetworkingSettings?filter=orgRef.name==${org}" ""; [ -z "$(echo ${response_body} | jq -r --arg o "${org}" '.values[]? | select(.orgRef.name == $o) | .id')" ]; }
    wait_until "regional networking of ${org} gone" 900 rns_gone || return 1
  fi
  vcfa_api GET "cloudapi/v1/virtualDatacenters?filter=name==${org}_region-1" ""
  id=$(echo ${response_body} | jq -r --arg n "${org}_region-1" '.values[]? | select(.name == $n) | .id')
  if [ -n "${id}" ]; then
    do_it "DELETE the vDC ${id}" vcfa_api DELETE "cloudapi/v1/virtualDatacenters/${id}" "" 3 10 || warn "deleting the vDC failed (${response_code}): ${response_body}"
    vdc_gone() { vcfa_api GET "cloudapi/v1/virtualDatacenters?filter=name==${org}_region-1" ""; [ -z "$(echo ${response_body} | jq -r --arg n "${org}_region-1" '.values[]? | select(.name == $n) | .id')" ]; }
    wait_until "vDC of ${org} gone" 600 vdc_gone || return 1
  fi
  vcfa_api GET "cloudapi/1.0.0/users" "" 2 5 "x-vmware-vcloud-tenant-context: ${org_uuid}"
  id=$(echo ${response_body} | jq -r --arg o "${org}" '.values[]? | select(.username == $o) | .id')
  [ -n "${id}" ] && do_it "DELETE the org user ${id}" vcfa_api DELETE "cloudapi/1.0.0/users/${id}" "" 2 5 "x-vmware-vcloud-tenant-context: ${org_uuid}"
  # the org: disabled first, then deleted
  vcfa_api GET "cloudapi/1.0.0/orgs/${org_id}" ""
  v=$(echo ${response_body} | jq -c '.isEnabled = false')
  do_it "disable the org ${org}" vcfa_api PUT "cloudapi/1.0.0/orgs/${org_id}" "${v}" 2 5 || warn "disabling the org failed (${response_code}): ${response_body}"
  do_it "DELETE the org ${org}" vcfa_api DELETE "cloudapi/1.0.0/orgs/${org_id}" "" 3 10 || { warn "deleting the org failed (${response_code}): ${response_body}"; return 1; }
  org_gone() { vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org}" ""; [ -z "$(echo ${response_body} | jq -r --arg o "${org}" '.values[]? | select(.name == $o) | .id')" ]; }
  wait_until "org ${org} gone" 900 org_gone || return 1
  ok_say "VCF-A org ${org} deleted"
}
del_avi_tenant() { # normally removed with the org's Avi setting; only an empty leftover is deleted
  avi_init
  local uuid; uuid=$(avi_get "api/tenant?name=${org}" | jq -r '.results[0].uuid // empty')
  [ -n "${uuid}" ] || { say "Avi tenant ${org}: none left"; return 0; }
  [ "$(avi_vs_total)" == "0" ] || { warn "Avi tenant ${org} still has virtual services: left alone"; return 1; }
  [ "${dry_run}" == "true" ] && { say "[dry-run] would: delete the empty Avi tenant ${org}"; return 0; }
  ( avi_api 3 3 DELETE "" "api/tenant/${uuid}" ) && ok_say "Avi tenant ${org} deleted" || warn "deleting the Avi tenant failed"
}
del_git() {
  local c; c=$(gitea_api GET "users/${org}")
  [ "${c}" == "200" ] || { say "Gitea user ${org}: none"; return 0; }
  [ "${dry_run}" == "true" ] && { say "[dry-run] would: delete the Gitea user ${org} with its repo"; return 0; }
  c=$(gitea_api DELETE "admin/users/${org}?purge=true"); [ "${c}" == "204" ] && ok_say "Gitea user ${org} and its repo deleted" || warn "deleting the Gitea user failed (HTTP ${c})"
}
del_vault() { vault_cmd read "auth/userpass/users/${org}" > /dev/null 2>&1 || { say "Vault login ${org}: none"; return 0; }; do_it "delete the Vault login ${org}" vault_cmd delete "auth/userpass/users/${org}" > /dev/null && ok_say "Vault login ${org} deleted"; }
# the org stays as a LOCKED gw account holding /home/<org>/.delete (functions.sh hides such an org from every phase, gw-org-api.py does not
# hand it out, the gw's WireGuard peers drop it): a deleted org that is still in the spec is not created again by the next run. Order:
# marker first (nothing hands the org out any more), then sessions killed and the account locked / expired / nologin, then the home
# cleaned (credentials, kubeconfig, WireGuard keys) except the skeleton files and the marker. `add` reverses all of it.
gw_mark_deleted() {
  local home="/home/${org}"
  if [ "${dry_run}" == "true" ]; then say "[dry-run] would: lock the gw account ${org} (nologin, expired), clean ${home} and leave ${home}/.delete"; return 0; fi
  if ! org_has_account; then
    sudo useradd -m -s /usr/sbin/nologin "${org}" 2> "${tmpdir}/useradd.err" || { warn "no gw account ${org} to hold the deleted marker: $(tr '\n' ' ' < "${tmpdir}/useradd.err")"; return 1; }
  fi
  sudo chmod o+x "${home}"
  sudo bash -c "umask 022; echo \"deleted \$(date +%Y-%m-%dT%H:%M:%S%z) by vcfa_org delete: hidden from every phase until vcfa_org.sh add ${org}\" > '${home}/.delete'" \
    || { warn "could not write ${home}/.delete"; return 1; }
  sudo pkill -KILL -u "${org}" 2> /dev/null
  sudo usermod -L -e 1 -s /usr/sbin/nologin "${org}" 2> "${tmpdir}/usermod.err" || warn "locking the gw account ${org} failed: $(tr '\n' ' ' < "${tmpdir}/usermod.err")"
  sudo find "${home}" -mindepth 1 -maxdepth 1 ! -name .delete ! -name .bashrc ! -name .profile ! -name .bash_logout -exec rm -rf {} + 2> /dev/null
  say "gw account ${org} locked and cleaned, marker ${home}/.delete written"
}
gw_unmark_deleted() { # add: undo gw_mark_deleted (before any phase runs: the phases hide an org that still has the marker)
  org_is_deleted || return 0
  if [ "${dry_run}" == "true" ]; then say "[dry-run] would: remove /home/${org}/.delete and unlock the gw account ${org}"; return 0; fi
  sudo rm -f "/home/${org}/.delete" "/home/${org}/.assigned"
  sudo usermod -U -e '' -s /bin/bash "${org}" 2> /dev/null || warn "unlocking the gw account ${org} failed"
  say "${org} was marked deleted: marker removed, gw account unlocked"
}
del_files_and_account() {
  local d
  for d in $(org_dirs); do sudo test -d "${d}" && [ "${d}" != "/home/${org}" ] && do_it "remove ${d}" sudo rm -rf "${d}"; done
  if org_has_account || [ "${deployment_kind}" == "vApp" ] || others_have_accounts; then
    gw_mark_deleted || warn "${org} is not marked deleted: the next run that sees it in the spec may create it again"
    run_phase gw-org-api exclude; run_phase gw-accounts exclude   # the org leaves the list handed out and the gw's WireGuard peers
  fi
}
do_delete() {
  check_idle
  # vApp use case (the org has a gw account): gw-org-api hands out any org with a home folder and no /home/<org>/.assigned. An org a
  # student already holds is refused without --force; a free one is claimed FIRST (same marker the API writes, created atomically), so no
  # student can be given it while it is being deleted. A marker left by an earlier, failed vcfa_org.sh / cleaning run is our own and
  # is reused. The marker goes with the account at the end; when the delete fails halfway the org stays claimed.
  if org_is_deleted; then
    say "${org} is already marked deleted (/home/${org}/.delete): continuing, what is left gets removed"
  elif org_has_account; then
    local marker="/home/${org}/.assigned"
    if sudo test -e "${marker}"; then
      if sudo grep -qE "to (vcfa_org delete|vcfa_tenant_cleaning)" "${marker}" 2> /dev/null; then say "${org} is already claimed by an earlier delete/cleaning run"
      elif [ "${force}" != "true" ]; then die "${org} is assigned to a student ($(sudo cat "${marker}" 2> /dev/null | head -1)): not deleting it. Use --force to delete it anyway"
      else warn "${org} is assigned to a student: deleting it anyway (--force)"; fi
    elif [ "${dry_run}" == "true" ]; then say "[dry-run] would: claim ${org} (create ${marker}) so gw-org-api cannot hand it out"
    else
      sudo bash -c "set -o noclobber; echo \"assigned \$(date +%Y-%m-%dT%H:%M:%S%z) to vcfa_org delete\" > '${marker}'" 2> /dev/null \
        && say "claimed ${org} (${marker}): gw-org-api no longer hands it out" \
        || { [ "${force}" == "true" ] || die "${org} was assigned to a student a moment ago: not deleting it. Use --force to delete it anyway"; }
    fi
  fi
  org_lookup
  say "ABOUT TO DELETE the org ${org} and everything of it: VKS clusters, namespaces, deployments, accounts, Git repo, Vault and Avi/DNS entries (json ${jsonFile})"
  if [ -n "${org_item}" ]; then
    if org_has_account || [ "${deployment_kind}" == "vApp" ] || others_have_accounts; then ok_say "NOTE: ${org} is still in the spec: it stays hidden from every phase by /home/${org}/.delete until vcfa_org.sh add ${org}"
    else ok_say "NOTE: ${org} is still in the spec and this gw has no accounts: the next vcf_bootstrap.sh run recreates it"; fi
  fi
  if [ "${assume_yes}" != "true" ] && [ "${dry_run}" != "true" ]; then
    read -r -p "Type yes to delete ${org}: " answer; [ "${answer}" == "yes" ] || die "not confirmed, nothing done"
  fi
  # reverse of the bootstrap order: tenant (accounts, workloads), watcher, provider, git, avi, vault, gw
  del_harbor
  del_avi_user
  del_vcenter
  del_workloads || die "the workloads of ${org} could not be removed: stopped before deleting the org"
  run_phase supervisor-blueprint-watcher all
  del_vcfa_org || die "deleting the VCF-A org failed: stopped (see above)"
  del_avi_tenant
  del_git
  avi_dns_domains remove
  del_vault
  del_files_and_account
  say "done"
}

do_recreate_vks() {
  org_lookup
  [ -n "${org_item}" ] || die "${org} is not in the spec (vcf_a_organizations)"
  [ "$(echo "${org_item}" | jq -r '.vks_cluster.enabled // false')" == "true" ] || die "${org} has no VKS cluster in the spec (vks_cluster.enabled): nothing would be created again"
  check_idle
  say "ABOUT TO DELETE the VKS cluster(s) and the deployments of ${org} and create a new VKS cluster (json ${jsonFile}); the org, its namespace and its accounts stay"
  if [ "${assume_yes}" != "true" ] && [ "${dry_run}" != "true" ]; then
    read -r -p "Type yes to recreate the VKS cluster of ${org}: " answer; [ "${answer}" == "yes" ] || die "not confirmed, nothing done"
  fi
  keep_namespaces="true"
  del_workloads || die "the workloads of ${org} could not be removed: stopped, nothing created"
  run_phase vcfa_tenant_bootstrap only || die "vcfa_tenant_bootstrap.sh failed"
  say "done"
}

case "${action}" in
  recreate-vks) do_recreate_vks ;;
  status) do_status ;;
  add) do_add ;;
  isolate) add_isolation ;;
  delete) do_delete ;;
esac
