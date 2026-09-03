#!/bin/bash
# Shared library sourced by every 0N-*.sh script in this directory - NOT
# meant to be run directly. Holds everything genuinely cross-cutting:
# VCD session bootstrap, log_only/log_notify, and every *_api()/create_*_session()
# helper reused by more than one section (some, like avi_login/avi_api, only
# by two of the ten scripts - kept here anyway so there is exactly one
# definition instead of near-duplicates drifting apart over time).
#
# Split out of the original single-file vcf_bootstrap.sh so each pipeline
# stage (ESXi/SDDC build, vCenter port groups, NSX, Avi deploy/configure/
# upgrade, NSX Project/VPC, vSAN alarm silencing, Supervisor) can be
# re-run standalone against a live gw while testing, instead of only ever
# running the entire ~2000-line script end to end. Every 0N-*.sh takes the
# same single argument as the original script did:
#   bash 0N-name.sh /home/ubuntu/json/deployment.json

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

# VCD session, established up front (not just before the ESX power-cycle
# step) so log_notify below can use it too - govc has no session that can
# power-cycle a VCD-managed VM (GOVC_URL against the ESXi guest itself only
# reaches its own management API, not the layer that controls its power
# state), so this talks to VCD's REST API directly instead. Logged in once
# and reused throughout the script.
vcd_host=$(jq -r .vcd.host $jsonFile)
vcd_user=$(jq -r .vcd.user $jsonFile)
vcd_password=$(jq -r .vcd.password $jsonFile)
vcd_org=$(jq -r .vcd.org $jsonFile)
vcd_api_version=$(jq -r .vcd.apiVersion $jsonFile)
vcd_auth_token=$(curl -sk -X POST "https://${vcd_host}/cloudapi/1.0.0/sessions" \
  -H "Authorization: Basic $(printf '%s' "${vcd_user}@${vcd_org}:${vcd_password}" | base64 -w0)" \
  -H "Accept: application/json;version=${vcd_api_version}" \
  -D - -o /dev/null | tr -d '\r' | awk -F': ' 'tolower($1) == "x-vmware-vcloud-access-token" {print $2}')


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
gw_vm_href=$(vcd_find_vm_href "gw")


# log_only just echoes (already captured by the caller's stdout redirect
# into vcf_bootstrap.log); log_notify also posts to gchat AND writes the
# same message into a VCD metadata key (vcf_bootstrap_progress) on gw's own
# VM, for milestones - lets the operator/anything else with VCD API access
# poll "what's this script currently doing" directly, without needing
# someone to relay gchat messages. jq/sed build the JSON/XML bodies so
# message text is never hand-quoted into a curl argument (the same class
# of bug that broke the kickstart heredoc earlier in this project).
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
