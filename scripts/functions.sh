#!/bin/bash
#
# Shared bash helper functions for vcf_bootstrap.sh (VCD/vApp use case) -
# split out of that script to keep it from growing further; sourced once
# near its own top via "${script_dir}/functions.sh". Every function here
# is a genuine top-level helper vcf_bootstrap.sh calls directly during its
# own execution - NOT the several separate show_help/prompt_choice/etc.
# definitions that also appear inside vcf_bootstrap.sh's own heredocs
# (those generate other standalone scripts like auth_vks_context.sh and
# must stay self-contained wherever they end up deployed/run, so they are
# deliberately left untouched).
#
# deployment_kind distinguishes vApp-use-case from SDDC-use-case runs -
# used by log_notify's own gchat messages (both eventually post to the
# same space) and by esxi-bootstrap.sh's own VCD-vs-govc power-cycle
# branch. NOT hardcoded here: the two use cases share this same
# vcf_bootstrap.sh/functions.sh, driven by two SEPARATE operators (each
# with its own CRD/kopf watch - the vApp operator here in epc-vapp, an
# equivalent one for the sddc CRD elsewhere). epc-vapp's own userdata.py
# always renders "deployment_kind": "vApp" into both bash/variables.sh
# and the deployment JSON, so this file never actually falls back to the
# default below for a real vApp run - the default exists purely for the
# sddc use case, which (as of 2026-09-28) has no equivalent
# CRD/variables.sh rendering of its own yet, so it can never set this
# explicitly and needs the correct value by default rather than an
# empty/broken tag.
: "${deployment_kind:=sddc}"

# This org has far more VMs (other users' labs) than fit in one page - a
# single unpaginated page silently drops results past its page size and
# would make an existing VM look "not found" (the exact class of bug
# vcd_client.py's own query_records() was already hardened against).
vcd_find_vm_href() {
  local target_name="$1"
  local page=1
  local page_size=128
  while true; do
    local resp=$(curl -sk "https://${vcd_host}/api/query?type=vm&format=records&page=${page}&pageSize=${page_size}" \
      -H "Authorization: Bearer ${vcd_auth_token}" \
      -H "Accept: application/*+json;version=${vcd_api_version}")
    local href=$(echo "${resp}" | jq -r --arg name "${target_name}" '[.record[] | select(.name == $name) | .href][0] // empty')
    if [ -n "${href}" ]; then
      echo "${href}"
      return 0
    fi
    # resultTotal isn't reliably present in this API's response, so don't
    # depend on it - a short page (fewer records than requested) is the
    # actual "last page" signal.
    local record_count=$(echo "${resp}" | jq -r '.record | length' 2> /dev/null)
    # No answer / not JSON (no VCD to talk to): not a number, so stop instead of paging forever.
    case "${record_count}" in ''|*[!0-9]*) return 1 ;; esac
    if [ "${record_count}" -lt "${page_size}" ]; then
      return 1
    fi
    ((page++))
  done
}

# Gates on the operator having actually finished this host's boot-ISO
# upload+insert before we ever hit its HTTPS reachability loop below -
# vapp_operator.py only powers an ESXi VM on AFTER its media upload/insert
# completes, and that pipeline is serialized per host (host 1 alone pays
# the one-time base-ISO download+extract cost), so it can legitimately take
# far longer than a fixed HTTPS-reachability timeout budget. Polling this
# real signal instead avoids racing a guessed duration against however long
# that upload happens to take. Confirmed live against this VCD's own
# api/query?type=vm records: the field is a plain string, "status" ==
# "POWERED_ON"/"POWERED_OFF" (not a numeric/XML status code).
vcd_wait_vm_powered_on() {
  local target_name="$1"
  local retry=300 pause=20 attempt=1
  while true; do
    local page=1
    local page_size=128
    local status=""
    while true; do
      local resp=$(curl -sk "https://${vcd_host}/api/query?type=vm&format=records&page=${page}&pageSize=${page_size}" \
        -H "Authorization: Bearer ${vcd_auth_token}" \
        -H "Accept: application/*+json;version=${vcd_api_version}")
      status=$(echo "${resp}" | jq -r --arg name "${target_name}" '[.record[] | select(.name == $name) | .status][0] // empty')
      if [ -n "${status}" ]; then
        break
      fi
      local record_count=$(echo "${resp}" | jq -r '.record | length')
      if [ "${record_count}" -lt "${page_size}" ]; then
        break
      fi
      ((page++))
    done
    if [ "${status}" == "POWERED_ON" ]; then
      return 0
    fi
    if [ ${attempt} -eq ${retry} ]; then
      echo "ERROR: ${target_name} not POWERED_ON in VCD after ${attempt} attempts of ${pause} seconds (last status='${status:-not found}')"
      return 1
    fi
    sleep ${pause}
    ((attempt++))
  done
}

