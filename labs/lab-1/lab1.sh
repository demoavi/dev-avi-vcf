#!/bin/bash
# lab1.sh - drive the VCF Automation org catalog through the API, the same calls the org portal makes, in three steps:
#   1. create-2-vms                     deployment <name>          (first namespace, first VM image, first VM size, app <app>)
#   2. create-virtual-service-dynamic   deployment claude-vs       (app <app>, target port 80, DNS record, SSL, Trusted certificate)
#   3. create-2-vms                     deployment <name>-2        (same settings as step 1)
#   4. Avi check                         the DNS name of the HTTPRoute of step 2 must exist in Avi: parent VS (vsvip DNS entry)
#                                        -> child VS of that parent -> its pool group -> its pool(s), which must hold
#                                        2 members per successful create-2-vms step (4 with the two requests above); retried
#                                        because AKO needs a few seconds to update Avi.
# Every step is followed until its deployment ends. A report says, per deployment, whether the blueprint succeeded or
# failed (and why), the HTTP code and response time of every call, and min/avg/max per endpoint. Meant as a stress test
# on many student vApps: the last stdout line is a one-line machine readable RESULT, the exit code is 0 only when all
# three deployments succeeded.
#
# Usage: ./lab1.sh <vcfa-url> <org> <user> <password> <avi_username> <avi_password> <avi_tenant> <avi_url> [deployment-name] [app-name]
#   <vcfa-url>  e.g. https://sddc01-auto-vip.vcf9.lab
#   <org>       organization name, e.g. org-1
#   <user>      provider account allowed to open a session in that org (e.g. admin)
#   <password>  its password
#   <avi_username> <avi_password>  Avi account that can read the org's objects
#   <avi_tenant>   Avi tenant of the org (X-Avi-Tenant), e.g. org-1
#   <avi_url>      Avi controller, e.g. https://sddc01-avi.vcf9.lab
#   deployment-name defaults to test-claude (the three deployments are <name>, claude-vs, <name>-2, see the *_DEPLOYMENT_NAME variables),
#   app-name to test-claude. The virtual service picks its app from the Supervisor apps list, so the app must be
#   offered there (it appears once the step 1 VMs exist).
#
# Optional environment:
#   BLUEPRINT_VMS    catalog item of steps 1 and 3 (default create-2-vms)
#   BLUEPRINT_VS     catalog item of step 2 (default create-virtual-service-dynamic)
#   VM_DEPLOYMENT_NAME   deployment name of step 1 (default test-claude; the optional 9th argument does the same)
#   VS_DEPLOYMENT_NAME   deployment name of step 2 (default claude-vs)
#   VM2_DEPLOYMENT_NAME  deployment name of step 3 (default <step 1 name>-2)
#   NAME_SUFFIX      appended to every deployment name (use it to make parallel runs on one org unique)
#   VM_IMAGE_INDEX   which entry of the VM image list to use (default 0 = the first one)
#   DEPLOY_TIMEOUT   seconds to wait for each deployment (default 1200)
#   AVI_RETRY_TIMEOUT / AVI_RETRY_INTERVAL   how long (default 300 s) and how often (default 10 s) step 4 retries
#   POLL_INTERVAL    seconds between status polls (default 20)
#   HTTP_TIMEOUT     per-call curl --max-time (default 60)
#   CLEANUP          true = delete the deployments at the end (the DELETEs are timed too; default false)
#   REPORT_FILE      append one CSV line per run to this file
#                    (timestamp,host,org,result,seconds,calls,http_errors,step1,step2,step3,step4)
#
# Login: the provider session (user@system) is exchanged for a token scoped to <org> (OIDC jwt-bearer on the
# automation-relying-party client), which is what the catalog/deployment services accept.
# Needs: curl, jq, awk.

