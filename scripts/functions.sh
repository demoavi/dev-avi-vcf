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
    local record_count=$(echo "${resp}" | jq -r '.record | length')
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
  local retry=180 pause=20 attempt=1
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
  local message="$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: $1"
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
vcfa_login() {
  local creds
  creds=$(printf '%s@system:%s' "admin" "${generic_password}" | base64 -w0)
  local resp
  resp=$(curl -sk -i -X POST "${VCFA_HOST}/cloudapi/1.0.0/sessions/provider" \
    -H "$ACCEPT" -H "$CONTENT_TYPE" -H "Authorization: Basic ${creds}")
  vcfa_token=$(printf '%s' "$resp" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
  if [ -z "${vcfa_token}" ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A provider login FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"
    exit 100
  fi
}
vcfa_api() {
  # $1 method, $2 endpoint (relative to /), $3 data, $4 retries, $5 pause
  # - re-logs in once per call on a 401, since provider tokens have a
  # limited TTL and this script's total runtime (region/ipSpace/
  # providerGateway/org/vDC/networking, several with poll loops) can
  # comfortably outlast it. Result lands in response_body/response_code.
  local method="$1" endpoint="$2" data="$3" retry="${4:-2}" pause="${5:-5}" attempt=0
  while true; do
    response=$(curl -sk -X "${method}" --write-out "\n%{http_code}" \
      -H "$ACCEPT" -H "$CONTENT_TYPE" -H "Authorization: Bearer ${vcfa_token}" \
      -d "${data}" "${VCFA_HOST}/${endpoint}")
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