# sddc use case's own equivalent of vcd_wait_vm_powered_on - same retry/
# pause budget, but against the underlying/external vCenter directly via
# govc (GOVC_* already exported by the caller) rather than VCD's query
# API, since sddc's ESXi VMs live there instead of inside a VCD-managed
# vApp.
govc_wait_vm_powered_on() {
  local target_name="$1"
  local retry=300 pause=20 attempt=1
  while true; do
    local power_state=$(govc vm.info -json "${target_name}" 2>/dev/null | jq -r '.virtualMachines[0].runtime.powerState // empty')
    if [ "${power_state}" == "poweredOn" ]; then
      return 0
    fi
    if [ ${attempt} -eq ${retry} ]; then
      echo "ERROR: ${target_name} not poweredOn in vCenter after ${attempt} attempts of ${pause} seconds (last state='${power_state:-not found}')"
      return 1
    fi
    sleep ${pause}
    ((attempt++))
  done
}

# log_only just echoes (already captured by the caller's stdout redirect
# into vcf_bootstrap.log); log_notify also posts to gchat AND writes the
# same message into a VCD metadata key (vcf_bootstrap_progress) on gw's own
# VM, for milestones - lets the operator/anything else with VCD API access
# poll "what's this script currently doing" directly, without needing
# someone to relay gchat messages. jq/sed build the JSON/XML bodies so
# message text is never hand-quoted into a curl argument (the same class
# of bug that broke the kickstart heredoc earlier in this project).
#
# vcd_login sets vcd_host/vcd_user/vcd_password/vcd_org/vcd_api_version/
# vcd_auth_token/gw_vm_href as globals - log_notify's own VCD-metadata
# posting (vcf_bootstrap_progress) depends on vcd_auth_token/
# vcd_api_version/gw_vm_href being set, so every self-contained phase
# script that wants that progress reporting to work (not just the
# google_webhook + stdout echo, which work regardless) calls this once
# near its own top, right after sourcing variables.sh/functions.sh.
vcd_login() {
  # The sddc use case has no VCD (no .vcd in its spec): nothing to log in to, and gw_vm_href stays unset, which log_notify
  # tolerates. Without this every phase hung here, paging a VCD that does not exist.
  if [ "${deployment_kind}" != "vApp" ]; then
    return 0
  fi
  vcd_host=$(jq -r .vcd.host $jsonFile)
  vcd_user=$(jq -r .vcd.user $jsonFile)
  vcd_password=$(jq -r .vcd.password $jsonFile)
  vcd_org=$(jq -r .vcd.org $jsonFile)
  vcd_api_version=$(jq -r .vcd.apiVersion $jsonFile)
  vcd_auth_token=$(curl -sk -X POST "https://${vcd_host}/cloudapi/1.0.0/sessions" \
    -H "Authorization: Basic $(printf '%s' "${vcd_user}@${vcd_org}:${vcd_password}" | base64 -w0)" \
    -H "Accept: application/json;version=${vcd_api_version}" \
    -D - -o /dev/null | tr -d '\r' | awk -F': ' 'tolower($1) == "x-vmware-vcloud-access-token" {print $2}')
  gw_vm_href=$(vcd_find_vm_href "gw")
}
log_only() {
  echo "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: $1"
}
log_notify() {
  local message="$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc} (${deployment_kind}): $1"
  echo "${message}"
  if [ -n "${google_webhook}" ]; then
    curl -s -X POST -H 'Content-Type: application/json' --data "$(jq -n --arg text "${message}" '{text: $text}')" "${google_webhook}" >/dev/null 2>&1
  fi
  if [ -n "${gw_vm_href}" ]; then
    local escaped=$(echo "${message}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')
    curl -sk -X POST "${gw_vm_href}/metadata" \
      -H "Authorization: Bearer ${vcd_auth_token}" \
      -H "Accept: application/*+xml;version=${vcd_api_version}" \
      -H "Content-Type: application/vnd.vmware.vcloud.metadata+xml" \
      --data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Metadata xmlns=\"http://www.vmware.com/vcloud/v1.5\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><MetadataEntry><Key>vcf_bootstrap_progress</Key><TypedValue xsi:type=\"MetadataStringValue\"><Value>${escaped}</Value></TypedValue></MetadataEntry></Metadata>" >/dev/null 2>&1
  fi
}
create_api_session() {
  # $1 username, $2 password, $3 SDDC Manager/VCF Installer IP or FQDN, $4 output file
  local retry=3 pause=5 attempt=0
  while true ; do
    response=$(curl -k -s --write-out "\n%{http_code}" -X POST -d '{"username" : "'${1}'", "password" : "'${2}'"}' https://${3}/v1/tokens -H "Content-Type: application/json" -H "Accept: application/json")
    http_code=$(tail -n1 <<< "$response")
    content=$(sed '$ d' <<< "$response")
    if [[ ${http_code} == 200 ]] ; then
      echo ${content} | jq . -c -r | tee ${4} > /dev/null 2>&1
      break
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_notify "FAILED to get SDDC Manager API token after ${attempt} attempts of ${pause} seconds, http_response_code: ${http_code}"
      exit 100
    fi
    sleep ${pause}
    ((attempt++))
  done
}
sddc_manager_api() {
  # $1 retries, $2 pause between retries, $3 HTTP method, $4 http data,
  # $5 SDDC Manager IP or FQDN, $6 API endpoint, $7 Bearer token
  local retry=$1 pause=$2 attempt=0
  echo "HTTP ${3} API call to https://${5}/${6}"
  while true ; do
    response=$(curl -k -s -X ${3} --write-out "\n%{http_code}" -H 'Content-Type: application/json' -H 'Accept: application/json' -H "Authorization: Bearer ${7}" -d "${4}" https://${5}/${6})
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
    if [[ ${response_code} == 2[0-9][0-9] ]] ; then
      break
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_notify "FAILED HTTP ${3} API call to https://${5}/${6}, response code was: ${response_code}"
      echo "${response_body}"
      exit 100
    fi
    sleep ${pause}
    ((attempt++))
  done
}
create_nsx_api_session() {
  rm -f /tmp/nsx_cookies.txt /tmp/nsx_headers.txt
  local retry=6 pause=10 attempt=0
  while true ; do
    http_code=$(curl -k -s -o /dev/null -w '%{http_code}' -c /tmp/nsx_cookies.txt -D /tmp/nsx_headers.txt \
      -X POST -d "j_username=admin&j_password=${generic_password}" "https://${ip_nsx_vip}/api/session/create")
    if [[ ${http_code} == 200 ]]; then
      return
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_notify "ERROR: FAILED to create NSX API session, http_response_code: ${http_code}"
      exit 100
    fi
    sleep ${pause}
    ((attempt++))
  done
}
nsx_api() {
  # $1 retries, $2 pause, $3 HTTP method, $4 API endpoint, $5 http data - result lands in response_body/response_code
  local retry=$1 pause=$2 attempt=0
  while true ; do
    response=$(curl -k -s -X ${3} --write-out "\n%{http_code}" -b /tmp/nsx_cookies.txt \
      -H "$(grep -i X-XSRF-TOKEN /tmp/nsx_headers.txt | tr -d '\r\n')" \
      -H 'Content-Type: application/json' -d "${5}" "https://${ip_nsx_vip}/${4}")
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
    if [[ ${response_code} == 2[0-9][0-9] ]] ; then
      break
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_notify "ERROR: FAILED HTTP ${3} NSX API call to ${4}, response code was: ${response_code}: ${response_body}"
      exit 100
    fi
    sleep ${pause}
    ((attempt++))
  done
}
nsx_get_object() {
  create_nsx_api_session
  nsx_api 2 2 GET "$1" ""
}
nsx_set_object() {
  create_nsx_api_session
  nsx_api 2 2 "$2" "$1" "$3"
}
nsx_retrieve_object_path() {
  nsx_get_object "$1"
  echo ${response_body} | jq -c -r --arg arg "$2" '.results[] | select(.display_name == $arg) | .path'
}
nsx_retrieve_object_id() {
  nsx_get_object "$1"
  echo ${response_body} | jq -c -r --arg arg "$2" '.results[] | select(.display_name == $arg) | .id'
}
avi_login() {
  rm -f /tmp/avi_cookies.txt
  curl -s -k -X POST -H 'Content-Type: application/json' \
    -d "{\"username\": \"admin\", \"password\": \"${generic_password}\"}" \
    -c /tmp/avi_cookies.txt "https://${ip_avi}/login" > /dev/null
  avi_csrftoken=$(grep csrftoken /tmp/avi_cookies.txt | awk '{print $7}')
  if [ -z "${avi_csrftoken}" ]; then
    log_notify "ERROR: Avi csrftoken is undefined after login"
    exit 100
  fi
}
avi_api() {
  # $1 retries, $2 pause, $3 HTTP method, $4 http data, $5 API endpoint,
  # $6 X-Avi-Tenant (default admin - upgrade_avi.sh's version check needs
  # "*" instead), $7 optional local file path to upload as multipart
  # (api/image, for controller upgrades) instead of sending $4 as JSON.
  local retry=$1 pause=$2 attempt=0
  local tenant=${6:-admin}
  while true ; do
    if [ -z "${7}" ]; then
      response=$(curl -k -s -X ${3} --write-out "\n%{http_code}" -b /tmp/avi_cookies.txt \
        -H "X-CSRFToken: ${avi_csrftoken}" -H "X-Avi-Tenant: ${tenant}" -H "X-Avi-Version: ${avi_version}" \
        -H 'Content-Type: application/json' -H "Referer: https://${ip_avi}" -d "${4}" "https://${ip_avi}/${5}")
    else
      response=$(curl -k -s -X ${3} --write-out "\n%{http_code}" -b /tmp/avi_cookies.txt \
        -H "X-CSRFToken: ${avi_csrftoken}" -H "X-Avi-Tenant: ${tenant}" -H "X-Avi-Version: ${avi_version}" \
        -H "Referer: https://${ip_avi}" "https://${ip_avi}/${5}" -F "file=@${7}")
    fi
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
    if [[ ${response_code} == 2[0-9][0-9] ]] ; then
      break
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_notify "ERROR: FAILED HTTP ${3} Avi API call to ${5}, response code was: ${response_code}: ${response_body}"
      exit 100
    fi
    sleep ${pause}
    ((attempt++))
  done
}
create_vcenter_api_session() {
  local retry=10 pause=20 attempt=0
  while true ; do
    response=$(curl -k -s --write-out "\n%{http_code}" -X POST \
      -u "administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile):${generic_password}" \
      "https://${basename_sddc}-vc01.${domain}/api/session" -H 'Content-Type: application/json')
    http_code=$(tail -n1 <<< "$response")
    vcenter_token=$(sed '$ d' <<< "$response" | tr -d '"')
    if [[ ${http_code} == 20[0-9] ]] && [ ${#vcenter_token} -eq 32 ]; then
      return
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_notify "ERROR: FAILED to create vCenter API session, http_response_code: ${http_code}"
      exit 100
    fi
    sleep ${pause}
    ((attempt++))
  done
}
vcenter_api() {
  # $1 retries, $2 pause, $3 HTTP method, $4 API endpoint, $5 http data
  local retry=$1 pause=$2 attempt=0
  while true ; do
    response=$(curl -k -s -X ${3} --write-out "\n%{http_code}" -H "vmware-api-session-id: ${vcenter_token}" \
      -H 'Content-Type: application/json' -d "${5}" "https://${basename_sddc}-vc01.${domain}/${4}")
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
    if [[ ${response_code} == 2[0-9][0-9] ]] ; then
      break
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_notify "ERROR: FAILED HTTP ${3} vCenter API call to ${4}, response code was: ${response_code}: ${response_body}"
      exit 100
    fi
    sleep ${pause}
    ((attempt++))
  done
}
log_message() {
  local message="${1}"
  local log_file="${2}"
  local slack_url="${3}"
  local google_url="${4}"
  if [[ -z "${message}" ]]; then
    echo "Error: message is missing."
    return 1
  fi
  if [[ -f "${log_file}" ]]; then echo "${message}" >> ${log_file} ; else echo "${message}"; fi
  if [ -z "${slack_url}" ] ; then : ; else curl -X POST -H "Content-type: application/json" -d "{\"text\":\"${message}\"}" "${slack_url}" > /dev/null 2>&1; fi
  if [[ -z "${google_url}" ]]; then : ; else curl -X POST -H "Content-Type: application/json" -d "{\"text\":\"${message}\"}" "${google_url}" > /dev/null 2>&1; fi
}
#
# Waits until VCF Automation answers calmly before the provider work starts: "vcfa_gate_good" (default 5) consecutive
# answers of the gateway root page (the same URL the gw's VIP probe watches: a 301/200 means the gateway VIP is held and the
# proxies run) in under "vcfa_gate_limit_sec" (default 3) seconds, polled every 10 s, for at most "vcfa_gate_max_wait_sec"
# (default 900). Right after the SDDC build, and again after the stabilization phase restarted the API server, the platform
# can still be busy re-converging. Never fails: on timeout it logs a warning and the caller goes on, the provider script has
# its own retries. vcfa_health_gate=false skips it. $1 = https://<fqdn_vcfa>
#
vcfa_health_gate() {
  [ "${vcfa_health_gate:-true}" == "true" ] || return 0
  local host="$1" limit="${vcfa_gate_limit_sec:-3}" max_wait="${vcfa_gate_max_wait_sec:-900}" need="${vcfa_gate_good:-5}" waited=0 good=0 r
  while [ "${waited}" -lt "${max_wait}" ]; do
    r=$(curl -sk -m 15 -o /dev/null -w '%{http_code} %{time_total}' "${host}/" 2>/dev/null)
    if awk -v r="${r:-000 99}" -v l="${limit}" 'BEGIN{split(r, x, " "); exit !(x[1] + 0 >= 200 && x[1] + 0 < 400 && x[2] + 0 < l)}'; then
      good=$((good + 1))
      [ "${good}" -ge "${need}" ] && return 0
    else
      good=0
    fi
    sleep 10; waited=$((waited + 10))
  done
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A health gate: no ${need} consecutive answers under ${limit}s within ${max_wait}s (last: ${r:-none}), continuing anyway" "${log_file}" "${slack_webhook}" "${google_webhook}"
  return 0
}

# vApp use case only: name of the ESX host at a 1-based position of ips_esxi, read from names_esxi - decided once by the
# operator (the mgmt hosts, any workload hosts, the dedicated host), so nothing re-derives it from an index.
esxi_host_name() {
  echo "${names_esxi}" | jq -r ".[$(($1-1))]"
}

vcfa_login() {
  # A single failed answer is not final: VCF-A can miss a login for a few seconds under load (seen on 2026-10-26, it answered
  # fine again 40 s later), so try 5 times, 20 s apart, with a timeout per call, before giving up.
  local creds resp login_attempt
  creds=$(printf '%s@system:%s' "admin" "${generic_password}" | base64 -w0)
  for login_attempt in 1 2 3 4 5; do
    resp=$(curl -sk -m 30 -i -X POST "${VCFA_HOST}/cloudapi/1.0.0/sessions/provider" \
      -H "$ACCEPT" -H "$CONTENT_TYPE" -H "Authorization: Basic ${creds}")
    vcfa_token=$(printf '%s' "$resp" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
    [ -n "${vcfa_token}" ] && return 0
    if [ ${login_attempt} -lt 5 ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A provider login failed (attempt ${login_attempt} of 5), retrying in 20 seconds" "${log_file}" "" ""
      sleep 20
    fi
  done
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A provider login FAILED after 5 attempts" "${log_file}" "${slack_webhook}" "${google_webhook}"
  exit 100
}
vcfa_api() {
  # $1 method, $2 endpoint (relative to /), $3 data, $4 retries, $5 pause,
  # $6 optional extra header (e.g. "x-vmware-vcloud-tenant-context: <org
  # uuid>" - scopes the same provider token to a specific org, needed for
  # tenant-scoped resources like the "Organization Administrator" role and
  # per-org local users, both confirmed live invisible/rejected on a plain
  # provider-context call) - re-logs in once per call on a 401, since
  # provider tokens have a limited TTL and this script's total runtime
  # (region/ipSpace/providerGateway/org/vDC/networking, several with poll
  # loops) can comfortably outlast it. Result lands in response_body/
  # response_code.
  local method="$1" endpoint="$2" data="$3" retry="${4:-2}" pause="${5:-5}" extra_header="${6:-}" attempt=0
  while true; do
    if [ -n "${extra_header}" ]; then
      response=$(curl -sk -X "${method}" --write-out "\n%{http_code}" \
        -H "$ACCEPT" -H "$CONTENT_TYPE" -H "Authorization: Bearer ${vcfa_token}" -H "${extra_header}" \
        -d "${data}" "${VCFA_HOST}/${endpoint}")
    else
      response=$(curl -sk -X "${method}" --write-out "\n%{http_code}" \
        -H "$ACCEPT" -H "$CONTENT_TYPE" -H "Authorization: Bearer ${vcfa_token}" \
        -d "${data}" "${VCFA_HOST}/${endpoint}")
    fi
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
    if [[ ${response_code} == 2[0-9][0-9] ]]; then
      return 0
    fi
    if [[ ${response_code} == 401 ]]; then
      vcfa_login
    fi
    if [ ${attempt} -eq ${retry} ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${method} call to ${endpoint} FAILED, response code was: ${response_code}: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
      return 1
    fi
    sleep "${pause}"
    ((attempt++))
  done
}
vcfa_put_file() {
  # $1 item_id, $2 file_name (as listed by .../files), $3 transfer URL,
  # $4 local file path, $5 description for logging, $6 retries, $7 pause
  # - confirmed live these contentLibraryItem file PUTs can silently
  # transfer 0 bytes with curl itself reporting HTTP 200/no error
  # (previously not checked here at all, --data-binary piped to
  # /dev/null), leaving the item stuck NOT_READY/FAILED with no
  # indication which file (or that a file at all, versus some other
  # server-side issue) was actually the cause.
  #
  # Content-Type: application/octet-stream turned out to be one real
  # cause (curl's --data-binary defaults to
  # application/x-www-form-urlencoded when no Content-Type is set, which
  # the transfer endpoint accepts with a genuine 200 while discarding the
  # body) - but NOT the only one: confirmed live a second time, even with
  # this header set, the very same PUT (identical body/headers) can still
  # silently transfer 0 bytes with an unqualified HTTP 200, while an
  # immediate manual retry of the exact same transfer URL succeeds fully.
  # A likely per-transfer-session readiness race on VCFA's own transfer
  # endpoint, not something fixable by tweaking the request. So: an HTTP
  # 2xx here is necessary but still not sufficient - re-fetch this item's
  # own /files listing after every PUT and check bytesTransferred ==
  # expectedSizeBytes for THIS file by name before considering it done,
  # retrying the whole PUT (not just re-checking) otherwise.
  local item_id="$1" file_name="$2" transfer_url="$3" local_path="$4" description="$5" retry="${6:-3}" pause="${7:-10}" attempt=1
  while true; do
    curl -sk -o /dev/null -X PUT "${transfer_url}" -H "Authorization: Bearer ${vcfa_token}" -H "Content-Type: application/octet-stream" --data-binary @"${local_path}"
    vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}/files" ""
    transferred=$(echo ${response_body} | jq -c -r --arg n "${file_name}" '.values[] | select(.name == $n) | .bytesTransferred')
    expected=$(echo ${response_body} | jq -c -r --arg n "${file_name}" '.values[] | select(.name == $n) | .expectedSizeBytes')
    if [ -n "${transferred}" ] && [ "${transferred}" == "${expected}" ]; then
      return 0
    fi
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: upload of ${description} incomplete (${transferred:-0}/${expected} bytes transferred), attempt ${attempt}/${retry}" "${log_file}" "" ""
    if [ ${attempt} -eq ${retry} ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: giving up uploading ${description} after ${retry} attempts" "${log_file}" "${slack_webhook}" "${google_webhook}"
      return 1
    fi
    sleep "${pause}"
    ((attempt++))
  done
}
cci_api() {
  # $1 method, $2 endpoint (relative to /cci/kubernetes/), $3 data, $4 org token
  local method="$1" endpoint="$2" data="$3" org_token="$4"
  response=$(curl -sk -X "${method}" --write-out "\n%{http_code}" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${org_token}" \
    -d "${data}" "${VCFA_HOST}/cci/kubernetes/${endpoint}")
  response_body=$(sed '$ d' <<< "$response")
  response_code=$(tail -n1 <<< "$response")
  [[ ${response_code} == 2[0-9][0-9] ]]
}
# A namespace's own K8s API (used for VKS clusters etc.) lives at a
# completely different base path (namespaceEndpointURL, e.g.
# https://HOST/proxy/k8s/namespaces/{ns-urn}) than the CCI namespace/
# project API cci_api above talks to (https://HOST/cci/kubernetes/...) -
# confirmed live these are NOT nested under each other. This takes the
# full base URL directly rather than assuming any fixed prefix.
ns_k8s_api() {
  # $1 method, $2 base url (namespaceEndpointURL), $3 path (relative to base), $4 data, $5 org token
  local method="$1" base="$2" path="$3" data="$4" org_token="$5"
  response=$(curl -sk -X "${method}" --write-out "\n%{http_code}" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${org_token}" \
    -d "${data}" "${base}/${path}")
  response_body=$(sed '$ d' <<< "$response")
  response_code=$(tail -n1 <<< "$response")
  [[ ${response_code} == 2[0-9][0-9] ]]
}
# Blueprints (Aria Automation Cloud Templates) live under a COMPLETELY
# different base path (/blueprint/api/, /project-service/api/,
# /catalog/api/) than cloudapi/cci/proxy-k8s used everywhere else in
# this script - confirmed live these are real, reachable APIs on the
# same VCFA host, using the SAME org-scoped OAuth token already derived
# for namespace/VKS provisioning (no separate auth needed).
blueprint_api() {
  # $1 method, $2 path (relative to VCFA_HOST, no leading /), $3 data, $4 org token
  local method="$1" path="$2" data="$3" org_token="$4"
  response=$(curl -sk -X "${method}" --write-out "\n%{http_code}" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${org_token}" \
    -d "${data}" "${VCFA_HOST}/${path}")
  response_body=$(sed '$ d' <<< "$response")
  response_code=$(tail -n1 <<< "$response")
  [[ ${response_code} == 2[0-9][0-9] ]]
}
# The ONE read-only NSX Manager node user shared by every org (NSX Manager caps local node users - about 10 custom ones -
# so one per org does not scale to 16+ orgs, and its roles are not project-scoped anyway: every org saw the whole manager).
# Created by nsx-bootstrap.sh, handed out as a bookmark credential by gw-org-api.sh. The password has the same 20-char shape
# as every other derived password but is derived from a fixed label, not an org name, and is not generic_password.
nsx_readonly_user="student"
nsx_readonly_password() { echo "VMware1!$(echo -n "${gw_accounts_secret}nsx-readonly" | sha256sum | cut -c1-4)VMware1!"; }
# find_org_manifest <folder> <kind> <metadata.name> - prints the path of the first single-document *.yaml file in
# <folder> (not recursive) whose Kind and metadata.name match, so callers find a manifest by content and not by file
# name. The folder can be owned by another user, hence sudo. Returns 1 if there is none.
find_org_manifest() {
  local f
  for f in $(sudo find "$1" -maxdepth 1 -name '*.yaml' | sort); do
    [ "$(sudo yq 'document_index' "$f" | tail -1)" == "0" ] || continue
    if [ "$(sudo yq ".kind == \"$2\" and .metadata.name == \"$3\"" "$f")" == "true" ]; then
      echo "$f"; return 0
    fi
  done
  return 1
}

# Directory that holds one org's rendered files (demo yamls, gitops manifests, .kube): the org's own gw home (/home/<org>) when
# gw-accounts.sh has created the account (both use cases), /home/ubuntu/<org> otherwise (an sddc gw built without
# gw_accounts_secret).
org_home_dir() { # org
  if id "${1}" >/dev/null 2>&1; then
    echo "/home/${1}"
  else
    echo "/home/ubuntu/${1}"
  fi
}

# chown a path (recursively) to the org's own gw account when it exists (vApp use case: gw-accounts.sh creates one per org);
# otherwise to ubuntu - the sddc use case has no per-org accounts, and "chown <org>:<org>" would print "invalid user".
chown_org_or_ubuntu() { # org path...
  local org="$1"; shift
  if id "${org}" >/dev/null 2>&1; then
    sudo chown -R "${org}:${org}" "$@"
  else
    sudo chown -R ubuntu:ubuntu "$@"
  fi
}

#
# Fail fast when gw_accounts_secret is missing. Every per-org password (gw Linux accounts, vCenter SSO, Avi tenant admin,
# VCF-A org admin, Gitea, Argo CD, and the shared NSX read-only user) is "VMware1!<4 hex of sha256(gw_accounts_secret + name)>
# VMware1!", and this repo is public: with no secret those passwords can be computed by anyone from the org name. The vApp CRD
# makes the secret required; on the SDDC side bash/variables.sh reads it with `jq -r`, which prints the TEXT "null" (not an
# empty string) when the spec has no such key - so both "" and "null" are rejected. Runs when functions.sh is sourced, i.e.
# at the top of every phase, so a missing secret stops the pipeline before anything is created.
#
case "${gw_accounts_secret:-}" in
  ""|null)
    log_notify "ERROR: gw_accounts_secret is empty or \"null\" (not set in the deployment spec). Every per-org password is derived from it and would be guessable from the public scripts. Add gw_accounts_secret to the spec and re-run."
    exit 1
    ;;
esac

# Same Avi SE for everything of an org. Every Avi service engine (SE) needs one vNIC per org network it serves (9 data vNICs per SE), and Avi
# may place the VSes of one org on different SEs (the VKS control-plane VIP, made by the Supervisor, and the VSes AKO makes for the org's
# Gateways), so that org takes a vNIC on each. avi_colocate_org_vs <org> <vks cluster name> moves the VSes AKO made in the org's Avi tenant
# (marker "clustername") onto the SE that serves the cluster's control-plane VIP (marker GatewayName = the cluster's name):
# POST api/virtualservice/<uuid>/migrate. Moving one VS can move siblings that share its VIP, so it looks again after each move. Never fatal
# (a failure is logged and the caller goes on); the variable avi_colocate_vs=false turns it off. A moved VS is out for a few seconds.
_avi_org_curl() { # jar token org curl-args...
  local jar="$1" tok="$2" tenant="$3"; shift 3
  curl -sk -m 30 -b "${jar}" -H "X-CSRFToken: ${tok}" -H "Referer: https://${ip_avi}" -H "X-Avi-Version: ${avi_version:-32.1.1}" -H "X-Avi-Tenant: ${tenant}" -H 'Content-Type: application/json' "$@"
}
avi_colocate_org_vs() {
  local org="$1" vks="$2" jar tok inv full plan cp_se todo uuid name vip code pass waited
  [ "${avi_colocate_vs:-true}" == "true" ] || return 0
  [ -n "${ip_avi:-}" ] && [ -n "${org}" ] && [ -n "${vks}" ] || return 0
  jar=$(mktemp) || return 0
  curl -sk -m 20 -c "${jar}" -o /dev/null -X POST -H 'Content-Type: application/json' -d "{\"username\": \"admin\", \"password\": \"${generic_password}\"}" "https://${ip_avi}/login"
  tok=$(awk '/csrftoken/{print $7}' "${jar}")
  if [ -z "${tok}" ]; then log_only "Avi: no login, the VS placement of ${org} is not checked"; rm -f "${jar}"; return 0; fi
  for pass in 1 2 3 4 5 6; do
    # the inventory has the SE of each VS, only the VS object itself has the markers (clustername = made by AKO, GatewayName = the cluster's control-plane VIP)
    inv=$(_avi_org_curl "${jar}" "${tok}" "${org}" "https://${ip_avi}/api/virtualservice-inventory?page_size=200")
    full=$(_avi_org_curl "${jar}" "${tok}" "${org}" "https://${ip_avi}/api/virtualservice?page_size=200")
    plan=$(jq -n -c --argjson inv "${inv:-null}" --argjson full "${full:-null}" --arg v "${vks}" '
      ($inv.results // [] | map({key: .uuid, value: {se: (.runtime.vip_summary[0].service_engine[0].uuid // ""), vip: (.runtime.vip_summary[0].vip_id // "0")}}) | from_entries) as $m
      | ([($full.results // [])[] | select(any(.markers[]?; .key == "GatewayName" and (.values[0] // "") == $v)) | .uuid][0] // "") as $cp
      | (($m[$cp] // {}).se // "") as $se
      | {cp_se: $se, todo: [($full.results // [])[] | select(any(.markers[]?; .key == "clustername")) | select((($m[.uuid] // {}).se // "") != "" and (($m[.uuid] // {}).se) != $se) | [.uuid, .name, ($m[.uuid].vip)] | @tsv]}' 2> /dev/null)
    cp_se=$(echo "${plan}" | jq -r '.cp_se // empty' 2> /dev/null)
    if [ -z "${cp_se}" ]; then log_only "Avi: no control-plane VIP virtual service of ${vks} in tenant ${org}, its VS placement is not changed"; break; fi
    todo=$(echo "${plan}" | jq -r '.todo[0] // empty' 2> /dev/null)
    if [ -z "${todo}" ]; then [ "${pass}" -gt 1 ] && log_only "Avi: every virtual service AKO made for ${vks} is on the SE of its control-plane VIP (${cp_se})"; break; fi
    IFS=$'\t' read -r uuid name vip <<< "${todo}"
    code=$(_avi_org_curl "${jar}" "${tok}" "${org}" -o /dev/null -w '%{http_code}' -X POST "https://${ip_avi}/api/virtualservice/${uuid}/migrate" -d "{\"vip_id\": \"${vip}\", \"serviceengine_ref\": \"https://${ip_avi}/api/serviceengine/${cp_se}\", \"to_new_se\": false}")
    if [[ "${code}" != 2* ]]; then log_only "Avi: moving ${name} (tenant ${org}) to ${cp_se} failed (HTTP ${code}), left where it is"; break; fi
    log_only "Avi: moving ${name} (tenant ${org}) to the SE ${cp_se} of the control-plane VIP of ${vks}"
    for waited in $(seq 1 24); do
      sleep 5
      [ "$(_avi_org_curl "${jar}" "${tok}" "${org}" "https://${ip_avi}/api/virtualservice-inventory/${uuid}" | jq -r '.runtime.vip_summary[0].service_engine[0].uuid // empty' 2> /dev/null)" == "${cp_se}" ] && break
    done
  done
  rm -f "${jar}"
  return 0
}

# Org filter for the phases, set only by vcfa_org.sh (never by the pipeline): VCFA_ORG_ONLY=<org> narrows vcf_a_organizations (and
# blueprint_apps_orgs) to that one org, so a phase that loops over the orgs only touches it; VCFA_ORG_EXCLUDE=<org> removes one org
# from the lists (what a phase that rebuilds a list from all orgs must see after that org was deleted). Said loudly, once per phase.
if [ -n "${VCFA_ORG_ONLY:-}" ]; then
  vcf_a_organizations=$(echo "${vcf_a_organizations:-[]}" | jq -c --arg o "${VCFA_ORG_ONLY}" '[.[] | select(.name == $o)]')
  blueprint_apps_orgs=$(echo "${blueprint_apps_orgs:-[]}" | jq -c --arg o "${VCFA_ORG_ONLY}" '[.[] | select(. == $o)]')
  echo "NOTE: VCFA_ORG_ONLY=${VCFA_ORG_ONLY}: this phase only sees the org ${VCFA_ORG_ONLY}" >&2
elif [ -n "${VCFA_ORG_EXCLUDE:-}" ]; then
  vcf_a_organizations=$(echo "${vcf_a_organizations:-[]}" | jq -c --arg o "${VCFA_ORG_EXCLUDE}" '[.[] | select(.name != $o)]')
  blueprint_apps_orgs=$(echo "${blueprint_apps_orgs:-[]}" | jq -c --arg o "${VCFA_ORG_EXCLUDE}" '[.[] | select(. != $o)]')
  echo "NOTE: VCFA_ORG_EXCLUDE=${VCFA_ORG_EXCLUDE}: this phase does not see the org ${VCFA_ORG_EXCLUDE}" >&2
fi