if [ $# -lt 8 ]; then
  echo "Usage: $0 <vcfa-url> <org> <user> <password> <avi_username> <avi_password> <avi_tenant> <avi_url> [deployment-name] [app-name]" >&2
  exit 1
fi
vcfa_url="${1%/}"; org="$2"; user="$3"; password="$4"
avi_username="$5"; avi_password="$6"; avi_tenant="$7"; avi_url="${8%/}"
app_name="${10:-test-claude}"
suffix="${NAME_SUFFIX:-}"
# catalog items (blueprints) and the virtual service deployment name; override from the environment if they are renamed
blueprint_vms="${BLUEPRINT_VMS:-create-2-vms}"
blueprint_vs="${BLUEPRINT_VS:-create-virtual-service-dynamic}"
# deployment names of the three requests; the optional 9th argument overrides the first one
vm_deployment_name="${9:-${VM_DEPLOYMENT_NAME:-test-claude}}"
vs_deployment_name="${VS_DEPLOYMENT_NAME:-claude-vs}"
vm2_deployment_name="${VM2_DEPLOYMENT_NAME:-${vm_deployment_name}-2}"
image_index="${VM_IMAGE_INDEX:-0}"; deploy_timeout="${DEPLOY_TIMEOUT:-1200}"; poll_interval="${POLL_INTERVAL:-20}"
http_timeout="${HTTP_TIMEOUT:-60}"; cleanup="${CLEANUP:-false}"
avi_retry_timeout="${AVI_RETRY_TIMEOUT:-300}"; avi_retry_interval="${AVI_RETRY_INTERVAL:-10}"
api_version="9.1.0"
accept="Accept: application/json;version=${api_version}"

calls_file=$(mktemp); body_file=$(mktemp); header_file=$(mktemp); avi_jar=$(mktemp)
start_epoch=$(date +%s.%N)
fatal_detail=""
# one entry per step, same index in every array
step_bp=(); step_name=(); step_id=(); step_status=(); step_secs=(); step_result=(); step_detail=()

# call <label> <curl args...>: runs curl with a timeout, records "<label>\t<http code>\t<seconds>", leaves the body in
# CALL_BODY and the code in CALL_CODE (000 when curl itself failed: DNS, connect, timeout).
call() {
  local label="$1" out; shift
  out=$(curl -sk --max-time "${http_timeout}" -o "${body_file}" -D "${header_file}" -w '%{http_code} %{time_total}' "$@" 2> /dev/null)
  CALL_CODE="${out%% *}"; CALL_TIME="${out##* }"
  [ -n "${CALL_CODE}" ] || { CALL_CODE="000"; CALL_TIME="0"; }
  CALL_BODY=$(cat "${body_file}")
  printf '%s\t%s\t%s\n' "${label}" "${CALL_CODE}" "${CALL_TIME}" >> "${calls_file}"
}
api() { call "$1" "${vcfa_url}/$2" -H "Authorization: Bearer ${token}" -H "Accept: application/json"; }
ok() { [[ "${CALL_CODE}" == 2[0-9][0-9] ]]; }
fail() { fatal_detail="${fatal_detail:-$*}"; echo "ERROR: $*" >&2; exit 1; }

report() {
  local rc=$? i overall="SUCCESS"
  local total; total=$(awk -v s="${start_epoch}" -v e="$(date +%s.%N)" 'BEGIN{printf "%.1f", e-s}')
  [ "${rc}" -eq 0 ] || overall="FAILED"
  [ "${#step_result[@]}" -eq 4 ] || overall="FAILED"
  for i in "${!step_result[@]}"; do [ "${step_result[$i]}" == "SUCCESS" ] || overall="FAILED"; done
  local n_calls n_err
  n_calls=$(wc -l < "${calls_file}"); n_err=$(awk -F'\t' '$2 !~ /^2[0-9][0-9]$/ {n++} END{print n+0}' "${calls_file}")
  echo
  echo "================ REPORT ================"
  echo "target      : ${vcfa_url}  org=${org}"
  echo "overall     : ${overall}"
  [ -n "${fatal_detail}" ] && echo "detail      : ${fatal_detail}"
  echo "total time  : ${total}s, ${n_calls} HTTP calls, ${n_err} not 2xx"
  echo
  echo "steps:"
  printf '  %-4s %-32s %-26s %-8s %-18s %7s\n' "step" "blueprint / check" "deployment / dns name" "result" "status" "time(s)"
  for i in "${!step_bp[@]}"; do
    printf '  %-4s %-32s %-26s %-8s %-18s %7s\n' "$((i+1))" "${step_bp[$i]}" "${step_name[$i]}" "${step_result[$i]:-NOT RUN}" "${step_status[$i]:-n/a}" "${step_secs[$i]:--}"
    [ -n "${step_detail[$i]:-}" ] && echo "       detail: ${step_detail[$i]}"
  done
  echo
  printf '%-48s %5s %6s %9s %9s %9s\n' "call" "count" "non2xx" "min(s)" "avg(s)" "max(s)"
  awk -F'\t' '{ n[$1]++; if ($2 !~ /^2[0-9][0-9]$/) e[$1]++; t=$3+0; s[$1]+=t; if (!($1 in mn) || t<mn[$1]) mn[$1]=t; if (t>mx[$1]) mx[$1]=t; if (!($1 in ord)) {ord[$1]=++k; name[k]=$1} }
       END { for (i=1;i<=k;i++) { l=name[i]; printf "%-48s %5d %6d %9.3f %9.3f %9.3f\n", l, n[l], e[l]+0, mn[l], s[l]/n[l], mx[l] } }' "${calls_file}"
  echo
  echo "every call (label, HTTP code, seconds):"
  awk -F'\t' '{printf "  %-48s %s  %ss\n", $1, $2, $3}' "${calls_file}"
  echo "========================================"
  local s1="${step_result[0]:-NOT_RUN}" s2="${step_result[1]:-NOT_RUN}" s3="${step_result[2]:-NOT_RUN}" s4="${step_result[3]:-NOT_RUN}"
  [ -n "${REPORT_FILE:-}" ] && echo "$(date -Is),${vcfa_url},${org},${overall},${total},${n_calls},${n_err},${s1},${s2},${s3},${s4}" >> "${REPORT_FILE}"
  echo "RESULT=${overall} step1=${s1} step2=${s2} step3=${s3} step4=${s4} seconds=${total} calls=${n_calls} http_errors=${n_err}"
  rm -f "${calls_file}" "${body_file}" "${header_file}" "${avi_jar}"
  [ "${overall}" == "SUCCESS" ] && exit 0 || exit 1
}
trap 'report' EXIT

# ---- login ----------------------------------------------------------------------------------------------------------
call "login provider session" -X POST "${vcfa_url}/cloudapi/1.0.0/sessions/provider" -H "${accept}" \
  -H "Authorization: Basic $(printf '%s@system:%s' "${user}" "${password}" | base64 -w0)"
provider_token=$(tr -d '\r' < "${header_file}" | awk -F': ' 'tolower($1) == "x-vmware-vcloud-access-token" {print $2}')
[ -n "${provider_token}" ] || fail "login failed on ${vcfa_url} for ${user}@system (HTTP ${CALL_CODE})"
call "lookup org" "${vcfa_url}/cloudapi/1.0.0/orgs?filter=name==${org}" -H "${accept}" -H "Authorization: Bearer ${provider_token}"
org_id=$(echo "${CALL_BODY}" | jq -r '.values[0].id // empty')
[ -n "${org_id}" ] || fail "organization ${org} not found (HTTP ${CALL_CODE})"
call "lookup oidc client" "${vcfa_url}/cloudapi/1.0.0/openIdProvider/relyingParties" -H "${accept}" -H "Authorization: Bearer ${provider_token}"
client_id=$(echo "${CALL_BODY}" | jq -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // empty')
[ -n "${client_id}" ] || fail "automation-relying-party client not found (HTTP ${CALL_CODE})"
call "org token exchange" -X POST "${vcfa_url}/oidc/oauth2/token" -H "${accept}" -H "x-vmware-vcloud-tenant-context: ${org_id##*:}" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  --data-urlencode "scope=openid profile email phone groups vcd_idp" \
  --data-urlencode "assertion=${provider_token}" --data-urlencode "client_id=${client_id}"
token=$(echo "${CALL_BODY}" | jq -r '.access_token // empty')
[ -n "${token}" ] || fail "could not get an org-scoped token for ${org} (HTTP ${CALL_CODE})"
api "catalog items" "catalog/api/items?size=200"
catalog_items="${CALL_BODY}"

# ---- one step: look up the item, build its inputs, request it, follow it ---------------------------------------------
# run_step <blueprint> <deployment name> <kind: vms|vs>. Records the outcome in the step_* arrays; never exits, so a
# failed step does not hide the next ones.
run_step() {
  local bp="$1" name="$2" kind="$3" idx item_id project_id version inputs ns body dep_id req_epoch status detail
  idx=${#step_bp[@]}
  step_bp[idx]="${bp}"; step_name[idx]="${name}"; step_result[idx]="FAILED"
  echo; echo "== step $((idx+1)): ${bp} -> deployment ${name}"

  item_id=$(echo "${catalog_items}" | jq -r --arg n "${bp}" '[.content[]? | select(.name == $n)][0].id // empty')
  project_id=$(echo "${catalog_items}" | jq -r --arg n "${bp}" '[.content[]? | select(.name == $n)][0].projectIds[0] // empty')
  [ -n "${item_id}" ] || { step_detail[idx]="catalog item ${bp} not found in ${org}"; return 1; }
  api "${bp}: versions" "catalog/api/items/${item_id}/versions"
  version=$(echo "${CALL_BODY}" | jq -r '.content[0].id // empty')     # newest first
  [ -n "${version}" ] || { step_detail[idx]="no version for ${bp} (HTTP ${CALL_CODE})"; return 1; }
  api "${bp}: form schema" "catalog/api/items/${item_id}/versions/${version}"
  local schema="${CALL_BODY}"
  api "${bp}: form data namespaces" "catalog/api/items/${item_id}/versions/${version}/data/namespaces"
  ns=$(echo "${CALL_BODY}" | jq -r '.content[0].id // empty')
  [ -n "${ns}" ] || { step_detail[idx]="no namespace offered (HTTP ${CALL_CODE})"; return 1; }

  if [ "${kind}" == "vms" ]; then
    local img flavor
    api "${bp}: form data vm images" "catalog/api/items/${item_id}/versions/${version}/data/namespaceclass-vmimages"
    img=$(echo "${CALL_BODY}" | jq -r --argjson i "${image_index}" '.content[$i].id // empty')
    flavor=$(echo "${schema}" | jq -r '.schema.properties.vm_flavor.enum[0] // empty'); [ -n "${flavor}" ] || flavor="best-effort-xsmall"
    [ -n "${img}" ] || { step_detail[idx]="no VM image at index ${image_index} (HTTP ${CALL_CODE})"; return 1; }
    inputs=$(jq -n --arg ns "${ns}" --arg img "${img}" --arg f "${flavor}" --arg a "${app_name}" \
      '{namespace: $ns, vm_image_id: $img, vm_flavor: $f, app: $a}')
  else
    local cert
    api "${bp}: form data apps" "catalog/api/items/${item_id}/versions/${version}/data/vro-actions/com.demo.supervisor/getSupervisorApps?namespace=${ns}"
    echo "${CALL_BODY}" | jq -e --arg a "${app_name}" 'any(.content[]?; .id == $a)' > /dev/null 2>&1 \
      || { step_detail[idx]="app ${app_name} is not offered by the Supervisor apps list of ${ns}: $(echo "${CALL_BODY}" | jq -c '[.content[]?.id]')"; return 1; }
    cert=$(echo "${schema}" | jq -r '[.schema.properties.ssl_cert.enum[]? | select(startswith("Trusted"))][0] // empty')
    [ -n "${cert}" ] || { step_detail[idx]="no Trusted certificate option in the form"; return 1; }
    inputs=$(jq -n --arg ns "${ns}" --arg a "${app_name}" --arg c "${cert}" \
      '{namespace: $ns, target_port: 80, app: $a, dns: true, ssl: true, ssl_cert: $c}')
  fi
  echo "inputs: $(echo "${inputs}" | jq -c .)"

  body=$(jq -n --arg d "${name}" --arg p "${project_id}" --arg v "${version}" --argjson i "${inputs}" \
    '{deploymentName: $d, projectId: $p, version: $v, bulkRequestCount: 1, inputs: $i}')
  call "${bp}: request" -X POST "${vcfa_url}/catalog/api/items/${item_id}/request" \
    -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" -H "Accept: application/json" -d "${body}"
  ok || { step_detail[idx]="request failed (HTTP ${CALL_CODE}): $(echo "${CALL_BODY}" | head -c 300)"; return 1; }
  dep_id=$(echo "${CALL_BODY}" | jq -r '.[0].deploymentId')
  step_id[idx]="${dep_id}"; req_epoch=$(date +%s)
  echo "requested ${name}: ${dep_id}"

  while true; do
    api "${bp}: poll status" "deployment/api/deployments/${dep_id}"
    status=$(echo "${CALL_BODY}" | jq -r '.status // empty' 2> /dev/null)
    echo "$(date +%H:%M:%S) ${name}: ${status:-unknown} (HTTP ${CALL_CODE})"
    step_status[idx]="${status}"
    case "${status}" in
      CREATE_SUCCESSFUL) step_result[idx]="SUCCESS"; break ;;
      CREATE_FAILED)
        api "${bp}: failure details" "deployment/api/deployments/${dep_id}/requests"
        step_detail[idx]=$(echo "${CALL_BODY}" | jq -r '[.content[]? | select(.status == "FAILED") | .details][0] // empty' | head -c 600)
        break ;;
    esac
    if [ $(( $(date +%s) - req_epoch )) -ge "${deploy_timeout}" ]; then
      step_detail[idx]="timed out after ${deploy_timeout}s (last status: ${status:-unknown})"; break
    fi
    sleep "${poll_interval}"
  done
  step_secs[idx]=$(( $(date +%s) - req_epoch ))
  [ "${step_result[idx]}" == "SUCCESS" ]
}

run_step "${blueprint_vms}" "${vm_deployment_name}${suffix}"   vms
run_step "${blueprint_vs}"  "${vs_deployment_name}${suffix}"   vs
run_step "${blueprint_vms}" "${vm2_deployment_name}${suffix}"  vms

# ---- step 4: Avi ------------------------------------------------------------------------------------------------------
avi_api() {
  call "$1" "${avi_url}/api/$2" -b "${avi_jar}" -H "X-Avi-Tenant: ${avi_tenant}" -H "X-CSRFToken: ${avi_csrf}" \
    -H "Referer: ${avi_url}" -H "X-Avi-Version: ${avi_version}" -H "Accept: application/json"
}
# One pass over the chain: vsvip with the DNS name -> parent VS -> child VS (its vh_matches host is the DNS name) ->
# pool group -> pool(s) -> number of members. avi_stage says how far it got, avi_chain_info what it found. Returns 0 when
# the members found equal avi_expected.
avi_chain() {
  local vsvip_uuid parent_uuid child_uuid pg_uuid pool_ref total=0 n vs_list
  avi_stage="no vsvip with DNS entry ${avi_host}"; avi_members=""; avi_chain_info=""
  avi_api "avi: vsvip list" "vsvip?page_size=200"
  ok || { avi_stage="vsvip list failed (HTTP ${CALL_CODE})"; return 1; }
  vsvip_uuid=$(echo "${CALL_BODY}" | jq -r --arg h "${avi_host}" '[.results[]? | select(any(.dns_info[]?; .fqdn == $h))][0].uuid // empty' 2> /dev/null)
  [ -n "${vsvip_uuid}" ] || return 1
  avi_chain_info="vsvip ${vsvip_uuid}"
  avi_stage="no parent VS on vsvip ${vsvip_uuid}"
  avi_api "avi: virtualservice list" "virtualservice?page_size=200"
  ok || { avi_stage="virtualservice list failed (HTTP ${CALL_CODE})"; return 1; }
  vs_list="${CALL_BODY}"
  parent_uuid=$(echo "${vs_list}" | jq -r --arg v "${vsvip_uuid}" '[.results[]? | select(.type == "VS_TYPE_VH_PARENT" and ((.vsvip_ref // "") | endswith($v)))][0].uuid // empty' 2> /dev/null)
  [ -n "${parent_uuid}" ] || return 1
  avi_chain_info="${avi_chain_info} > parent ${parent_uuid}"
  avi_stage="no child VS of parent ${parent_uuid} for host ${avi_host}"
  child_uuid=$(echo "${vs_list}" | jq -r --arg p "${parent_uuid}" --arg h "${avi_host}" \
    '[.results[]? | select(((.vh_parent_vs_ref // "") | endswith($p)) and any(.vh_matches[]?; .host == $h))][0].uuid // empty' 2> /dev/null)
  [ -n "${child_uuid}" ] || return 1
  pg_uuid=$(echo "${vs_list}" | jq -r --arg c "${child_uuid}" '[.results[]? | select(.uuid == $c)][0].pool_group_ref // empty' 2> /dev/null)
  pg_uuid="${pg_uuid##*/}"
  avi_chain_info="${avi_chain_info} > child ${child_uuid}"
  avi_stage="child VS ${child_uuid} has no pool group"
  [ -n "${pg_uuid}" ] || return 1
  avi_api "avi: poolgroup" "poolgroup/${pg_uuid}"
  ok || { avi_stage="pool group ${pg_uuid} lookup failed (HTTP ${CALL_CODE})"; return 1; }
  avi_chain_info="${avi_chain_info} > poolgroup ${pg_uuid}"
  avi_stage="pool group ${pg_uuid} has no pool"
  local pool_refs; pool_refs=$(echo "${CALL_BODY}" | jq -r '.members[]?.pool_ref // empty' 2> /dev/null)
  [ -n "${pool_refs}" ] || return 1
  for pool_ref in ${pool_refs}; do
    avi_api "avi: pool" "pool/${pool_ref##*/}"
    ok || { avi_stage="pool ${pool_ref##*/} lookup failed (HTTP ${CALL_CODE})"; return 1; }
    n=$(echo "${CALL_BODY}" | jq -r '(.servers // []) | length' 2> /dev/null); total=$((total + ${n:-0}))
    avi_chain_info="${avi_chain_info} > pool ${pool_ref##*/} (${n:-0} members)"
  done
  avi_members="${total}"
  avi_stage="pool members: ${total}, expected ${avi_expected}"
  [ "${total}" -eq "${avi_expected}" ]
}

run_avi_check() {
  local idx=${#step_bp[@]} vs_idx=1 deadline attempt=0 vs_ok=0 vms_ok=0 i
  step_bp[idx]="avi check"; step_name[idx]="-"; step_result[idx]="FAILED"
  echo; echo "== step $((idx+1)): Avi check on ${avi_url} (tenant ${avi_tenant})"
  [ "${step_result[${vs_idx}]:-}" == "SUCCESS" ] || { step_detail[idx]="skipped: step 2 (virtual service) did not succeed"; return 1; }
  # the DNS name the blueprint put in the HTTPRoute, read from the deployment itself
  api "avi: deployment resources" "deployment/api/deployments/${step_id[${vs_idx}]}/resources"
  avi_host=$(echo "${CALL_BODY}" | jq -r '[.content[]? | select(.name == "AVI_HTTPROUTE")][0].properties.manifest.spec.hostnames[0] // empty' 2> /dev/null)
  [ -n "${avi_host}" ] || { step_detail[idx]="no HTTPRoute hostname found in deployment ${step_name[${vs_idx}]} (HTTP ${CALL_CODE})"; return 1; }
  step_name[idx]="${avi_host}"
  # 2 VMs per successful create-2-vms
  for i in "${!step_bp[@]}"; do [ "${step_bp[$i]}" == "${blueprint_vms}" ] && [ "${step_result[$i]}" == "SUCCESS" ] && vms_ok=$((vms_ok + 1)); done
  avi_expected=$((vms_ok * 2))
  echo "expecting DNS name ${avi_host} with ${avi_expected} pool members (${vms_ok} successful create-2-vms)"

  call "avi: login" -X POST "${avi_url}/login" -c "${avi_jar}" --data-urlencode "username=${avi_username}" --data-urlencode "password=${avi_password}"
  ok || { step_detail[idx]="Avi login failed on ${avi_url} for ${avi_username} (HTTP ${CALL_CODE})"; return 1; }
  avi_csrf=$(awk '$6 == "csrftoken" {print $7}' "${avi_jar}"); avi_version="31.1.1"
  avi_api "avi: cluster version" "cluster/version"
  avi_version=$(echo "${CALL_BODY}" | jq -r '.Version // empty' 2> /dev/null); avi_version="${avi_version:-31.1.1}"

  local start; start=$(date +%s); deadline=$((start + avi_retry_timeout))
  while true; do
    attempt=$((attempt + 1))
    if avi_chain; then
      echo "$(date +%H:%M:%S) avi attempt ${attempt}: ${avi_chain_info}"
      step_status[idx]="${avi_members} members"; step_result[idx]="SUCCESS"; break
    fi
    echo "$(date +%H:%M:%S) avi attempt ${attempt}: not yet - ${avi_stage}"
    step_status[idx]="${avi_members:+${avi_members} members}"; step_status[idx]="${step_status[idx]:-n/a}"
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      step_detail[idx]="after ${attempt} attempts / ${avi_retry_timeout}s: ${avi_stage}${avi_chain_info:+ (found: ${avi_chain_info})}"; break
    fi
    sleep "${avi_retry_interval}"
  done
  step_secs[idx]=$(( $(date +%s) - start ))
  [ "${step_result[idx]}" == "SUCCESS" ]
}
run_avi_check

if [ "${cleanup}" == "true" ]; then
  echo; echo "== cleanup"
  for i in 2 1 0; do
    [ -n "${step_id[$i]:-}" ] || continue
    call "${step_bp[$i]}: delete" -X DELETE "${vcfa_url}/deployment/api/deployments/${step_id[$i]}" -H "Authorization: Bearer ${token}"
    ok || echo "WARNING: deleting ${step_name[$i]} returned HTTP ${CALL_CODE}" >&2
  done
fi
exit 0
