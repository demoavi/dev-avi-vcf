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
# VCFA's own FQDN - a simple derived value (not a CR field), needed both
# for the Supervisor auth helper scripts rendered further down and for
# the VCFA org-provisioning section appended at the end of this script.
# Computed here (once, near the top) rather than at either point of use,
# so both sections share the exact same value with no duplication.
fqdn_vcfa="${basename_sddc}-auto-vip.${domain}"
# Nested vCenter's own FQDN - already the literal expression
# create_vcenter_api_session() below builds inline; named here too so the
# enable_supervisor_service.sh rendering further down can reuse it without
# duplicating the expression a third time.
vcsa_fqdn="${basename_sddc}-vc01.${domain}"
# VCF's own built-in first admin account - always this literal value
# (matches what create_vcenter_api_session() below already hardcodes
# inline), not a CR field.
vsphere_nested_username="administrator"

# Demo Gateway API/Ingress/workload yaml templating - ported here from
# gw-setup.sh.tpl (this project's own port target per that file's
# comments) rather than left at cloud-init time, so it can also cover
# workloads that need this environment's own Harbor (not yet up at
# cloud-init time, though the substitution below is a pure deterministic
# string rewrite that doesn't actually need Harbor already running - see
# the Deployment case). The cloned repo's yamls/ dir holds workshop demo
# manifests with placeholder hostnames/fqdns (all "*.mydomain.com"-style)
# and Docker Hub image refs; these get substituted per-Kind with real
# values derived from this deployment's own avi_subdomain/domain (and,
# for images, harbor's own hostname/registry project). Output goes to a
# fresh /home/ubuntu/yaml-files/ - every file is copied there, rendered
# or not, leaving the git-cloned originals under dev-avi-vcf/yamls/
# untouched. Rendered only, never applied to any cluster here - that's
# left to whoever actually deploys these demos. Uses mikefarah/yq
# (installed by gw-setup.sh.tpl, NOT apt's incompatible python/jq-wrapper
# "yq") for the del()/wildcard-index/path-assignment/sub() mutations
# below.
if [ -d /home/ubuntu/dev-avi-vcf/yamls ]; then
  mkdir -p /home/ubuntu/yaml-files
  full_domain="${avi_subdomain}.${domain}"
  harbor_registry_fqdn="harbor.${full_domain}"
  for yaml_src in /home/ubuntu/dev-avi-vcf/yamls/*.yaml; do
    yaml_dst="/home/ubuntu/yaml-files/$(basename "$yaml_src")"
    cp "$yaml_src" "$yaml_dst"
    # select(di == 0), not a bare '.kind' - a multi-doc file (e.g.
    # demo-http-apps.yaml's 3 Deployments + 3 Services) would otherwise
    # yield every document's kind concatenated, which never matches any
    # single case label below and always fell through to the silent no-op
    # catch-all instead.
    yaml_kind="$(yq 'select(di == 0) | .kind' "$yaml_dst")"
    case "$yaml_kind" in
      Ingress)
        # .spec.rules[i].host = "v<i+1>.<full_domain>"
        rule_count=$(yq '.spec.rules | length' "$yaml_dst")
        for ((i = 0; i < rule_count; i++)); do
          yq -i ".spec.rules[$i].host = \"v$((i + 1)).${full_domain}\"" "$yaml_dst"
        done
        ;;
      HTTPRoute)
        # .spec.hostnames = ["<metadata.name>.<full_domain>"]
        httproute_name="$(yq '.metadata.name' "$yaml_dst")"
        yq -i "del(.spec.hostnames) | .spec.hostnames[0] = \"${httproute_name}.${full_domain}\"" "$yaml_dst"
        ;;
      Gateway)
        # every listener's hostname = "*.<full_domain>"
        yq -i ".spec.listeners[].hostname = \"*.${full_domain}\"" "$yaml_dst"
        ;;
      HostRule)
        # .spec.virtualhost.fqdn = "<metadata.name>.<full_domain>"
        hostrule_name="$(yq '.metadata.name' "$yaml_dst")"
        yq -i ".spec.virtualhost.fqdn = \"${hostrule_name}.${full_domain}\"" "$yaml_dst"
        ;;
      RouteBackendExtension)
        # .spec.backendTLS.domainName[0] = "<metadata.name>.<full_domain>"
        rbe_name="$(yq '.metadata.name' "$yaml_dst")"
        yq -i ".spec.backendTLS.domainName[0] = \"${rbe_name}.${full_domain}\"" "$yaml_dst"
        ;;
      Deployment)
        # every container's (and initContainer's) image, in every
        # Deployment document in this file (not just the first - the sub()
        # below runs per-document across the whole multi-doc stream, e.g.
        # demo-http-apps.yaml's other two Deployments and its interleaved
        # Service docs, where it's a safe no-op since Services have no
        # .spec.template.spec.containers path at all) - registry host
        # swapped for this environment's own Harbor, image name/tag kept
        # as-is (untagged stays untagged, i.e. still implicitly ":latest"
        # by Docker convention, matching how the harbor image-preload step
        # above always pushes as ":latest"). Confirmed live this correctly
        # leaves the 3 Service docs in demo-http-apps.yaml untouched while
        # rewriting all 3 Deployments' images.
        yq -i '(.. | select(has("containers")) | .containers[], .. | select(has("initContainers")) | .initContainers[] | select(.image != null)).image |= sub("^.*/", "'"${harbor_registry_fqdn}"'/registry/")' "$yaml_dst"
        ;;
      *)
        # HealthMonitor, L7Rule, Service (incl. the LB demos) - no changes.
        ;;
    esac
  done
  chown -R ubuntu:ubuntu /home/ubuntu/yaml-files
fi

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
#
#
echo '------------------------------------------------------------'
echo "Cloud Builder JSON file creation"

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

hostSpecs="[]"
for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
do
  group=$(( (esxi-1)/4 ))
  if [[ ${group} -eq 0 ]] ; then
    name_esxi="${basename_sddc}-mgmt-esx0${esxi}"
  else
    pos_in_group=$(( esxi - group*4 ))
    name_esxi="${basename_sddc}-wld0${group}-esx0${pos_in_group}"
  fi
  ip_esxi="$(echo ${ips_esxi} | jq -r .[$(expr ${esxi} - 1)])"

  if ! vcd_wait_vm_powered_on "${name_esxi}"; then
    echo "ERROR: ${name_esxi} never reached POWERED_ON in VCD, skipping this host"
    continue
  fi

  count=1
  until $(curl --output /dev/null --silent --head -k https://${ip_esxi})
  do
    echo "Attempt ${count}: Waiting for ESXi host at https://${ip_esxi} to be reachable..."
    sleep 10
    count=$((count+1))
    if [[ "${count}" -eq 90 ]]; then
      echo "ERROR: Unable to connect to ESXi host at https://${ip_esxi}, skipping this host"
      continue 2
    fi
  done
  sleep 60
  esxi_sslThumbprint=$(echo | openssl s_client -servername ${ip_esxi} -connect ${ip_esxi}:443 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | awk -F'Fingerprint=' '{print $2}')
  hostSpec='{"hostname":"'${name_esxi}'","credentials":{"username":"root","password":"'$(jq -c -r .generic_password $jsonFile)'"},"sslThumbprint":"'${esxi_sslThumbprint}'"}'
  hostSpecs=$(echo ${hostSpecs} | jq '. += ['${hostSpec}']')

  #
  # Power-cycle this host via VCD now that we know it's genuinely up
  # (thumbprint just captured above) - a clean reboot after the kickstart
  # install, same as the original vCenter-based flow's govc vm.power
  # cycle, just against VCD instead of govc.
  #
  vm_href=$(vcd_find_vm_href "${name_esxi}")
  curl -sk -X POST "${vm_href}/power/action/powerOff" \
    -H "Authorization: Bearer ${vcd_auth_token}" \
    -H "Accept: application/*+xml;version=${vcd_api_version}" > /dev/null
  sleep 30
  curl -sk -X POST "${vm_href}/power/action/powerOn" \
    -H "Authorization: Bearer ${vcd_auth_token}" \
    -H "Accept: application/*+xml;version=${vcd_api_version}" > /dev/null

  count=1
  until $(curl --output /dev/null --silent --head -k https://${ip_esxi})
  do
    echo "Attempt ${count}: Waiting for ESXi host at https://${ip_esxi} to be reachable after power cycle..."
    sleep 10
    count=$((count+1))
    if [[ "${count}" -eq 60 ]]; then
      # hostSpec for this host was already appended to hostSpecs above -
      # a single stuck host here shouldn't abort the whole SDDC bootstrap,
      # so skip its remaining customization below rather than exiting.
      echo "ERROR: Unable to connect to ESXi host at https://${ip_esxi} after power cycle, skipping this host"
      continue 2
    fi
  done
  sleep 20

  #
  # ESXi customization (merged from esxi_customization.sh.template) - govc
  # here talks directly to the ESXi host's own management API, not VCD.
  #
  export GOVC_URL="${ip_esxi}"
  export GOVC_USERNAME=root
  export GOVC_PASSWORD=$(jq -c -r .generic_password $jsonFile)
  export GOVC_INSECURE=true
  export GOVC_PERSIST_SESSION=false
  export GOVC_DEBUG=true
  # hostd's own management API can still be initializing for a while after
  # the HTTPS port itself starts accepting connections (the wait-loop
  # above only checks the port) - a 503 here right after a kickstart
  # reboot is expected, not a real failure, so retry a few times before
  # giving up.
  retry_storage_rescan=6 ; pause_storage_rescan=20 ; attempt_storage_rescan=0 ; rescan_ok=false
  while true ; do
    storage_info=$(govc host.storage.info -json -rescan 2>&1)
    if [ $? -eq 0 ]; then
      rescan_ok=true
      break
    fi
    ((attempt_storage_rescan++))
    if [ ${attempt_storage_rescan} -eq ${retry_storage_rescan} ]; then
      log_notify "ERROR: govc host.storage.info -rescan failed for ${name_esxi} after ${attempt_storage_rescan} attempts: ${storage_info}"
      break
    fi
    sleep ${pause_storage_rescan}
  done
  if [ "${rescan_ok}" = true ]; then
    marked=0
    while read -r disk_device
    do
      [ -z "${disk_device}" ] && continue
      mark_error=$(govc host.storage.mark -ssd "${disk_device}" 2>&1)
      if [ $? -ne 0 ]; then
        log_notify "ERROR: govc host.storage.mark -ssd ${disk_device} failed for ${name_esxi}: ${mark_error}"
      else
        ((marked++))
      fi
    done <<< "$(echo "${storage_info}" | jq -c -r '.storageDeviceInfo.scsiLun[] | select( .deviceType == "disk" ) | .deviceName')"
    log_notify "nested ESXi ${name_esxi}: ${marked} disk(s) marked as SSD"
  fi
done
#
#
#
nsxtManagers="[]"
for nsx_count in $(seq 2 $(echo ${ips_nsx} | jq -c -r '. | length'))
do
  nsxtManager='{"hostname":"'${basename_sddc}''${basename_nsx_manager}''${nsx_count}'","ip":"'$(echo ${ips_nsx} | jq -c -r '.['$((nsx_count - 1))']')'"}'
  nsxtManagers=$(echo ${nsxtManagers} | jq '. += ['${nsxtManager}']')
done
#
#
#
json_template_file="${templates_dir}/sddc_vcf_installer_trunk_9.1.json.template"
sed -e "s/\${basename_sddc}/${basename_sddc}/" \
    -e "s/\${SDDC_MANAGER_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
    -e "s/\${VCFA_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
    -e "s/\${VCF_VSP_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
    -e "s/\${ip_vcf_vsp_start}/${ip_vcf_vsp_start}/" \
    -e "s/\${ip_vcf_vsp_end}/${ip_vcf_vsp_end}/" \
    -e "s/\${pool_ip_vcf_auto}/$(echo ${pool_ip_vcf_auto} | jq -c -r .)/" \
    -e "s/\${vcf_automation_node_prefix}/${vcf_automation_node_prefix}/" \
    -e "s/\${vcf_version_full}/${vcf_version_full}/" \
    -e "s/\${domain}/${domain}/" \
    -e "s/\${hostSpecs}/$(echo ${hostSpecs} | jq -c -r .)/" \
    -e "s/\${VCFO_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
    -e "s/\${ip_gw}/${ip_gw}/" \
    -e "s/\${ip_gw_direct}/${ip_gw_direct}/" \
    -e "s/\${VCS_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
    -e "s/\${ssoDomain}/$(jq -c -r .sddc.vcenter.ssoDomain ${jsonFile})/" \
    -e "s/\${nsxtManagerSize}/$(jq -c -r .sddc.nsx.size ${jsonFile})/" \
    -e "s/\${NSX_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
    -e "s/\${nsx_pool_range_start}/${nsx_pool_range_start}/" \
    -e "s/\${nsx_pool_range_end}/${nsx_pool_range_end}/" \
    -e "s@\${nsx_subnet_cidr}@$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
    -e "s/\${nsx_subnet_gw}/$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
    -e "s/\${vlan_id_host_overlay}/$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
    -e "s/\${basename_nsx_manager}/${basename_nsx_manager}/" \
    -e "s/\${gw_mgmt}/$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
    -e "s/\${vlan_id_mgmt}/$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
    -e "s@\${cidr_mgmt}@$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
    -e "s@\${cidr_vm_mgmt}@$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
    -e "s/\${gw_vm_mgmt}/$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
    -e "s/\${vlan_id_vm_mgmt}/$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
    -e "s@\${cidr_vmotion}@$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
    -e "s/\${gw_vmotion}/$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
    -e "s/\${vlan_id_vmotion}/$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
    -e "s/\${ending_ip_vmotion}/${ending_ip_vmotion}/" \
    -e "s/\${starting_ip_vmotion}/${starting_ip_vmotion}/" \
    -e "s@\${cidr_vsan}@$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
    -e "s/\${gw_vsan}/$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
    -e "s/\${vlan_id_vsan}/$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
    -e "s/\${ending_ip_vsan}/${ending_ip_vsan}/" \
    -e "s/\${starting_ip_vsan}/${starting_ip_vsan}/" ${json_template_file} | tee /home/ubuntu/json/${basename_sddc}.json > /dev/null
#
#
#
template_html_file="${templates_dir}/index-vcfi.html.template"
sed -e "s/\${basename_sddc}/${basename_sddc}/" \
    -e "s/\${name_vcf_installer}/${name_vcf_installer}/" \
    -e "s/\${basename_avi_ctrl}/${basename_avi_ctrl}/" \
    -e "s/\${domain}/${domain}/" ${template_html_file} | tee /home/ubuntu/html/index.html > /dev/null
sed -e "s@\${ip_gw_direct}@${ip_gw_direct}@" "${templates_dir}/socks.html.template" | tee /home/ubuntu/html/socks.html > /dev/null
sudo mv /home/ubuntu/html/index.html /var/www/html/index.html
sudo mv /home/ubuntu/html/socks.html /var/www/html/socks.html
sudo chown root /var/www/html/index.html
sudo chgrp root /var/www/html/index.html
sudo chown root /var/www/html/socks.html
sudo chgrp root /var/www/html/socks.html
sudo cat /var/lib/bind/db.${domain} | grep avi | sudo tee /var/www/html/avi_raw.html
while read -r line; do echo "${line}<br>"; done < /var/www/html/avi_raw.html | sudo tee /var/www/html/avi.html
sudo cat /var/lib/bind/db.${domain} | grep wld | sudo tee /var/www/html/esxi_raw.html
while read -r line; do echo "${line}<br>"; done < /var/www/html/esxi_raw.html | sudo tee /var/www/html/esxi.html
sudo cp /home/ubuntu/json/${basename_sddc}.json /var/www/html/${basename_sddc}.json
sudo chown root /var/www/html/${basename_sddc}.json
sudo chgrp root /var/www/html/${basename_sddc}.json
log_notify "deployment JSON ready, details available at http://${ip_gw_direct}/"
#
#
#
# VCF Installer configuration (merged from vcf-installer/vcfi.sh) -
# exchanges the license-service credentials for an activation code, waits
# for the install bundles to download, then submits/validates/builds the
# SDDC. Only the VCF 9.1 path is kept - see the earlier json_builder.sh
# simplification for why the 9.0/Cloud Builder branches were dropped.
# create_api_session/sddc_manager_api are defined up top with the other
# helpers.
#
count=1
until $(curl --output /dev/null --silent --head -k https://${ip_vcf_installer})
do
  echo "Attempt ${count}: Waiting for VCF Installer at https://${ip_vcf_installer} to be reachable..."
  sleep 10
  count=$((count+1))
  if [[ "${count}" -eq 60 ]]; then
    log_notify "ERROR: Unable to connect to VCF Installer at https://${ip_vcf_installer}"
    exit 100
  fi
done

#
# Patch the VCF Installer appliance's lcm/domainmanager config before
# driving its API - doing this after we've already started using the API
# would mean the service restarts below interrupt in-flight calls.
# Confirmed empirically: the "vcf" account's sudo access is restricted to a
# single support-bundle command (`sudo -l` only allows
# /opt/vmware/sddc-support/sos) - real root access is via `su -` with the
# root password (= generic_password, same convention as ROOT_PASSWORD in
# build_vcf_installer_ovf_properties() in userdata.py), and `su` refuses to
# run without a real controlling terminal ("must be run from a terminal"),
# so a plain ssh+heredoc can't drive its password prompt - this needs
# expect (already in variables.json's apt_packages) instead.
#
export VCF_ROOT_PASSWORD="$(jq -c -r .generic_password $jsonFile)"
export VCF_INSTALLER_IP="${ip_vcf_installer}"

# Points lcm/domainmanager at the staging depot+license-service
# infrastructure instead of production defaults - built here (real bash
# variables, no escaping needed) and relayed through the ssh/expect layers
# as base64, since the domainmanager line is a JSON blob full of double
# quotes that would otherwise have to survive bash heredoc -> Tcl string ->
# remote-shell quoting all at once (the same class of problem jq -n --arg
# already solves for the gchat messages above).
lcm_patch_b64=$(printf '%s\n%s\n%s\n%s\n' \
  "lcm.depot.adapter.host=${lcm_depot_host}" \
  "lcm.depot.adapter.remote.vcfMetadataDir=${lcm_depot_metadata_dir}" \
  "lcm.depot.adapter.vCenterUpgradeInfoDir=${lcm_depot_vcenter_upgrade_info_dir}" \
  "lcm.access_token.broadcom.authorization.server.url=${vcf_installer_bearer_url}" \
  | base64 -w0)
dm_override_json=$(printf '{"publicDepotHost":"%s","authorizationServer":"%s","publicVvsHost":"%s","publicVvsVcfLcmBundlePath":"%s","publicVvsVcfInteropBundlePath":"%s","publicVvsVlcmInteropVcgBundlePath":"%s","publicVsanHclHost":"%s","publicPackagesHost":"%s"}' \
  "${lcm_depot_host}" "${vcf_installer_bearer_url}" "${vvs_host}" "${vvs_lcm_bundle_path}" "${vvs_interop_bundle_path}" "${vvs_vlcm_interop_vcg_bundle_path}" "${vsan_hcl_host}" "${packages_host}")
dm_patch_b64=$(printf 'lcm.depot.service.online.config.override=%s\n' "${dm_override_json}" | base64 -w0)
export VCF_LCM_PATCH_B64="${lcm_patch_b64}"
export VCF_DM_PATCH_B64="${dm_patch_b64}"

# The staging depot host/URLs above only take effect once these production
# defaults are cleared out of the way (Spring's "last value wins" loading
# doesn't help here - remote.v2.rootDir/port have no staging equivalent at
# all, so leaving them active conflicts with the appended settings rather
# than being harmlessly superseded) and cert checking is disabled (the
# staging depot doesn't present a cert the default enableCertCheck=true
# would accept). Confirmed by diffing a real patched appliance against its
# own pre-patch backup. Static/structural, not deployment-specific, so
# hardcoded here rather than templated through env_vars like the values
# above.
lcm_sed_fix_b64=$(base64 -w0 <<'SED_FIX_EOF'
sed -i '/^lcm\.depot\.adapter\.host=dl\.broadcom\.com$/d;/^lcm\.depot\.adapter\.port=443$/d;/^lcm\.depot\.adapter\.remote\.v2\.rootDir=\/PROD$/d' /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties
sed -i 's/^lcm\.depot\.adapter\.certificateCheckEnabled=true$/lcm.depot.adapter.certificateCheckEnabled=false/' /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties
SED_FIX_EOF
)
export VCF_LCM_SED_FIX_B64="${lcm_sed_fix_b64}"

expect <<'VCFI_EXPECT_EOF'
set timeout 30
set password $env(VCF_ROOT_PASSWORD)
spawn ssh -tt -o StrictHostKeyChecking=no vcf@$env(VCF_INSTALLER_IP)
expect "*assword:" { send "$password\r" }
expect "*$ " { send "su -\r" }
expect "*assword:" { send "$password\r" }
expect "*# " { send "cp /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties.bck\r" }
expect "*# " { send "cp /etc/vmware/vcf/domainmanager/application-prod.properties /etc/vmware/vcf/domainmanager/application-prod.properties.bck\r" }
expect "*# " { send "echo $env(VCF_LCM_SED_FIX_B64) | base64 -d | bash\r" }
expect "*# " { send "echo $env(VCF_LCM_PATCH_B64) | base64 -d | tee -a /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties > /dev/null\r" }
expect "*# " { send "echo $env(VCF_DM_PATCH_B64) | base64 -d | tee -a /etc/vmware/vcf/domainmanager/application-prod.properties > /dev/null\r" }
expect "*# " {
  # Confirmed empirically on a real appliance: these two files can end up
  # owned by root (breaking the service accounts' own read access,
  # "syslog.facility_IS_UNDEFINED"/"Permission denied" on restart) even
  # though nothing here should change ownership of an already-existing
  # file - restoring the correct owner defensively either way costs
  # nothing and makes this self-healing regardless of root cause.
  send "chown vcf_lcm:vcf /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties\r"
}
expect "*# " { send "chown vcf_domainmanager:vcf /etc/vmware/vcf/domainmanager/application-prod.properties\r" }
expect "*# " {
  send "systemctl restart lcm.service\r"
}
expect "*# " { send "systemctl restart domainmanager\r" }
expect "*# " { send "exit\r" }
expect "*$ " { send "exit\r" }
expect eof
VCFI_EXPECT_EOF
unset VCF_ROOT_PASSWORD VCF_LCM_PATCH_B64 VCF_DM_PATCH_B64 VCF_LCM_SED_FIX_B64
log_notify "VCF-I: patched and restarted lcm/domainmanager services"

# The reverse proxy in front of lcm/domainmanager comes back up almost
# immediately, but the Java services themselves take real time to
# reinitialize - hitting the API too soon gets a 502 Bad Gateway (confirmed
# empirically). Same reachability-wait pattern as the ESXi hosts above.
sleep 60
count=1
until $(curl --output /dev/null --silent --head -k https://${ip_vcf_installer})
do
  echo "Attempt ${count}: Waiting for VCF Installer at https://${ip_vcf_installer} to be reachable after service restart..."
  sleep 10
  count=$((count+1))
  if [[ "${count}" -eq 60 ]]; then
    log_notify "ERROR: VCF Installer at https://${ip_vcf_installer} not reachable after service restart"
    exit 100
  fi
done

log_notify "Create VCF Installer API session"
create_api_session "admin@local" "$(jq -c -r .generic_password $jsonFile)" "${ip_vcf_installer}" /tmp/token_vcfi.json

sddc_manager_api 3 2 GET '' "${ip_vcf_installer}" v1/system/settings/depot/machine-details $(jq -c -r .accessToken /tmp/token_vcfi.json)
vcfi_machineId=$(echo ${response_body} | jq -c -r '.machineId')
if [ -z "${vcfi_machineId}" ] || [ "${vcfi_machineId}" == "null" ]; then
  log_notify "VCF-I: vcfi_machineId is undefined or null - response: ${response_body}"
  exit 100
fi
#
# The license/entitlement service (${vcf_installer_bearer_url} /
# ${vcf_installer_token_url}) can only be reached from Broadcom's internal
# network, not from gw - but the operator CAN reach it (and already holds
# the same VCD credentials gw uses for the ESXi power-cycle step above), so
# the exchange is relayed through VCD VM metadata on gw's own VM: gw writes
# vcfi_machineId here, the operator's relay_vcf_installer_activation()
# timer picks it up, does the exchange, and writes vcfi_activation_code
# back the same way. gw_vm_href was already resolved up top (log_notify
# needs it too).
#
curl -sk -X POST "${gw_vm_href}/metadata" \
  -H "Authorization: Bearer ${vcd_auth_token}" \
  -H "Accept: application/*+xml;version=${vcd_api_version}" \
  -H "Content-Type: application/vnd.vmware.vcloud.metadata+xml" \
  --data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Metadata xmlns=\"http://www.vmware.com/vcloud/v1.5\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><MetadataEntry><Key>vcfi_machineId</Key><TypedValue xsi:type=\"MetadataStringValue\"><Value>${vcfi_machineId}</Value></TypedValue></MetadataEntry></Metadata>" > /dev/null

log_notify "VCF-I: posted machineId to VCD metadata, waiting for the operator to relay the activation code"
retry_activation=60 ; pause_activation=30 ; attempt_activation=1
while true; do
  # Confirm the machineId write actually landed - a single unretried POST
  # can be silently dropped by VCD's optimistic-locking on concurrent VM
  # metadata writes (seen empirically: "Row was updated or deleted by
  # another transaction"), which would otherwise strand this loop for the
  # full retry budget waiting on an activation code the operator has
  # nothing to relay. Re-post it here (folded into the existing poll
  # interval, no extra delay) if it's ever missing.
  posted_machine_id=$(curl -sk "${gw_vm_href}/metadata/vcfi_machineId" \
    -H "Authorization: Bearer ${vcd_auth_token}" \
    -H "Accept: application/*+xml;version=${vcd_api_version}" \
    | grep -oP '(?<=<Value>).*?(?=</Value>)')
  if [ -z "${posted_machine_id}" ]; then
    log_only "VCF-I: vcfi_machineId missing from VCD metadata, re-posting"
    curl -sk -X POST "${gw_vm_href}/metadata" \
      -H "Authorization: Bearer ${vcd_auth_token}" \
      -H "Accept: application/*+xml;version=${vcd_api_version}" \
      -H "Content-Type: application/vnd.vmware.vcloud.metadata+xml" \
      --data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Metadata xmlns=\"http://www.vmware.com/vcloud/v1.5\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><MetadataEntry><Key>vcfi_machineId</Key><TypedValue xsi:type=\"MetadataStringValue\"><Value>${vcfi_machineId}</Value></TypedValue></MetadataEntry></Metadata>" > /dev/null
  fi
  vcfi_activation_code=$(curl -sk "${gw_vm_href}/metadata/vcfi_activation_code" \
    -H "Authorization: Bearer ${vcd_auth_token}" \
    -H "Accept: application/*+xml;version=${vcd_api_version}" \
    | grep -oP '(?<=<Value>).*?(?=</Value>)')
  if [ -n "${vcfi_activation_code}" ]; then
    log_notify "VCF-I: received activation code via VCD metadata relay"
    break
  fi
  if [ ${attempt_activation} -eq ${retry_activation} ]; then
    log_notify "VCF-I: activation code not relayed after ${attempt_activation} attempts of ${pause_activation} seconds"
    exit 100
  fi
  sleep ${pause_activation}
  ((attempt_activation++))
done
sddc_manager_api 3 2 PUT '{"vmwareAccount" : {"downloadActivationCode" : "'${vcfi_activation_code}'"}}' "${ip_vcf_installer}" v1/system/settings/depot $(jq -c -r .accessToken /tmp/token_vcfi.json)

#
# check that the depot bundle has been populated
#
retry_bundle=60 ; pause_bundle=10 ; attempt_bundle=1
while true
do
  sddc_manager_api 3 2 GET '' "${ip_vcf_installer}" v1/bundles $(jq -c -r .accessToken /tmp/token_vcfi.json)
  bundles_count=$(echo ${response_body} | jq -c -r '.elements | length')
  if [[ ${bundles_count} -gt 0 ]] ; then
    log_notify "VCF-I: bundles are populated"
    sleep 30
    break
  fi
  if [ ${attempt_bundle} -eq ${retry_bundle} ]; then
    log_notify "VCF-I: Bundles are not populated after ${attempt_bundle} attempts of ${pause_bundle} seconds"
    exit 100
  fi
  sleep ${pause_bundle}
  ((attempt_bundle++))
done

# The machineId/activation code relayed through VCD VM metadata have done
# their job - clear them now rather than leaving an activation secret
# sitting on the VM indefinitely.
curl -sk -X DELETE "${gw_vm_href}/metadata/vcfi_machineId" \
  -H "Authorization: Bearer ${vcd_auth_token}" \
  -H "Accept: application/*+xml;version=${vcd_api_version}" > /dev/null
curl -sk -X DELETE "${gw_vm_href}/metadata/vcfi_activation_code" \
  -H "Authorization: Bearer ${vcd_auth_token}" \
  -H "Accept: application/*+xml;version=${vcd_api_version}" > /dev/null
log_only "VCF-I: cleared machineId/activation code from VCD metadata"

sddc_manager_api 3 2 GET '' "${ip_vcf_installer}" v1/bundles $(jq -c -r .accessToken /tmp/token_vcfi.json)
depots_ids=$(echo ${response_body} | jq --arg arg "${vcf_version}" '[.elements[] | select ((.components[0].imageType == "INSTALL") and (.version | startswith($arg))) | .id]')
depots_to_download=$(echo ${response_body} | jq --arg arg "${vcf_version}" '[.elements[] | select ((.components[0].imageType == "INSTALL") and (.version | startswith($arg))) | .id ] | length')
echo ${depots_ids} | jq -c -r .[] | while read depot_id
do
  sddc_manager_api 3 2 PATCH '{"bundleDownloadSpec":{"downloadNow":true}}' "${ip_vcf_installer}" v1/bundles/${depot_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
  log_only "VCF-I: patching bundle ${depot_id} to download it"
done
log_only "VCF-I: waiting 600 seconds for bundle download to start"
sleep 600

#
# download bundles
#
retry_download=60 ; pause_download=20 ; attempt_download=1
while true
do
  sddc_manager_api 3 2 GET '' "${ip_vcf_installer}" v1/bundles $(jq -c -r .accessToken /tmp/token_vcfi.json)
  depot_downloaded=$(echo ${response_body} | jq --arg arg "${vcf_version}" '[.elements[] | select ((.components[0].imageType == "INSTALL") and (.downloadStatus == "SUCCESSFUL") and (.version | startswith($arg))) ] | length')
  if [[ ${depot_downloaded} == ${depots_to_download} ]]; then
    log_notify "VCF-I: all bundles downloaded"
    break
  else
    log_only "${depot_downloaded} on ${depots_to_download} bundles have been downloaded"
  fi
  if [ ${attempt_download} -eq ${retry_download} ]; then
    log_notify "VCF-I: Bundles are not downloaded after ${attempt_download} attempts of ${pause_download} seconds"
    exit 100
  fi
  sleep ${pause_download}
  ((attempt_download++))
done

#
# validation json
#
sddc_manager_api 3 2 POST "@/home/ubuntu/json/${basename_sddc}.json" "${ip_vcf_installer}" v1/sddcs/validations $(jq -c -r .accessToken /tmp/token_vcfi.json)
sddc_validation_id=$(echo ${response_body} | jq -c -r .id)
if [ -z "${sddc_validation_id}" ] || [ "${sddc_validation_id}" == "null" ]; then
  log_notify "VCF-I: sddc_validation_id is undefined or null"
  exit 100
fi
log_notify "VCF-I: sddc_validation_id: ${sddc_validation_id}"
log_only "VCF-I: waiting 300 seconds"
sleep 300
retry_validation=60 ; pause_validation=10 ; attempt_validation=1
while true ; do
  log_only "attempt ${attempt_validation} to verify SDDC JSON validation"
  sddc_manager_api 3 2 GET "" "${ip_vcf_installer}" v1/sddcs/validations/${sddc_validation_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
  executionStatus=$(echo ${response_body} | jq -c -r .executionStatus)
  if [[ ${executionStatus} == "COMPLETED" ]]; then
    sddc_manager_api 3 2 GET "" "${ip_vcf_installer}" v1/sddcs/validations/${sddc_validation_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
    resultStatus=$(echo ${response_body} | jq -c -r .resultStatus)
    log_notify "VCF-I: SDDC JSON validation finished, result: ${resultStatus} after ${attempt_validation} attempt of ${pause_validation} seconds"
    if [[ ${resultStatus} != "SUCCEEDED" ]] ; then
      echo ${response_body} | jq -c -r '[.validationChecks[] | select( .resultStatus != "SUCCEEDED").errorResponse.nestedErrors.[].message]' | jq -c -r .[] | while read item
      do
        log_notify "VCF-I: SDDC JSON validation item not SUCCEEDED - ${item}"
      done
      log_notify "VCF-I: v9.1 - ignoring the validation error and proceeding"
    fi
    break
  fi
  sleep ${pause_validation}
  ((attempt_validation++))
  if [ ${attempt_validation} -eq ${retry_validation} ]; then
    log_notify "VCF-I: SDDC JSON validation not finished after ${attempt_validation} attempts of ${pause_validation} seconds, last executionStatus: ${executionStatus}"
    log_only "VCF-I: last validation response: ${response_body}"
    echo ${response_body} | jq -c -r '[.validationChecks[]? | select( .resultStatus != "SUCCEEDED").errorResponse.nestedErrors[]?.message]' 2>/dev/null | jq -c -r '.[]?' 2>/dev/null | while read item
    do
      log_notify "VCF-I: SDDC JSON validation item not SUCCEEDED - ${item}"
    done
    exit 100
  fi
done

#
# sddc build
#
sddc_manager_api 3 2 POST "@/home/ubuntu/json/${basename_sddc}.json" "${ip_vcf_installer}" v1/sddcs $(jq -c -r .accessToken /tmp/token_vcfi.json)
sddc_id=$(echo ${response_body} | jq -c -r .id)
log_notify "VCF-I: starting building sddc id ${sddc_id}"
retry_build=180 ; pause_build=300 ; attempt_build=1 ; count_retry=1
while true ; do
  create_api_session "admin@local" "$(jq -c -r .generic_password $jsonFile)" "${ip_vcf_installer}" /tmp/token_vcfi.json
  log_only "attempt ${attempt_build} to verify SDDC ${sddc_id} creation"
  sddc_manager_api 3 2 GET "" "${ip_vcf_installer}" v1/sddcs/${sddc_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
  sddc_status=$(echo ${response_body} | jq -c -r .status)
  if [[ ${sddc_status} != "IN_PROGRESS" ]]; then
    log_notify "SDDC ${sddc_id} creation status: ${sddc_status} after attempt ${attempt_build}, go to https://${ip_vcf_installer}"
    if [[ ${sddc_status} != "COMPLETED_WITH_SUCCESS" ]]; then
      ((count_retry++))
      if [[ ${count_retry} == 3 ]]; then
        log_notify "SDDC ${sddc_id} creation status: ${sddc_status}, go to https://${ip_vcf_installer} - giving up"
        log_only "SDDC ${sddc_id} last status response: ${response_body}"
        echo ${response_body} | jq -c -r '[.. | objects | select(has("message") or has("errorCode")) | {message, errorCode}]' 2>/dev/null | jq -c -r '.[]?' 2>/dev/null | while read item
        do
          log_notify "SDDC ${sddc_id} error detail - ${item}"
        done
        exit 100
      fi
      sleep 600
      log_only "SDDC ${sddc_id} trying ${count_retry} times to apply after status ${sddc_status}"
      sddc_manager_api 3 2 PATCH "" "${ip_vcf_installer}" v1/sddcs/${sddc_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
    fi
    if [[ ${sddc_status} == "COMPLETED_WITH_SUCCESS" ]]; then
      log_notify "SDDC ${sddc_id} creation status: ${sddc_status}, go to https://${ip_vcf_installer}"
      break
    fi
  else
    sleep ${pause_build}
  fi
  ((attempt_build++))
  if [ ${attempt_build} -eq ${retry_build} ]; then
    log_notify "SDDC ${sddc_id} creation status: ${sddc_status}, go to https://${ip_vcf_installer} - giving up after ${attempt_build} attempts"
    log_only "SDDC ${sddc_id} last status response: ${response_body}"
    exit 100
  fi
done

#
# port groups (merged from the reference project's vcenter/vcsa.sh - content
# library creation/OVA upload deliberately dropped, same as the earlier
# Cloud Builder/9.0 branches: VCF 9.1-only scope, so the EDGE_OVERLAY
# portgroup that reference script only creates for 9.0/8.0U3b is skipped
# too. govc here talks to the newly-built nested vCenter, not an ESXi host
# directly - GOVC_CLUSTER is unset since portgroups sit on the vDS itself,
# independent of any specific cluster. Folded back in here (rather than
# staying its own 0N-*.sh) once confirmed working against a live build -
# no reason to make this one a separate manual step.
#
export GOVC_URL="${basename_sddc}-vc01.${domain}"
export GOVC_USERNAME="administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)"
export GOVC_PASSWORD="${generic_password}"
export GOVC_DATACENTER="${basename_sddc}-dc"
export GOVC_INSECURE=true
export GOVC_PERSIST_SESSION=false
unset GOVC_CLUSTER
vds_name="${basename_sddc}-vds-01"

external_vlan_id=$(jq -c -r --arg arg "EXTERNAL" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)
pg_error=$(govc dvs.portgroup.add -dvs "${vds_name}" -vlan "${external_vlan_id}" "${basename_sddc}-pg-external" 2>&1)
if [ $? -ne 0 ]; then
  log_notify "ERROR: govc dvs.portgroup.add ${basename_sddc}-pg-external failed: ${pg_error}"
else
  log_notify "portgroup ${basename_sddc}-pg-external created (vlan ${external_vlan_id})"
fi

pg_error=$(govc dvs.portgroup.add -dvs "${vds_name}" -vlan-mode=trunking "${basename_sddc}-edge-uplink1" 2>&1)
if [ $? -ne 0 ]; then
  log_notify "ERROR: govc dvs.portgroup.add ${basename_sddc}-edge-uplink1 failed: ${pg_error}"
else
  log_notify "portgroup ${basename_sddc}-edge-uplink1 created (trunking)"
fi

#
# NSX Manager configuration (merged from the reference project's
# nsx/configure_nsx.sh) - 9.0/8.0U3b-only branches dropped (VCF 9.1-only
# scope, same as elsewhere in this script), including its ip-pool-creation
# section, since 9.1 uses VCF's own pre-created "teppool" TEP IP pool
# (ip_pool_name_9_1) instead of creating one here. The reference project's
# 4 separate REST helper scripts + on-disk cookie/header/response files are
# inlined as functions below instead, matching this script's own
# single-file convention (see sddc_manager_api/create_api_session above) -
# response_body is reused as the "last response" variable the same way
# sddc_manager_api already does, rather than writing/reading JSON files.
#
# Every "while read ... ; done < <(...)" below deliberately uses process
# substitution instead of piping into the loop ("... | while read") -
# piping would run the loop body in a subshell, where an exit 100 inside a
# helper (on a real API failure) would only kill that subshell and let the
# script silently carry on instead of actually stopping.
#
#
# check NSX Manager
#
retry_nsx=10 ; pause_nsx=60 ; attempt_nsx=0
while [[ "$(curl -u admin:${generic_password} -k -s -o /dev/null -w '%{http_code}' https://${ip_nsx_vip}/api/v1/cluster/status)" != "200" ]]; do
  log_only "waiting for NSX Manager API to be ready"
  sleep ${pause_nsx}
  ((attempt_nsx++))
  if [ ${attempt_nsx} -eq ${retry_nsx} ]; then
    log_notify "ERROR: NSX Manager API not ready after ${retry_nsx} attempts of ${pause_nsx} seconds"
    exit 100
  fi
done
attempt_nsx=0
while [[ "$(curl -u admin:${generic_password} -k -s https://${ip_nsx_vip}/api/v1/cluster/status | jq -r .detailed_cluster_status.overall_status)" != "STABLE" ]]; do
  log_only "waiting for NSX Manager API to be STABLE"
  sleep ${pause_nsx}
  ((attempt_nsx++))
  if [ ${attempt_nsx} -eq ${retry_nsx} ]; then
    log_notify "ERROR: NSX Manager API not STABLE after ${retry_nsx} attempts of ${pause_nsx} seconds"
    exit 100
  fi
done
log_notify "NSX Manager ready at https://${ip_nsx_vip}"

#
# uplink profile for edge
#
while read -r item
do
  nsx_set_object "policy/api/v1/infra/host-switch-profiles/$(echo ${item} | jq -c -r '.display_name')" PUT "${item}"
done < <(echo ${nsx_config_uplink_profiles} | jq -c -r '.[]')

#
# transport zones
#
while read -r zone
do
  nsx_set_object "api/v1/transport-zones" POST "${zone}"
done < <(echo ${nsx_config_transport_zones} | jq -c -r '.[]')

#
# create the external VLAN segment
#
while read -r item
do
  seg_name=$(echo ${item} | jq -c -r '.display_name')
  tz_path=$(nsx_retrieve_object_path "policy/api/v1/infra/sites/default/enforcement-points/default/transport-zones" "$(echo ${item} | jq -c -r '.transport_zone')")
  seg_data=$(jq -n --arg n "${seg_name}" --arg d "$(echo ${item} | jq -c -r '.description')" \
    --argjson v "$(echo ${item} | jq -c -r '.vlan_ids')" --arg tzp "${tz_path}" \
    '{display_name: $n, description: $d, vlan_ids: $v, transport_zone_path: $tzp}')
  nsx_set_object "policy/api/v1/infra/segments/${seg_name}" PUT "${seg_data}"
done < <(echo ${nsx_config_segments} | jq -c -r '.[]')

#
# update host transport node profile with the VLAN transport zone
#
nsx_get_object "policy/api/v1/infra/host-transport-node-profiles"
htnp_data=$(echo ${response_body} | jq -c -r .results[0])
tz_id=$(nsx_retrieve_object_id "policy/api/v1/infra/sites/default/enforcement-points/default/transport-zones" "$(echo ${nsx_config_transport_zones} | jq -c -r .[0].display_name)")
htnp_data=$(echo ${htnp_data} | jq --arg p "/infra/sites/default/enforcement-points/default/transport-zones/${tz_id}" \
  '.host_switch_spec.host_switches[0].transport_zone_endpoints += [{"transport_zone_id": $p, "transport_zone_profile_ids": []}]')
nsx_set_object "policy/api/v1/infra/host-transport-node-profiles/$(echo ${htnp_data} | jq -c -r '.id')" PUT "$(echo ${htnp_data} | jq -c -r .)"

#
# enable SSH and disable the OVF validation flag (needed for edge node
# deployment to succeed against a nested vCenter) - the reference project's
# disable_ovf_validation_flag.sh trimmed down to its actual mechanic
# (flag check/update/verify) and inlined via heredoc rather than requiring
# a separate file staged in the bootstrap repo.
#
nsx_set_object "api/v1/node/services/ssh" PUT '{"service_name": "ssh","service_properties": {"start_on_boot": true,"root_login": true}}'
nsx_set_object "api/v1/node/services/ssh?action=start" POST ""
cat > /tmp/disable_ovf_validation_flag.sh <<'OVF_FLAG_EOF'
#!/bin/bash
set -euo pipefail
PROPERTIES_FILE="/config/vmware/auth/ovf_validation.properties"
FLAG_NAME="INTERNAL_OVFS_VALIDATION_FLAG"
if grep -q "^${FLAG_NAME}=2$" "${PROPERTIES_FILE}"; then
  echo "Flag already set to 2, no changes needed."
  exit 0
fi
sed -i "s/^${FLAG_NAME}=0$/${FLAG_NAME}=2/" "${PROPERTIES_FILE}"
grep -q "^${FLAG_NAME}=2$" "${PROPERTIES_FILE}"
OVF_FLAG_EOF
export SSHPASS="${generic_password}"
sshpass -e scp -o StrictHostKeyChecking=no /tmp/disable_ovf_validation_flag.sh root@${ip_nsx_vip}:/tmp/disable_ovf_validation_flag.sh
sshpass -e ssh -o StrictHostKeyChecking=no root@${ip_nsx_vip} "bash /tmp/disable_ovf_validation_flag.sh"
unset SSHPASS

#
# edge node creation
#
nsx_get_object "api/v1/fabric/compute-managers"
vc_id=$(echo ${response_body} | jq -c -r --arg arg "${basename_sddc}-vc01.${domain}" '.results[] | select(.display_name == $arg).id')

create_vcenter_api_session
vcenter_api 2 2 GET "api/vcenter/datastore" ""
storage_id=$(echo ${response_body} | jq -r .[0].datastore)
vcenter_api 2 2 GET "api/vcenter/network" ""
management_network_id=$(echo ${response_body} | jq -c -r --arg arg "${basename_sddc}-pg-mgmt" '.[] | select(.name == $arg).network')
# explicit two-element construction (not a single select(A or B) filter) -
# jq's select preserves vCenter's own api/vcenter/network response order,
# not the order these two --arg names are declared, so fp-eth0/fp-eth1
# (which data_network_ids[0]/[1] become on the edge VM) could silently end
# up swapped depending on how vCenter happens to list the two networks -
# confirmed live: edge-uplink1 (meant for fp-eth0/overlay) landed on
# fp-eth1/external and vice versa, breaking inter-edge TEP/overlay
# connectivity (Tier-0/Tier-1 HA never formed) despite every NSX config
# object looking correctly realized.
data_network_ids=$(echo ${response_body} | jq -c --arg u "${basename_sddc}-edge-uplink1" --arg e "${basename_sddc}-pg-external" \
  '[(.[] | select(.name == $u) | .network), (.[] | select(.name == $e) | .network)]')
vcenter_api 2 2 GET "api/vcenter/cluster" ""
cluster_id=$(echo ${response_body} | jq -c -r --arg arg "${basename_sddc}-cluster" '.[] | select(.name == $arg).cluster')
vcenter_api 2 2 GET "api/vcenter/cluster/${cluster_id}" ""
compute_id=$(echo ${response_body} | jq -c -r '.resource_pool')

edge_ids="[]"
for edge_index in $(seq 1 $(echo ${nsx_config_ips_edge} | jq -c -r '. | length'))
do
  edge_name="${nsx_config_edge_node_basename}${edge_index}"
  edge_fqdn="${edge_name}.${domain}"
  ip_edge="${cidr_mgmt_three_octets}.$(echo ${nsx_config_ips_edge} | jq -r .[$((edge_index - 1))])"

  host_switches_built="[]"
  while read -r hs
  do
    profile_ids="[]"
    while read -r profile_name
    do
      nsx_get_object "api/v1/host-switch-profiles"
      profile_id=$(echo ${response_body} | jq -c -r --arg arg "${profile_name}" '.results[] | select(.display_name == $arg).id')
      profile_ids=$(echo ${profile_ids} | jq -c --arg id "${profile_id}" '. + [{"key":"UplinkHostSwitchProfile","value":$id}]')
    done < <(echo ${hs} | jq -c -r '.host_switch_profile_names[]')

    tz_endpoints="[]"
    while read -r tz_name
    do
      nsx_get_object "api/v1/transport-zones"
      tz_id=$(echo ${response_body} | jq -c -r --arg arg "${tz_name}" '.results[] | select(.display_name == $arg).id')
      tz_endpoints=$(echo ${tz_endpoints} | jq -c --arg id "${tz_id}" '. + [{"transport_zone_id":$id}]')
    done < <(echo ${hs} | jq -c -r '.transport_zone_names[]')

    hs_built=$(echo ${hs} | jq -c --argjson p "${profile_ids}" --argjson t "${tz_endpoints}" --arg v "$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)" \
      '. + {host_switch_profile_ids:$p, transport_zone_endpoints:$t, vlan:$v} | del(.host_switch_profile_names, .transport_zone_names)')
    if [ "$(echo ${hs} | jq -r '.ip_pool_name_9_1 // empty')" != "" ]; then
      nsx_get_object "api/v1/infra/ip-pools"
      ip_pool_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${hs} | jq -r .ip_pool_name_9_1)" '.results[] | select(.display_name == $arg).realization_id')
      hs_built=$(echo ${hs_built} | jq -c --arg id "${ip_pool_id}" '. + {ip_assignment_spec: {ip_pool_id: $id, resource_type: "StaticIpPoolSpec"}} | del(.ip_pool_name_9_1)')
    fi
    host_switches_built=$(echo ${host_switches_built} | jq -c --argjson hs "${hs_built}" '. + [$hs]')
  done < <(echo ${nsx_config_edge_node_host_switch_spec_host_switches} | jq -c -r '.[]')

  edge_json=$(jq -n \
    --argjson host_switches "${host_switches_built}" \
    --arg edge_name "${edge_name}" --arg edge_fqdn "${edge_fqdn}" \
    --arg vc_id "${vc_id}" --arg compute_id "${compute_id}" --arg storage_id "${storage_id}" \
    --arg ip_edge "${ip_edge}" --argjson mgmt_prefix "${mgmt_prefix_length}" --arg ip_gw_mgmt "${ip_gw_mgmt}" \
    --argjson data_network_ids "${data_network_ids}" --arg management_network_id "${management_network_id}" \
    --argjson edge_cpu "${nsx_config_edge_node_cpu}" --argjson edge_memory "${nsx_config_edge_node_memory}" \
    --arg root_password "${generic_password}" \
    '{
      host_switch_spec: {host_switches: $host_switches, resource_type: "StandardHostSwitchSpec"},
      maintenance_mode: "DISABLED",
      display_name: $edge_name,
      node_deployment_info: {
        resource_type: "EdgeNode",
        deployment_type: "VIRTUAL_MACHINE",
        deployment_config: {
          vm_deployment_config: {
            vc_id: $vc_id, compute_id: $compute_id, storage_id: $storage_id,
            management_network_id: $management_network_id,
            management_port_subnets: [{ip_addresses: [$ip_edge], prefix_length: $mgmt_prefix}],
            default_gateway_addresses: [$ip_gw_mgmt],
            data_network_ids: $data_network_ids,
            reservation_info: {memory_reservation: {reservation_percentage: 100}, cpu_reservation: {reservation_in_shares: "HIGH_PRIORITY", reservation_in_mhz: 0}},
            resource_allocation: {cpu_count: $edge_cpu, memory_allocation_in_mb: $edge_memory},
            placement_type: "VsphereDeploymentConfig"
          },
          form_factor: "MEDIUM",
          node_user_settings: {cli_username: "admin", root_password: $root_password, cli_password: $root_password}
        },
        node_settings: {hostname: $edge_fqdn, allow_ssh_root_login: true}
      }
    }')
  nsx_set_object "api/v1/transport-nodes" POST "${edge_json}"
  edge_ids=$(echo ${edge_ids} | jq -c --arg id "$(echo ${response_body} | jq -r .id)" '. + [$id]')
done

#
# wait for the edge nodes to come up
#
log_only "waiting 600 seconds for edge nodes to initialize"
sleep 600
retry_edge=240 ; pause_edge=20
while read -r edge_id
do
  attempt_edge=0
  while true ; do
    nsx_get_object "policy/api/v1/transport-nodes/state"
    state=$(echo ${response_body} | jq -c -r --arg arg "${edge_id}" '.results[] | select(.transport_node_id == $arg).state')
    if [[ ${state} == "success" ]]; then
      log_notify "edge node ${edge_id} ready after ${attempt_edge} attempts of ${pause_edge} seconds"
      break
    fi
    ((attempt_edge++))
    if [ ${attempt_edge} -eq ${retry_edge} ]; then
      log_notify "ERROR: edge node ${edge_id} not ready after ${attempt_edge} attempts of ${pause_edge} seconds"
      exit 100
    fi
    sleep ${pause_edge}
  done
done < <(echo ${edge_ids} | jq -c -r '.[]')

#
# edge cluster creation
#
while read -r ec
do
  members="[]"
  while read -r member_name
  do
    nsx_get_object "api/v1/transport-nodes"
    tn_id=$(echo ${response_body} | jq -c -r --arg arg "${member_name}" '.results[] | select(.display_name == $arg).id')
    members=$(echo ${members} | jq -c --arg id "${tn_id}" '. + [{"transport_node_id": $id}]')
  done < <(echo ${ec} | jq -c -r '.members[].display_name')
  nsx_set_object "api/v1/edge-clusters" POST "$(echo ${ec} | jq -c --argjson m "${members}" '{display_name: .display_name, members: $m}')"
done < <(echo ${nsx_config_edge_clusters} | jq -c -r '.[]')

#
# tier-0 creation
#
while read -r t0
do
  t0_name=$(echo ${t0} | jq -c -r .display_name)
  nsx_set_object "policy/api/v1/infra/tier-0s/${t0_name}" PUT "$(jq -n --arg n "${t0_name}" --arg h "$(echo ${t0} | jq -r .ha_mode)" '{display_name: $n, ha_mode: $h}')"
done < <(echo ${nsx_config_tier0s} | jq -c -r '.[]')

#
# tier-0 edge cluster association
#
while read -r t0
do
  t0_name=$(echo ${t0} | jq -c -r .display_name)
  edge_cluster_id=$(nsx_retrieve_object_id "api/v1/edge-clusters" "$(echo ${t0} | jq -r .edge_cluster_name)")
  nsx_set_object "policy/api/v1/infra/tier-0s/${t0_name}/locale-services/default" PUT \
    "{\"edge_cluster_path\": \"/infra/sites/default/enforcement-points/default/edge-clusters/${edge_cluster_id}\"}"
done < <(echo ${nsx_config_tier0s} | jq -c -r '.[]')

#
# tier-0 interface config
#
nsx_tier0_ip=${nsx_tier0_starting_ip}
while read -r t0
do
  t0_name=$(echo ${t0} | jq -c -r .display_name)
  if [ "$(echo ${t0} | jq 'has("interfaces")')" == "true" ]; then
    while read -r iface
    do
      iface_name=$(echo ${iface} | jq -r .display_name)
      segment_path=$(nsx_retrieve_object_path "policy/api/v1/infra/segments" "$(echo ${iface} | jq -r .segment_name)")
      edge_cluster_id=$(nsx_retrieve_object_id "api/v1/edge-clusters" "$(echo ${t0} | jq -r .edge_cluster_name)")
      nsx_get_object "api/v1/edge-clusters"
      edge_node_id=$(echo ${response_body} | jq -c -r --arg c "$(echo ${t0} | jq -r .edge_cluster_name)" --arg e "$(echo ${iface} | jq -r .edge_name)" \
        '.results[] | select(.display_name == $c).members[] | select(.display_name == $e).member_index')
      iface_data=$(jq -n --arg ip "${cidr_external_three_octets}.${nsx_tier0_ip}" --argjson pl "${external_prefix_length}" \
        --arg n "${iface_name}" --arg sp "${segment_path}" \
        --arg ep "/infra/sites/default/enforcement-points/default/edge-clusters/${edge_cluster_id}/edge-nodes/${edge_node_id}" \
        '{subnets: [{ip_addresses: [$ip], prefix_len: $pl}], display_name: $n, segment_path: $sp, edge_path: $ep}')
      nsx_tier0_ip=$((nsx_tier0_ip+1))
      nsx_set_object "policy/api/v1/infra/tier-0s/${t0_name}/locale-services/default/interfaces/${iface_name}" PATCH "${iface_data}"
    done < <(echo ${t0} | jq -c -r '.interfaces[]')
  fi
done < <(echo ${nsx_config_tier0s} | jq -c -r '.[]')

#
# tier-0 static routes
#
while read -r t0
do
  t0_name=$(echo ${t0} | jq -c -r .display_name)
  if [ "$(echo ${t0} | jq 'has("static_routes")')" == "true" ]; then
    while read -r route
    do
      route_data=$(echo ${route} | jq -c --arg ip "${ip_gw_external}" '.next_hops[0] += {"ip_address": $ip}')
      nsx_set_object "policy/api/v1/infra/tier-0s/${t0_name}/static-routes/$(echo ${route} | jq -r .display_name)" PATCH "${route_data}"
    done < <(echo ${t0} | jq -c -r '.static_routes[]')
  fi
done < <(echo ${nsx_config_tier0s} | jq -c -r '.[]')

#
# tier-0 HA VIP config
#
nsx_tier0_vip_ip=${nsx_tier0_tier0_vip_starting_ip}
while read -r t0
do
  t0_name=$(echo ${t0} | jq -c -r .display_name)
  ha_data='{"display_name": "default", "ha_vip_configs": []}'
  if [ "$(echo ${t0} | jq 'has("ha_vips")')" == "true" ]; then
    edge_cluster_id=$(nsx_retrieve_object_id "api/v1/edge-clusters" "$(echo ${t0} | jq -r .edge_cluster_name)")
    ha_data=$(echo ${ha_data} | jq --arg p "/infra/sites/default/enforcement-points/default/edge-clusters/${edge_cluster_id}" '. + {edge_cluster_path: $p}')
    while read -r vip
    do
      interfaces="[]"
      while read -r iface
      do
        interfaces=$(echo ${interfaces} | jq -c --arg p "/infra/tier-0s/${t0_name}/locale-services/default/interfaces/${iface}" '. + [$p]')
      done < <(echo ${vip} | jq -c -r '.interfaces[]')
      ha_data=$(echo ${ha_data} | jq -c --arg ip "${cidr_external_three_octets}.${nsx_tier0_vip_ip}" --argjson pl "${external_prefix_length}" --argjson ifaces "${interfaces}" \
        '.ha_vip_configs += [{enabled: true, vip_subnets: [{ip_addresses: [$ip], prefix_len: $pl}], external_interface_paths: $ifaces}]')
      nsx_tier0_vip_ip=$((nsx_tier0_vip_ip+1))
    done < <(echo ${t0} | jq -c -r '.ha_vips[]')
    nsx_set_object "policy/api/v1/infra/tier-0s/${t0_name}/locale-services/default" PATCH "${ha_data}"
  fi
done < <(echo ${nsx_config_tier0s} | jq -c -r '.[]')

#
# DHCP servers
#
while read -r item
do
  nsx_set_object "policy/api/v1/infra/dhcp-server-configs/$(echo ${item} | jq -c -r '.display_name')" PUT "${item}"
done < <(echo ${nsx_config_dhcp_servers} | jq -c -r '.[]')

#
# tier-1 creation
#
while read -r t1
do
  t1_name=$(echo ${t1} | jq -r .display_name)
  tier0_path=$(nsx_retrieve_object_path "policy/api/v1/infra/tier-0s" "$(echo ${t1} | jq -r .tier0)")
  dhcp_config_path=$(nsx_retrieve_object_path "policy/api/v1/infra/dhcp-server-configs" "$(echo ${t1} | jq -r .dhcp_server)")
  t1_data=$(jq -n --arg n "${t1_name}" --arg t0p "${tier0_path}" --arg dcp "${dhcp_config_path}" --argjson rat "$(echo ${t1} | jq -c .route_advertisement_types)" \
    '{display_name: $n, tier0_path: $t0p, dhcp_config_paths: [$dcp], route_advertisement_types: $rat}')
  if [ "$(echo ${t1} | jq 'has("ha_mode")')" == "true" ]; then
    t1_data=$(echo ${t1_data} | jq --arg h "$(echo ${t1} | jq -r .ha_mode)" '. + {ha_mode: $h}')
  fi
  nsx_set_object "policy/api/v1/infra/tier-1s/${t1_name}" PUT "${t1_data}"
  if [ "$(echo ${t1} | jq 'has("edge_cluster_name")')" == "true" ]; then
    edge_cluster_id=$(nsx_retrieve_object_id "api/v1/edge-clusters" "$(echo ${t1} | jq -r .edge_cluster_name)")
    nsx_set_object "policy/api/v1/infra/tier-1s/${t1_name}/locale-services/default" PUT \
      "{\"display_name\": \"default\", \"edge_cluster_path\": \"/infra/sites/default/enforcement-points/default/edge-clusters/${edge_cluster_id}\"}"
  fi
done < <(echo ${nsx_config_tier1s} | jq -c -r '.[]')

#
# overlay segments (with DHCP)
#
while read -r seg
do
  seg_name=$(echo ${seg} | jq -r .display_name)
  connectivity_path=$(nsx_retrieve_object_path "policy/api/v1/infra/tier-1s" "$(echo ${seg} | jq -r .tier1)")
  transport_zone_path=$(nsx_retrieve_object_path "policy/api/v1/infra/sites/default/enforcement-points/default/transport-zones" "$(echo ${seg} | jq -r .transport_zone)")
  seg_data=$(jq -n --arg n "${seg_name}" --arg cp "${connectivity_path}" --arg tzp "${transport_zone_path}" \
    --arg gw "$(echo ${seg} | jq -r .gateway_address)" --argjson dr "$(echo ${seg} | jq -c .dhcp_ranges)" --arg dns "${ip_gw}" \
    '{display_name: $n, connectivity_path: $cp, transport_zone_path: $tzp,
      subnets: [{gateway_address: $gw, dhcp_ranges: $dr,
                 dhcp_config: {options: {others: [{code: 42, values: [$dns]}]}, resource_type: "SegmentDhcpV4Config", dns_servers: [$dns]}}]}')
  nsx_set_object "policy/api/v1/infra/segments/${seg_name}" PUT "${seg_data}"
done < <(echo ${nsx_segments_overlay} | jq -c -r '.[]')


# Avi Controller deployment via SDDC Manager (merged from the reference
# project's sddc-manager/avi-sddc.sh) - the 9.0 branch (manual pvc.json/OVA
# upload over scp) is dropped, VCF 9.1-only scope as elsewhere in this
# script. SDDC Manager exposes the same v1/tokens + v1/bundles API shape as
# the VCF Installer appliance, so this reuses create_api_session/
# sddc_manager_api directly rather than needing new helpers - just pointed
# at ${basename_sddc}-sddcm.${domain} instead of ${ip_vcf_installer}, since
# once the SDDC finishes building, SDDC Manager (not VCF Installer) owns
# the API. Login is administrator@<ssoDomain>, not admin@local - the local
# VCF Installer account doesn't carry over to the persistent SDDC Manager
# appliance.
#
ip_sddcm="${basename_sddc}-sddcm.${domain}"
create_api_session "administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)" "${generic_password}" "${ip_sddcm}" /tmp/token_sddcm.json

# spec.sddc.avi.version pins which NSX_ALB bundle to use when set (see
# crd-vapp.yaml) - matched by version prefix. Otherwise falls back to
# just taking the first NSX_ALB entry found (the historical behavior,
# ambiguous only if a later depot sync adds a second one before this
# first-ever download/deploy runs - unusual but not impossible).
sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/bundles $(jq -c -r .accessToken /tmp/token_sddcm.json)
if [ -n "${avi_version}" ]; then
  avi_bundle_id=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" --arg ver "${avi_version}" '.elements[] | select(.components[0].description == $arg and (.version | startswith($ver))) | .id')
  avi_download_status=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" --arg ver "${avi_version}" '.elements[] | select(.components[0].description == $arg and (.version | startswith($ver))) | .downloadStatus')
else
  avi_bundle_id=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .id' | head -1)
  avi_download_status=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .downloadStatus' | head -1)
fi
if [[ ${avi_download_status} != "SUCCESSFUL" ]]; then
  sddc_manager_api 3 2 PATCH '{"bundleDownloadSpec":{"downloadNow":true}}' "${ip_sddcm}" v1/bundles/${avi_bundle_id} $(jq -c -r .accessToken /tmp/token_sddcm.json)
  log_only "waiting 120 seconds for Avi bundle download to start"
  sleep 120
fi

retry_avi_download=30 ; pause_avi_download=10 ; attempt_avi_download=1
while true ; do
  sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/bundles $(jq -c -r .accessToken /tmp/token_sddcm.json)
  if [ -n "${avi_version}" ]; then
    avi_download_status=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" --arg ver "${avi_version}" '.elements[] | select(.components[0].description == $arg and (.version | startswith($ver))) | .downloadStatus')
  else
    avi_download_status=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .downloadStatus' | head -1)
  fi
  if [[ ${avi_download_status} == "SUCCESSFUL" ]]; then
    log_notify "Avi bundle downloaded"
    break
  fi
  if [ ${attempt_avi_download} -eq ${retry_avi_download} ]; then
    log_notify "ERROR: Avi bundle not downloaded after ${attempt_avi_download} attempts of ${pause_avi_download} seconds"
    exit 100
  fi
  sleep ${pause_avi_download}
  ((attempt_avi_download++))
done

sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/domains $(jq -c -r .accessToken /tmp/token_sddcm.json)
nsx_id=$(echo ${response_body} | jq -c -r '.elements[0].nsxtCluster.id')

if [[ $(echo ${ips_avi} | jq -c -r '. | length') -eq 3 ]]; then
  avi_cluster_json=$(jq -n --arg pw "${generic_password}" --arg bundle "${avi_bundle_id}" --arg fqdn "${basename_sddc}-avi.${domain}" --arg nsx "${nsx_id}" --argjson ips "${ips_avi}" \
    '{adminPassword: $pw, bundleId: $bundle, clusterFqdn: $fqdn, clusterName: "cluster-1", formFactor: "SMALL",
      nodes: [$ips[] | {ipAddress: .}], nsxIds: [$nsx], vcfopsAdminPassword: $pw}')
  sddc_manager_api 3 2 POST "${avi_cluster_json}" "${ip_sddcm}" v1/alb-clusters $(jq -c -r .accessToken /tmp/token_sddcm.json)
  log_notify "Avi cluster deployment started"
else
  #
  # single-node Avi controller needs a feature flag enabled on SDDC Manager
  # first (same expect-based su pattern as the earlier lcm/domainmanager
  # patch, since su also refuses to run without a real controlling
  # terminal here) - replaces the reference project's more generic
  # patch_sddcm.sh with just the two commands it actually runs.
  #
  log_notify "patching SDDC Manager for single-node Avi controller support"
  export SDDCM_ROOT_PASSWORD="${generic_password}"
  export SDDCM_HOST="${ip_sddcm}"
  expect <<'SDDCM_EXPECT_EOF'
set timeout 60
set password $env(SDDCM_ROOT_PASSWORD)
spawn ssh -tt -o StrictHostKeyChecking=no vcf@$env(SDDCM_HOST)
expect "*assword:" { send "$password\r" }
expect "*$ " { send "su -\r" }
expect "*assword:" { send "$password\r" }
expect "*# " { send "echo 'feature.vcf.vgl-41078.alb.single.node.cluster=true' | tee /home/vcf/feature.properties\r" }
expect "*# " { send "printf 'y' | /opt/vmware/vcf/operationsmanager/scripts/cli/sddcmanager_restart_services.sh\r" }
expect "*# " { send "exit\r" }
expect "*$ " { send "exit\r" }
expect eof
SDDCM_EXPECT_EOF
unset SDDCM_ROOT_PASSWORD SDDCM_HOST
log_only "waiting 180 seconds for SDDC Manager services to restart"
sleep 180

avi_cluster_json=$(jq -n --arg pw "${generic_password}" --arg bundle "${avi_bundle_id}" --arg fqdn "${basename_sddc}-avi.${domain}" --arg nsx "${nsx_id}" --arg ip "$(echo ${ips_avi} | jq -r '.[0]')" \
  '{adminPassword: $pw, bundleId: $bundle, clusterFqdn: $fqdn, clusterName: "cluster-1", formFactor: "SMALL",
    nodes: [{ipAddress: $ip}], nsxIds: [$nsx], vcfopsAdminPassword: $pw}')
sddc_manager_api 3 2 POST "${avi_cluster_json}" "${ip_sddcm}" v1/alb-clusters $(jq -c -r .accessToken /tmp/token_sddcm.json)
log_notify "single-node Avi controller deployment started"
log_only "waiting 1800 seconds for Avi controller deployment"
sleep 1800

create_api_session "administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)" "${generic_password}" "${ip_sddcm}" /tmp/token_sddcm.json
retry_avi_deploy=60 ; pause_avi_deploy=10 ; attempt_avi_deploy=1
while true ; do
  sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/alb-clusters $(jq -c -r .accessToken /tmp/token_sddcm.json)
  avi_deploy_status=$(echo ${response_body} | jq -c -r '.elements[0].deploymentStatus')
  if [[ ${avi_deploy_status} == "ACTIVE" ]]; then
    log_notify "Avi controller deployed"
    break
  fi
  if [ ${attempt_avi_deploy} -eq ${retry_avi_deploy} ]; then
    log_notify "ERROR: Avi controller not deployed after ${attempt_avi_deploy} attempts of ${pause_avi_deploy} seconds"
    exit 100
  fi
  sleep ${pause_avi_deploy}
  ((attempt_avi_deploy++))
done
fi

#
# Avi Controller configuration (merged from the reference project's
# avi/configure_avi.sh) - the 9.0/8.0U3b branch (ansible-driven config via
# an external avi_ansible_config_repo playbook) is dropped, VCF 9.1-only
# scope as elsewhere in this script. Reuses create_api_session/
# sddc_manager_api against ${ip_sddcm} (already set up in the Avi
# deployment section above) to look up the Avi bundle version.
#
# The reference project's top-of-script content library creation targets
# the OUTER/host vCenter (via load_govc_env_with_cluster, a vCenter/govc
# managing the physical hosts this whole nested lab runs on) - this project
# has no such thing, everything outer-layer is VCD-managed instead. The
# content library Avi's own vcenterserver config later attaches to is
# created on OUR nested vCenter instead, reusing the same GOVC_* pattern as
# the port-group section earlier in this script.
#
mkdir -p /home/ubuntu/avi
export GOVC_URL="${basename_sddc}-vc01.${domain}"
export GOVC_USERNAME="administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)"
export GOVC_PASSWORD="${generic_password}"
export GOVC_DATACENTER="${basename_sddc}-dc"
export GOVC_INSECURE=true
export GOVC_PERSIST_SESSION=false
unset GOVC_CLUSTER
govc_error=$(govc about 2>&1)
if [ $? -ne 0 ]; then
  log_notify "ERROR: unable to connect to vCenter for Avi content library setup: ${govc_error}"
  exit 100
fi
content_library_id=$(govc library.ls -json | jq -c -r --arg arg "${avi_content_library_name}" '(. // [])[] | select(.name == $arg) | .id')
if [ -z "${content_library_id}" ]; then
  govc library.create "${avi_content_library_name}" > /dev/null
fi

#
# Avi HTTPS check - ip_avi is the first (and, for a standalone controller,
# only) node from the Avi deployment section above.
#
ip_avi=$(echo ${ips_avi} | jq -r '.[0]')
count=1
until $(curl --output /dev/null --silent --head -k https://${ip_avi})
do
  log_only "Attempt ${count}: Waiting for Avi ctrl at https://${ip_avi} to be reachable..."
  sleep 10
  count=$((count+1))
  if [[ "${count}" -eq 60 ]]; then
    log_notify "ERROR: Unable to connect to Avi ctrl at https://${ip_avi}"
    exit 100
  fi
done
log_notify "Avi ctrl reachable at https://${ip_avi}"

# spec.sddc.avi.version pins this explicitly when set (see crd-vapp.yaml)
# - only fall back to deriving it from SDDC Manager's v1/bundles list when
# unset. That lookup is ambiguous once more than one NSX_ALB bundle shows
# up there (a later depot sync can add a newer one alongside whatever was
# already downloaded) - filtering on downloadStatus == "SUCCESSFUL" picks
# the one that's actually usable rather than just whatever jq happens to
# return first.
if [ -z "${avi_version}" ]; then
  create_api_session "administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)" "${generic_password}" "${ip_sddcm}" /tmp/token_sddcm.json
  sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/bundles $(jq -c -r .accessToken /tmp/token_sddcm.json)
  avi_version=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg and .downloadStatus == "SUCCESSFUL") | .version' | head -1 | cut -d"-" -f1)
fi

avi_login

#
# backup user + backup config
#
# Idempotent (unlike the reference project's own always-POST version) -
# reuses an existing "ubuntu" cloudconnectoruser instead of erroring with
# a 409 on every re-run after the first, since this step has no natural
# reason to ever need re-creating.
avi_api 2 2 GET "" "api/cloudconnectoruser?name=ubuntu"
cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid // empty')
if [ -z "${cloudconnectoruser_uuid}" ]; then
  avi_api 2 2 POST "$(jq -n --arg n "ubuntu" --arg p "${generic_password}" '{name: $n, password: $p}')" api/cloudconnectoruser
  cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.uuid')
fi
avi_api 2 2 GET "" api/backupconfiguration
backupconfiguration_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
backup_json=$(jq -n --arg pw "${generic_password}" --arg host "${ip_gw}" --arg ssh "${cloudconnectoruser_uuid}" \
  '{replace: {name: "Backup-Configuration", backup_passphrase: $pw, save_local: true, upload_to_remote_host: true,
    remote_directory: "/home/ubuntu/avi/backup", remote_file_transfer_protocol: "SCP", remote_hostname: $host, ssh_user_ref: $ssh}}')
avi_api 2 2 PATCH "${backup_json}" "api/backupconfiguration/${backupconfiguration_uuid}"

#
# system config, fault config, controller properties
#
avi_api 2 2 GET "" api/systemconfiguration
avi_api 2 2 PUT "$(echo ${response_body} | jq -c '. + {welcome_workflow_complete: true, default_license_tier: "ENTERPRISE_WITH_CLOUD_SERVICES"}')" api/systemconfiguration
avi_api 2 2 GET "" api/inventoryfaultconfig
avi_api 2 2 PUT "$(echo ${response_body} | jq -c '. + {controller_faults: {sslprofile_faults: false, license_faults: false}}')" api/inventoryfaultconfig
avi_api 2 2 GET "" api/controllerproperties
avi_api 2 2 PUT "$(echo ${response_body} | jq -c '. + {api_idle_timeout: 240}')" api/controllerproperties

#
# cloud + NSX discovery (transport zone, tier1s, segments)
#
avi_api 2 2 GET "" api/cloud
cloud_uuid=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .uuid')
cloud_url=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .url')
nsx_url=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .nsxt_configuration.nsxt_url')
avi_api 2 2 GET "" api/cloudconnectoruser
nsx_cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.results[] | select(has("nsxt_credentials")) | .uuid')
vcenter_cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.results[] | select(has("vcenter_credentials")) | .uuid')

nsx_lookup_json=$(jq -n --arg h "${nsx_url}" --arg c "${nsx_cloudconnectoruser_uuid}" '{host: $h, credentials_uuid: $c}')
avi_api 2 2 POST "${nsx_lookup_json}" api/nsxt/transportzones
tz_id=$(echo ${response_body} | jq -c -r --arg arg "VCF-Created-Overlay-Zone" '.resource.nsxt_transportzones[] | select(.name == $arg) | .id')

avi_api 2 2 POST "${nsx_lookup_json}" api/nsxt/tier1s
t1_mgmt_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select( .avi_mgmt == true) | .tier1')" '.resource.nsxt_tier1routers[] | select(.name == $arg) | .id')
t1_vip_name=$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .tier1')
t1_vip_id=$(echo ${response_body} | jq -c -r --arg arg "${t1_vip_name}" '.resource.nsxt_tier1routers[] | select(.name == $arg) | .id')

avi_api 2 2 POST "$(echo ${nsx_lookup_json} | jq -c --arg tz "${tz_id}" '. + {transport_zone_id: $tz}')" api/nsxt/segments
seg_mgmt_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select( .avi_mgmt == true) | .display_name')" '.resource.nsxt_segments[] | select(.name == $arg) | .id')
seg_vip_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .display_name')" '.resource.nsxt_segments[] | select(.name == $arg) | .id')

#
# vcenterserver + content library attach (avi_content_library_id is Avi's
# own internal id for the library from its vCenter discovery, distinct
# from govc's content_library_id fetched/created above by name)
#
avi_api 2 2 GET "" api/vcenterserver
vcenter_server_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
vcenter_server_url=$(echo ${response_body} | jq -c -r '.results[0].vcenter_url')
avi_api 2 2 POST "$(jq -n --arg h "${vcenter_server_url}" --arg c "${vcenter_cloudconnectoruser_uuid}" '{host: $h, credentials_uuid: $c}')" api/vcenter/contentlibraries
avi_content_library_id=$(echo ${response_body} | jq -c -r --arg arg "${avi_content_library_name}" '.resource.vcenter_clibs[] | select(.name == $arg) | .id')
avi_api 2 2 PATCH "$(jq -n --arg id "${avi_content_library_id}" '{add: {content_lib: {id: $id}}}')" "api/vcenterserver/${vcenter_server_uuid}"

#
# cloud nsxt_configuration update (mgmt + data network placement)
#
cloud_update_json=$(jq -n --arg tz "${tz_id}" --arg t1m "${t1_mgmt_id}" --arg segm "${seg_mgmt_id}" --arg t1v "${t1_vip_id}" --arg segv "${seg_vip_id}" \
  '{add: {nsxt_configuration: {
      management_network_config: {tz_type: "OVERLAY", transport_zone: $tz, overlay_segment: {tier1_lr_id: $t1m, segment_id: $segm}},
      data_network_config: {tz_type: "OVERLAY", transport_zone: $tz, tier1_segment_config: {segment_config_mode: "TIER1_SEGMENT_MANUAL", manual: {tier1_lrs: [{tier1_lr_id: $t1v, segment_id: $segv}]}}}
  }}}')
avi_api 2 2 PATCH "${cloud_update_json}" "api/cloud/${cloud_uuid}"

#
# DNS profile, then re-login (matching the reference's own wait+relogin
# here, presumably to pick up the cloud placement before the next calls)
#
# One dns_service_domain entry for the base avi_subdomain (e.g.
# app.vcf9.lab, used by anything not org-scoped) PLUS one entry per org
# actually configured (org-1.vcf9.lab, org-2.vcf9.lab, ...) - needed
# because each org's blueprints resolve their own per-org FQDN (see the
# blueprints section further below, which substitutes avi_subdomain with
# the org's own name for exactly this reason) - without a matching DNS
# service domain per org, Avi's internal DNS/IPAM has nothing
# authoritative to resolve those hostnames against. vcf_a_organizations
# is already the full expanded per-org list (empty array if
# sddc.vcf_a is unset, matching every other vcf_a_* variable). Confirmed
# live (pass_through: true on every entry) via the equivalent manual
# config on the sddc/vCenter reference environment's own Avi controller.
#
avi_dns_domains_json=$(jq -n --arg base "${avi_subdomain}.${domain}" --argjson orgs "${vcf_a_organizations}" --arg domain "${domain}" \
  '[{domain_name: $base, pass_through: true}] + ($orgs | map({domain_name: (.name + "." + $domain), pass_through: true}))')
avi_api 2 2 POST "$(jq -n --argjson dsd "${avi_dns_domains_json}" '{name: "dns-avi", type: "IPAMDNS_TYPE_INTERNAL_DNS", internal_profile: {dns_service_domain: $dsd}}')" api/ipamdnsproviderprofile
log_only "configure Avi - waiting 120 seconds"
sleep 120
avi_login

#
# IPAM profile + cloud ipam/dns refs
#
avi_api 2 2 GET "" api/network
vip_uuid=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .display_name')" '.results[] | select(.name == $arg) | .uuid')
avi_api 2 2 POST "$(jq -n --arg ref "/api/network/${vip_uuid}" '{name: "ipam-avi", type: "IPAMDNS_TYPE_INTERNAL", internal_profile: {usable_networks: [{nw_ref: $ref}]}}')" api/ipamdnsproviderprofile
avi_api 2 2 PATCH '{"add": {"ipam_provider_ref": "/api/ipamdnsproviderprofile/?name=ipam-avi", "dns_provider_ref": "/api/ipamdnsproviderprofile/?name=dns-avi"}}' "api/cloud/${cloud_uuid}"

#
# network update - static VIP pool on the overlay segment
#
vip_cidr=$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .avi_ipam_vip.cidr')
vip_pool=$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .avi_ipam_vip.pool')
network_update_json=$(jq -n --arg addr "$(echo ${vip_cidr} | cut -d'/' -f1)" --arg mask "$(echo ${vip_cidr} | cut -d'/' -f2)" \
  --arg begin "$(echo ${vip_pool} | cut -d'-' -f1)" --arg end "$(echo ${vip_pool} | cut -d'-' -f2)" \
  '{add: {dhcp_enabled: true, exclude_discovered_subnets: true, configured_subnets: [{
      prefix: {ip_addr: {addr: $addr, type: "V4"}, mask: $mask},
      static_ip_ranges: [{type: "STATIC_IPS_FOR_VIP", range: {begin: {addr: $begin, type: "V4"}, end: {addr: $end, type: "V4"}}}]
  }]}}')
avi_api 2 2 PATCH "${network_update_json}" "api/network/${vip_uuid}"

#
# Pulse cloud-services registration - optional, skipped entirely unless
# spec.sddc.avi.jwt_token/account_id are set.
#
if [ -n "${avi_jwt_token}" ] && [ -n "${avi_account_id}" ]; then
  avi_api 2 2 GET "" api/albservices/status
  avi_api 2 2 POST "$(jq -n --arg t "${avi_jwt_token}" '{jwt_token: $t}')" api/portal/refresh-access-token
  log_only "waiting 20 seconds"
  sleep 20
  random_string=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
  avi_api 2 2 POST "$(jq -n --arg n "workshop-demo-${random_string}" --arg acct "${avi_account_id}" '{name: $n, description: "Registration and deregistration", email: "avi.workshop@broadcom.com", account_id: $acct}')" api/albservices/register
  log_only "waiting 20 seconds"
  sleep 20
  avi_api 2 2 PATCH '{"replace": {"feature_opt_in_status": {"enable_appsignature_sync": true, "enable_ip_reputation": true, "enable_pulse_case_management": false, "enable_pulse_waf_management": true, "enable_user_agent_db_sync": false}, "waf_config": {"enable_auto_download_waf_signatures": true, "enable_waf_signatures_notifications": true}}}' api/albservicesconfig
  log_only "waiting 10 seconds"
  sleep 10
  avi_api 2 2 GET "" api/albservices/pool
  avi_api 2 2 POST "$(jq -n --arg id "$(echo ${response_body} | jq -c -r '.results[0].pool_id')" '{pool_id: $id}')" api/licensing/v1/cloud/subscribe
else
  log_only "avi_jwt_token/avi_account_id not set, skipping Pulse cloud-services registration"
fi

#
# availability zones (one per nested ESXi host, via Avi's NSX-T transport
# node discovery) and the default Service Engine Group
#
avi_api 2 2 GET "" api/vcenterserver
vcenter_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
log_only "waiting 10 seconds"
sleep 10
avi_api 2 2 GET "" api/cloud
cloud_uuid=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .uuid')
log_only "waiting 60 seconds"
sleep 60
# transport_zone_id is required here even though neither the reference
# project's own script nor Avi's inferred-from-cloud-config behavior
# includes it - confirmed empirically (fails with "Transportzone path
# missing" / HTTP 500 without it, works with it) against this Avi
# version (32.1.1), despite the cloud object's own nsxt_configuration
# already having a valid transport_zone set. tz_id was already looked up
# earlier in this same script (transport zone discovery, above).
avi_api 2 2 POST "$(jq -n --arg c "${cloud_uuid}" --arg v "${vcenter_uuid}" --arg tz "${tz_id}" '{cloud_uuid: $c, vcenter_uuid: $v, transport_zone_id: $tz}')" api/nsxt/transportnodes
list_az_uuids="[]"
while read -r item
do
  az_json=$(jq -n --arg hid "$(echo ${item} | jq -c -r '.vc_mobj_id')" --arg vc "${vcenter_uuid}" --arg cloud "${cloud_uuid}" --arg n "az-$(echo ${item} | jq -c -r '.name')" \
    '{az_hosts: [{host_ids: [$hid], vcenter_ref: $vc}], cloud_ref: $cloud, name: $n}')
  log_only "waiting 10 seconds"
  sleep 10
  avi_api 2 2 POST "${az_json}" api/availabilityzone
  list_az_uuids=$(echo ${list_az_uuids} | jq -c --arg id "$(echo ${response_body} | jq -c -r '.uuid')" '. + [$id]')
done < <(echo ${response_body} | jq -c -r '.resource.nsxt_transportnodes[]')

avi_api 2 2 GET "" "api/serviceenginegroup?name=Default-Group&cloud_ref=${cloud_uuid}"
serviceenginegroup_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
seg_update_json=$(jq -n --argjson azs "$(echo ${list_az_uuids} | jq -c '.[-3:]')" \
  '{replace: {availability_zone_refs: $azs, cpu_reserve: false, mem_reserve: false, se_deprovision_delay: 120, buffer_se: 0, min_scaleout_per_vs: 1, algo: "PLACEMENT_ALGO_PACKED", ha_mode: "HA_MODE_SHARED", vcpus_per_se: 1, memory_per_se: 2048, disk_per_se: 15, realtime_se_metrics: {duration: 30, enable: false}}}')
avi_api 2 2 PATCH "${seg_update_json}" "api/serviceenginegroup/${serviceenginegroup_uuid}"

#
# Extra Service Engine Groups (spec.sddc.avi.service_engine_groups) - in
# addition to the Default-Group patched above. Mirrors the reference
# project's avi/configure_avi.sh "seg creation" section exactly: each
# entry's fields are passed through as-is, only cloud_ref is added.
# Optional - skipped entirely if unset/empty.
#
if [ -z "${service_engine_groups}" ] || [ "${service_engine_groups}" == "null" ] || [ "${service_engine_groups}" == "[]" ]; then
  log_only "skipping seg creation"
else
  while read -r item
  do
    json_data=$(echo ${item} | jq -c --arg cloud_url "${cloud_url}" '. + {cloud_ref: $cloud_url}')
    avi_api 2 2 POST "${json_data}" api/serviceenginegroup
  done < <(echo "${service_engine_groups}" | jq -c -r '.[]')
fi

#
# DNS VsVip + DNS virtual service, then wait for it to come up
#
vsvip_json=$(jq -n --arg cloud "${cloud_url}" --arg fqdn "dns.${avi_subdomain}.${domain}" --arg ref "/api/network/${vip_uuid}" \
  --arg addr "$(echo ${vip_cidr} | cut -d'/' -f1)" --arg mask "$(echo ${vip_cidr} | cut -d'/' -f2)" --arg vrf "/api/vrfcontext/?name=${t1_vip_name}" \
  '{cloud_ref: $cloud, dns_info: [{algorithm: "DNS_RECORD_RESPONSE_CONSISTENT_HASH", fqdn: $fqdn, ttl: 30, type: "DNS_RECORD_A"}],
    name: "dns-VsVip", vip: [{auto_allocate_ip: true, ipam_network_subnet: {network_ref: $ref, subnet: {ip_addr: {addr: $addr, type: "V4"}, mask: $mask}}}],
    vrf_context_ref: $vrf}')
avi_api 2 2 POST "${vsvip_json}" api/vsvip
vsvip_url=$(echo ${response_body} | jq -c -r '.url')
avi_api 2 2 POST "$(jq -n --arg cloud "${cloud_url}" --arg vsvip "${vsvip_url}" '{cloud_ref: $cloud, name: "dns-vs", vsvip_ref: $vsvip, application_profile_ref: "/api/applicationprofile/?name=System-DNS", network_profile_ref: "/api/networkprofile/?name=System-UDP-Per-Pkt", services: [{port: 53, enable_ssl: false}]}')" api/virtualservice

avi_api 2 2 GET "" api/systemconfiguration
avi_api 2 2 PUT "$(echo ${response_body} | jq -c '. + {dns_virtualservice_refs: ["/api/virtualservice/?name=dns-vs"]}')" api/systemconfiguration

count_dns=1 ; pause_dns=10 ; dns_vs_status=""
until [[ ${dns_vs_status} == "OPER_UP" ]]
do
  avi_api 2 2 GET "" api/virtualservice-inventory
  dns_vs_status=$(echo ${response_body} | jq -c -r '.results[0].runtime.oper_status.state')
  if [[ ${dns_vs_status} == "OPER_UP" ]]; then
    break
  fi
  sleep ${pause_dns}
  ((count_dns++))
  if [[ "${count_dns}" -eq 120 ]]; then
    log_notify "ERROR: Unable to get the DNS VS UP after ${count_dns} attempts of ${pause_dns} seconds"
    exit 100
  fi
done
log_notify "DNS VS UP after ${count_dns} attempts of ${pause_dns} seconds"

#
# demo traffic generator - adds loopback IPs to source synthetic client
# traffic from, and a cron job that spreads requests (with random user
# agents) across any virtual-hosted VS every minute.
#
cat > /home/ubuntu/avi/traffic_gen_client.sh <<TRAFFICGEN_EOF
#!/bin/bash
IFS=\$'\n'
username="admin"
password="${generic_password}"
ip="${ip_avi}"
rm -f /home/ubuntu/avi/avi_cookie.txt
amount_of_ip=\$(ip a show lo: | grep -v 127 | grep -v inet6 | grep inet | cut -d" " -f6 | cut -d"/" -f1 | wc -l)
amount_of_user_agent=\$(jq -c -r '. | length' /home/ubuntu/json/user_agents.json)
curl -s -k -X POST -H "Content-Type: application/json" -d "{\\"username\\": \\"\$username\\", \\"password\\": \\"\$password\\"}" -c /home/ubuntu/avi/avi_cookie.txt "https://\$ip/login" > /dev/null
curl_tenants=\$(curl -s -k -X GET -H "Content-Type: application/json" -b /home/ubuntu/avi/avi_cookie.txt "https://\$ip/api/tenant")
echo \$curl_tenants | jq -c -r '.results[].name' | while read tenant
do
  if [[ \$tenant != "admin" ]]; then
    curl_virtualservice=\$(curl -s -k -X GET -H "Content-Type: application/json" -H "X-Avi-Tenant: \$tenant" -b /home/ubuntu/avi/avi_cookie.txt "https://\$ip/api/virtualservice")
    if [[ \$(echo \$curl_virtualservice | jq -c -r '.results | length') -gt 0 ]] ; then
      for vs in \$(echo \$curl_virtualservice | jq -c -r .results[])
      do
        if [[ \$(echo \$vs | jq -c -r .type) == "VS_TYPE_VH_CHILD" ]] ; then
          for vh_match in \$(echo \$vs | jq -c -r .vh_matches[])
          do
            host=\$(echo \$vh_match | jq -c -r '.host')
            random_number=\$(( RANDOM % 45 + 1 ))
            for i in \$(seq 1 "\$random_number")
            do
              ip_index=\$(( RANDOM % amount_of_ip + 1 ))
              user_agent_index=\$(( RANDOM % amount_of_user_agent ))
              user_agent=\$(jq -c -r --arg i "\$user_agent_index" '.[\$i | tonumber]' /home/ubuntu/json/user_agents.json)
              ip_source=\$(ip a show lo: | grep -v 127 | grep -v inet6 | grep inet | cut -d" " -f6 | cut -d"/" -f1 | head -\$ip_index | tail +\$ip_index)
              curl --interface \$ip_source -A "\$user_agent" -k -o /dev/null "https://\$host"
              curl --interface \$ip_source -A "\$user_agent" -k -o /dev/null "http://\$host"
              sleep 0.5
            done
            for i in \$(seq 1 2)
            do
              ip_index=\$(( RANDOM % amount_of_ip + 1 ))
              user_agent_index=\$(( RANDOM % amount_of_user_agent ))
              user_agent=\$(jq -c -r --arg i "\$user_agent_index" '.[\$i | tonumber]' /home/ubuntu/json/user_agents.json)
              ip_source=\$(ip a show lo: | grep -v 127 | grep -v inet6 | grep inet | cut -d" " -f6 | cut -d"/" -f1 | head -\$ip_index | tail +\$ip_index)
              curl --interface \$ip_source -A "\$user_agent" -k -o /dev/null "https://\$host/wrong-path"
              sleep 0.5
            done
          done
        fi
      done
    fi
  fi
done
TRAFFICGEN_EOF
chmod u+x /home/ubuntu/avi/traffic_gen_client.sh

echo ${avi_loopback_ips} | jq -c -r . | tee /home/ubuntu/json/loopback_ips.json > /dev/null
echo ${avi_user_agents} | jq -c -r . | tee /home/ubuntu/json/user_agents.json > /dev/null
echo ${avi_loopback_ips} | jq -c -r '.[]' | while read -r lo_ip ; do sudo ip a add ${lo_ip} dev lo: ; done
(crontab -l 2>/dev/null; echo "* * * * * /home/ubuntu/avi/traffic_gen_client.sh") | crontab -
log_notify "Avi ctrl configured, traffic generator scheduled"

#
# Avi Controller upgrade (merged from the reference project's
# avi/upgrade_avi.sh) - entirely skipped if spec.sddc.avi.pkg_iso isn't
# set, since most deployments don't need one. Reuses ip_avi/avi_version/
# avi_login/avi_api from the configuration section just above instead of
# re-deriving them, since this now runs later in the same process.
#
if [ -z "${avi_pkg_filename}" ]; then
  log_only "sddc.avi.pkg_iso not set, skipping Avi upgrade check"
else
  # gw has no route to download this itself - gw-setup.sh.tpl already
  # copied it here at boot from the Iso CR referenced by
  # sddc.avi.pkg_iso, mounted as gw's CD-ROM (see
  # vapp_operator._ensure_gw_tools_media). If it's still missing, that
  # Iso's media didn't contain a file matching pkg_iso.file, or wasn't
  # attached at all - not something retrying here would fix.
  avi_pkg_file="/home/ubuntu/avi/${avi_pkg_filename}"
  if [ ! -f "${avi_pkg_file}" ]; then
    log_notify "ERROR: ${avi_pkg_file} not found - gw tools ISO was not attached or didn't contain this file"
    exit 100
  fi
  avi_login
  avi_api 2 2 GET "" api/version/controller "*"
  current_version=$(echo ${response_body} | jq -c -r '.[0].version' | cut -d")" -f1 | tr '(' '-')
  target_version=$(basename "${avi_pkg_filename}" .pkg | cut -d"-" -f2-3)
  if [[ ${current_version} == ${target_version} ]]; then
    log_notify "Avi upgrade not required (already ${current_version})"
  else
    log_notify "Avi upgrade required, from ${current_version} to ${target_version}"
    avi_api 2 2 POST "" api/image admin "${avi_pkg_file}"
    image_uuid=$(echo ${response_body} | jq -c -r '.uuid')
    sleep 10
    upgrade_json=$(jq -n --arg id "${image_uuid}" '{image_uuid: $id, system: true, skip_warnings: true, dryrun: false, prechecks_only: false, se_group_options: {action_on_error: "CONTINUE_UPGRADE_OPS_ON_ERROR"}}')
    avi_api 2 2 POST "${upgrade_json}" api/upgrade
    log_only "waiting 1200 seconds for Avi upgrade to apply"
    sleep 1200
    retry_avi_up=10 ; pause_avi_up=60 ; attempt_avi_up=1
    while true ; do
      http_code=$(curl -k -o /dev/null -s --write-out '%{http_code}' "https://${ip_avi}/api/initial-data")
      if [[ ${http_code} -eq 200 ]]; then
        log_only "Avi ctrl reachable again after upgrade"
        break
      fi
      ((attempt_avi_up++))
      if [ ${attempt_avi_up} -eq ${retry_avi_up} ]; then
        log_notify "ERROR: Avi ctrl not reachable after ${retry_avi_up} attempts of ${pause_avi_up} seconds post-upgrade"
        exit 100
      fi
      sleep ${pause_avi_up}
    done
    avi_login
    avi_api 2 2 GET "" api/upgradestatusinfo "*"
    failed_items=$(echo ${response_body} | jq -c --arg tv "${target_version}" '[.results[] | select(.version != null and (.version | startswith($tv)) and .state.state != "UPGRADE_FSM_COMPLETED")]')
    if [ "$(echo ${failed_items} | jq -c -r 'length')" -gt 0 ]; then
      log_notify "ERROR: Avi has not been upgraded to ${target_version}: ${failed_items}"
      exit 100
    else
      log_notify "Avi has been upgraded to ${target_version}"
    fi
  fi
fi

#
# NSX Project/VPC/Transit-Gateway setup (merged from the reference
# project's nsx/vpc_avi.sh) - despite the filename, the only Avi-specific
# action in that script (registering Avi via
# policy/api/v1/infra/alb-onboarding-workflow) is gated to 9.0/8.0U3b only
# and is dropped here, same 9.1-only scope as everywhere else in this
# script; what's left is pure NSX multi-tenancy setup, unrelated to the
# Avi cloud config done earlier (that uses the traditional flat
# CLOUD_NSXT integration, not this VPC/Project-scoped one). Reuses the
# nsx_get_object/nsx_set_object/nsx_retrieve_object_path/
# nsx_retrieve_object_id helpers already defined above for the NSX
# configuration section - no new HTTP helpers needed. Also skips the
# reference's own "wait for NSX Manager STABLE" re-check at the top of
# this section, since that was already confirmed long ago earlier in this
# same run.
#
while read -r item
do
  if [[ "$(echo ${item} | jq -r -c .project_ref)" == "default" ]]; then
    ib_name=$(echo ${item} | jq -c -r .name)
    nsx_set_object "policy/api/v1/infra/ip-blocks/${ib_name}" PATCH "$(jq -n --arg n "${ib_name}" --arg c "$(echo ${item} | jq -c -r .cidr)" --arg v "$(echo ${item} | jq -c -r .visibility)" '{display_name: $n, cidr: $c, visibility: $v}')"
  fi
done < <(echo ${nsx_config_ip_blocks} | jq -c -r '.[]')

while read -r item
do
  gwc_name=$(echo ${item} | jq -c -r .name)
  tier0_path=$(nsx_retrieve_object_path "policy/api/v1/infra/tier-0s" "$(echo ${item} | jq -c -r '.tier0_ref')")
  nsx_set_object "policy/api/v1/infra/gateway-connections/${gwc_name}" PUT "$(jq -n --arg t "${tier0_path}" --arg n "${gwc_name}" '{tier0_path: $t, display_name: $n}')"
done < <(echo ${nsx_config_gw_connections} | jq -c -r '.[]')

while read -r item
do
  proj_name=$(echo ${item} | jq -c -r .name)
  ip_block_external_path=$(nsx_retrieve_object_path "policy/api/v1/infra/ip-blocks" "$(echo ${item} | jq -c -r '.ip_block_ref')")
  tier0_path=$(nsx_retrieve_object_path "policy/api/v1/infra/tier-0s" "$(echo ${item} | jq -c -r '.tier0_ref')")
  edge_cluster_id=$(nsx_retrieve_object_id "api/v1/edge-clusters" "$(echo ${item} | jq -c -r '.edge_cluster_ref')")
  gw_connections_refs="[]"
  while read -r gwc_ref
  do
    gwc_path=$(nsx_retrieve_object_path "policy/api/v1/infra/gateway-connections" "${gwc_ref}")
    gw_connections_refs=$(echo ${gw_connections_refs} | jq -c --arg p "${gwc_path}" '. + [$p]')
  done < <(echo ${item} | jq -c -r '.gw_connections_refs[]')
  project_json=$(jq -n --arg ep "/infra/sites/default/enforcement-points/default/edge-clusters/${edge_cluster_id}" --arg t0 "${tier0_path}" \
    --argjson gwc "${gw_connections_refs}" --arg ipb "${ip_block_external_path}" --arg n "${proj_name}" \
    '{site_infos: [{edge_cluster_paths: [$ep], site_path: "/infra/sites/default"}], tier_0s: [$t0], tgw_external_connections: $gwc, external_ipv4_blocks: [$ipb], activate_default_dfw_rules: false, display_name: $n}')
  nsx_set_object "policy/api/v1/orgs/default/projects/${proj_name}" PATCH "${project_json}"
done < <(echo ${nsx_config_projects} | jq -c -r '.[]')

# Known rough edge, per the reference project's own captured error log:
# this call fails with HTTP 400 ("Parent ... does not exist. Please first
# create the parent with id default.") for any non-default project unless
# NSX has already set up that project's default transit gateway on its
# own - not something this port works around, just carried over as-is.
while read -r item
do
  gwc_ref=$(echo ${item} | jq -c -r .gw_connection_ref)
  proj_ref=$(echo ${item} | jq -c -r .project_ref)
  tgw_name=$(echo ${item} | jq -c -r .name)
  gwc_path=$(nsx_retrieve_object_path "policy/api/v1/infra/gateway-connections" "${gwc_ref}")
  nsx_set_object "policy/api/v1/orgs/default/projects/${proj_ref}/transit-gateways/${tgw_name}/attachments/${gwc_ref}" PATCH "$(jq -n --arg p "${gwc_path}" --arg n "${gwc_ref}" '{connection_path: $p, display_name: $n}')"
done < <(echo ${nsx_config_transit_gateways} | jq -c -r '.[]')

# ip-block creation for non-default projects - only the inter-VPC transit
# gateway CIDR (scope vpc_tgw) gets created under each project this way.
while read -r item
do
  proj_ref=$(echo ${item} | jq -r -c .project_ref)
  scope=$(echo ${item} | jq -r -c .scope)
  if [[ "${proj_ref}" != "default" && "${proj_ref}" != "null" && "${scope}" == "vpc_tgw" ]]; then
    project_id=$(nsx_retrieve_object_id "policy/api/v1/orgs/default/projects" "${proj_ref}")
    ib_name=$(echo ${item} | jq -c -r .name)
    nsx_set_object "policy/api/v1/orgs/default/projects/${project_id}/infra/ip-blocks/${ib_name}" PATCH "$(jq -n --arg n "${ib_name}" --arg c "$(echo ${item} | jq -c -r .cidr)" --arg v "$(echo ${item} | jq -c -r .visibility)" '{display_name: $n, cidr: $c, visibility: $v}')"
  fi
done < <(echo ${nsx_config_ip_blocks} | jq -c -r '.[]')

while read -r item
do
  vcp_name=$(echo ${item} | jq -c -r .name)
  proj_ref=$(echo ${item} | jq -c -r .project_ref)

  external_ip_block_refs_paths="[]"
  while read -r ref
  do
    p=$(nsx_retrieve_object_path "policy/api/v1/infra/ip-blocks" "${ref}")
    external_ip_block_refs_paths=$(echo ${external_ip_block_refs_paths} | jq -c --arg p "${p}" '. + [$p]')
  done < <(echo ${item} | jq -c -r '.external_ip_block_refs[]')

  edge_cluster_refs_path="[]"
  while read -r ref
  do
    eid=$(nsx_retrieve_object_id "api/v1/edge-clusters" "${ref}")
    edge_cluster_refs_path=$(echo ${edge_cluster_refs_path} | jq -c --arg p "/infra/sites/default/enforcement-points/default/edge-clusters/${eid}" '. + [$p]')
  done < <(echo ${item} | jq -c -r '.edge_cluster_refs[]')

  if [[ "${proj_ref}" == "default" ]]; then
    ipb_endpoint="policy/api/v1/infra/ip-blocks"
  else
    ipb_endpoint="policy/api/v1/orgs/default/projects/${proj_ref}/infra/ip-blocks"
  fi
  private_tgw_ip_block_refs_path="[]"
  while read -r ref
  do
    p=$(nsx_retrieve_object_path "${ipb_endpoint}" "${ref}")
    private_tgw_ip_block_refs_path=$(echo ${private_tgw_ip_block_refs_path} | jq -c --arg p "${p}" '. + [$p]')
  done < <(echo ${item} | jq -c -r '.private_tgw_ip_block_refs[]')

  vcp_json=$(jq -n --arg tgp "/orgs/default/projects/${proj_ref}/transit-gateways/default" \
    --argjson eib "${external_ip_block_refs_paths}" --argjson ptib "${private_tgw_ip_block_refs_path}" \
    --argjson ecp "${edge_cluster_refs_path}" --arg n "${vcp_name}" \
    '{transit_gateway_path: $tgp, external_ip_blocks: $eib, is_default: true, private_tgw_ip_blocks: $ptib,
      service_gateway: {enable: true, nat_config: {enable_default_snat: true}, edge_cluster_paths: $ecp}, display_name: $n}')
  nsx_set_object "policy/api/v1/orgs/default/projects/${proj_ref}/vpc-connectivity-profiles/${vcp_name}" PUT "${vcp_json}"
done < <(echo ${nsx_config_vpc_connectivity_profiles} | jq -c -r '.[]')

while read -r item
do
  vsp_name=$(echo ${item} | jq -c -r .name)
  proj_ref=$(echo ${item} | jq -c -r .project_ref)
  vsp_json=$(jq -n --arg n "${vsp_name}" --arg dns "${ip_gw}" \
    '{display_name: $n, is_default: true, dhcp_config: {dhcp_server_config: {dns_client_config: {dns_server_ips: [$dns]}, lease_time: 86400, ntp_servers: [$dns], advanced_config: {is_distributed_dhcp: true}}}}')
  nsx_set_object "policy/api/v1/orgs/default/projects/${proj_ref}/vpc-service-profiles/${vsp_name}" PUT "${vsp_json}"
done < <(echo ${nsx_config_vpc_service_profiles} | jq -c -r '.[]')

while read -r item
do
  vpc_name=$(echo ${item} | jq -c -r .name)
  proj_ref=$(echo ${item} | jq -c -r .project_ref)

  private_ips="[]"
  while read -r ref
  do
    cidr=$(echo ${nsx_config_ip_blocks} | jq -c -r --arg arg "${ref}" '.[] | select( .name == $arg).cidr')
    private_ips=$(echo ${private_ips} | jq -c --arg c "${cidr}" '. + [$c]')
  done < <(echo ${item} | jq -c -r '.private_ips_refs[]')

  vpc_service_profile_path=$(nsx_retrieve_object_path "policy/api/v1/orgs/default/projects/${proj_ref}/vpc-service-profiles" "$(echo ${item} | jq -c -r .vpc_service_profile_ref)")
  nsx_set_object "policy/api/v1/orgs/default/projects/${proj_ref}/vpcs/${vpc_name}" PUT "$(jq -n --arg vsp "${vpc_service_profile_path}" --argjson pi "${private_ips}" --arg n "${vpc_name}" '{vpc_service_profile: $vsp, load_balancer_vpc_endpoint: {enabled: true}, private_ips: $pi, display_name: $n}')"

  vpc_connectivity_profile_path=$(nsx_retrieve_object_path "policy/api/v1/orgs/default/projects/${proj_ref}/vpc-connectivity-profiles" "$(echo ${item} | jq -c -r .connectivity_profile_ref)")
  nsx_set_object "policy/api/v1/orgs/default/projects/${proj_ref}/vpcs/${vpc_name}/attachments/$(echo ${item} | jq -c -r .connectivity_profile_ref)" PUT "$(jq -n --arg p "${vpc_connectivity_profile_path}" '{vpc_connectivity_profile: $p}')"
done < <(echo ${nsx_config_vpcs} | jq -c -r '.[]')

log_notify "NSX Project/VPC setup complete"

#
# vSAN health alarm silencing (merged from the reference project's
# vcenter/silent_alarm.sh + templates/silence_vsan_expect_script.sh.template)
# - needed for Tanzu/Supervisor enablement, which checks vSAN health as a
# prerequisite and would otherwise flag/block on checks a NESTED vSAN can
# never pass (controller driver/firmware/HCL support are meaningless for
# virtualized disk controllers). Retargeted from the reference's "outer
# host vCenter" (a vCenter/govc-managed physical layer this project has no
# equivalent of - everything outer-layer here is VCD-managed) to OUR own
# nested vCenter instead, which has exactly the same class of vSAN alarm
# noise. Also fixes what looks like a bug in the reference's own SSH
# invocation - it embeds a password directly into the ssh destination
# argument ("user@domain:password@host", not valid SSH syntax, and
# redundant anyway since the very next expect step still waits for an
# interactive password prompt) - with a clean `-l` username instead. The
# later `rvc user:password@host` line keeps that embedded-password form
# (RVC's own real, documented login syntax, not ssh's), but the password
# itself needs single-quoting there - confirmed live: this project's
# generic_password contains "!", and bash's interactive history expansion
# (the shell this gets typed into, via "pi shell") treats an unquoted "!"
# as a history-substitution trigger ("event not found"), silently
# preventing rvc from ever launching and leaving every subsequent
# vsan.health.silent_health_check_configure command typed into a bare
# bash prompt instead of rvc's. The reference project's own template
# already single-quotes the password for exactly this reason - this port
# had dropped those quotes.
#
export VC_ROOT_PASSWORD="${generic_password}"
export VC_SSO_USER="administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)"
export VC_HOST="${basename_sddc}-vc01.${domain}"
export VC_DC="${basename_sddc}-dc"
export VC_CLUSTER="${basename_sddc}-cluster"
expect <<'VSAN_EXPECT_EOF'
set timeout 60
set password $env(VC_ROOT_PASSWORD)
spawn ssh -tt -o StrictHostKeyChecking=no -l $env(VC_SSO_USER) $env(VC_HOST)
expect "assword:" { send "$password\r" }
expect "and>" { send "com.vmware.appliance.version1.access.shell.set --enabled true\r" }
expect "and> " { send "shell\r" }
expect " ]$ " { send "rvc $env(VC_SSO_USER):'$password'@$env(VC_HOST) -a -q\r" }
expect "> " { send "vsan.health.silent_health_check_configure -a controllerdriver $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a controllerdiskmode $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a controllerfirmware $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a controllerreleasesupport $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a controlleronhcl $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a upgradelowerhosts $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "vsan.health.silent_health_check_configure -a perfsvcstatus $env(VC_HOST)/$env(VC_DC)/computers/$env(VC_CLUSTER)\n" }
expect "> " { send "exit\n" }
expect " ]$ " { send "exit\n" }
expect "and> " { send "exit\n" }
expect eof
VSAN_EXPECT_EOF
unset VC_ROOT_PASSWORD VC_SSO_USER VC_HOST VC_DC VC_CLUSTER
log_notify "vSAN health alarm silencing applied on ${basename_sddc}-vc01.${domain}"

#
# Supervisor (Tanzu) cluster enablement (merged from the reference
# project's supervisor/configure_supervisor.sh - applies to both 9.0 and
# 9.1 there, so no version branch to drop here). Chains directly off
# earlier work in this same script: workloads.network below uses NSX_VPC
# mode against the "default" project / vpc_connectivity_profile-default
# the NSX Project/VPC section already created, and authenticates via the
# vcf CLI staged from the gw tools ISO. Reuses create_vcenter_api_session/
# vcenter_api from the NSX configuration section above (already targeting
# our nested vCenter) - re-authenticating before each call, matching the
# reference's own defensive pattern, since the 600-second wait partway
# through risks the session expiring.
#
mkdir -p /home/ubuntu/supervisor
create_vcenter_api_session
vcenter_api 6 10 GET "rest/vcenter/datastore" ""
datastore_id=$(echo ${response_body} | jq -c -r --arg arg "${basename_sddc}-vsan" '.value[] | select(.name == $arg) | .datastore')
supervisor_cm_thumbprint=$(openssl s_client -connect "$(echo ${content_library_subscription_url} | cut -d'/' -f3):443" < /dev/null 2>/dev/null | openssl x509 -fingerprint -noout -in /dev/stdin | awk -F'Fingerprint=' '{print $2}')
cl_json=$(jq -n --arg ds "${datastore_id}" --arg tp "${supervisor_cm_thumbprint}" --arg url "${content_library_subscription_url}" \
  '{storage_backings: [{datastore_id: $ds, type: "DATASTORE"}], type: "SUBSCRIBED", version: "2",
    subscription_info: {authentication_method: "NONE", ssl_thumbprint: $tp, automatic_sync_enabled: "true", subscription_url: $url, on_demand: "true"},
    name: "content_library_supervisor"}')
create_vcenter_api_session
vcenter_api 3 3 POST "api/content/subscribed-library" "${cl_json}"

create_vcenter_api_session
vcenter_api 3 3 GET "api/vcenter/cluster" ""
cluster_id=$(echo ${response_body} | jq -r --arg cluster "${basename_sddc}-cluster" '.[] | select(.name == $cluster).cluster')

create_vcenter_api_session
vcenter_api 3 3 GET "api/vcenter/storage/policies" ""
storage_policy_id=$(echo ${response_body} | jq -r --arg policy "${supervisor_cluster_storage_policy_ref}" '.[] | select(.name == $policy) | .policy')

create_vcenter_api_session
vcenter_api 3 3 GET "api/vcenter/network" ""
network_supervisor_management=$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).display_name')
network_id=$(echo ${response_body} | jq -r --arg pg "${network_supervisor_management}" '.[] | select(.name == $pg).network')

supervisor_json=$(jq -n \
  --argjson count 1 \
  --arg banner "${supervisor_cluster_name}-banner" \
  --arg network_id "${network_id}" \
  --arg gw_addr "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).gateway_address')" \
  --arg start_ip "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).supervisor_starting_ip')" \
  --argjson ip_count "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).supervisor_count')" \
  --arg domain "${domain}" --arg dns "${ip_gw}" \
  --arg size "${supervisor_cluster_size}" --arg storage_policy "${storage_policy_id}" \
  --arg name "${supervisor_cluster_name}" \
  --arg svc_addr "${supervisor_cluster_service_address}" --argjson svc_count "${supervisor_cluster_service_address_count}" \
  --arg vpc_project "/orgs/default/projects/${supervisor_cluster_project_ref}" \
  --arg vpc_profile "/orgs/default/projects/${supervisor_cluster_project_ref}/vpc-connectivity-profiles/${supervisor_cluster_vpc_profile}" \
  --arg vpc_cidr_addr "${supervisor_cluster_vpc_private_cidr_address}" --argjson vpc_cidr_prefix "${supervisor_cluster_vpc_private_cidr_prefix}" \
  '{
    control_plane: {
      count: $count,
      login_banner: $banner,
      network: {
        backing: {backing: "NETWORK_SEGMENT", network_segment: {networks: [$network_id]}},
        ip_management: {dhcp_enabled: false, gateway_address: $gw_addr, ip_assignments: [{assignee: "NODE", ranges: [{address: $start_ip, count: $ip_count}]}]},
        network: "managementnetwork0",
        proxy: {proxy_settings_source: "VC_INHERITED"},
        services: {dns: {search_domains: [$domain], servers: [$dns]}, ntp: {servers: [$dns]}}
      },
      size: $size,
      storage_policy: $storage_policy
    },
    name: $name,
    workloads: {
      edge: {provider: "NSX_VPC"},
      network: {
        ip_management: {dhcp_enabled: false, gateway_address: "", ip_assignments: [{assignee: "SERVICE", ranges: [{address: $svc_addr, count: $svc_count}]}]},
        network: "workloadnetwork0",
        network_type: "NSX_VPC",
        nsx_vpc: {default_private_cidrs: [{address: $vpc_cidr_addr, prefix: $vpc_cidr_prefix}], nsx_project: $vpc_project, vpc_connectivity_profile: $vpc_profile},
        services: {dns: {search_domains: [$domain], servers: [$dns]}, ntp: {servers: [$dns]}}
      },
      storage: {ephemeral_storage_policy: $storage_policy, image_storage_policy: $storage_policy}
    }
  }')
create_vcenter_api_session
vcenter_api 3 3 POST "api/vcenter/namespace-management/supervisors/${cluster_id}?action=enable_on_compute_cluster" "${supervisor_json}"
log_notify "Supervisor cluster enablement started"
log_only "waiting 600 seconds"
sleep 600

retry_supervisor=121 ; pause_supervisor=60 ; attempt_supervisor=1
while true ; do
  create_vcenter_api_session
  vcenter_api 3 3 GET "api/vcenter/namespace-management/clusters" ""
  config_status=$(echo ${response_body} | jq -c -r '.[0].config_status')
  k8s_status=$(echo ${response_body} | jq -c -r '.[0].kubernetes_status')
  if [[ "${config_status}" == "RUNNING" && "${k8s_status}" == "READY" ]]; then
    log_notify "Supervisor config_status ${config_status}, kubernetes_status ${k8s_status} after ${attempt_supervisor} attempts of ${pause_supervisor} seconds"
    break
  fi
  ((attempt_supervisor++))
  if [ ${attempt_supervisor} -eq ${retry_supervisor} ]; then
    log_notify "ERROR: Supervisor not RUNNING/READY after ${attempt_supervisor} attempts of ${pause_supervisor} seconds (config_status=${config_status}, kubernetes_status=${k8s_status})"
    exit 100
  fi
  sleep ${pause_supervisor}
done

create_vcenter_api_session
vcenter_api 3 3 GET "api/vcenter/namespace-management/clusters" ""
cluster_id=$(echo ${response_body} | jq -c -r .[0].cluster)
create_vcenter_api_session
vcenter_api 3 3 GET "api/vcenter/namespace-management/clusters/${cluster_id}" ""
api_server_cluster_endpoint=$(echo ${response_body} | jq -c -r .api_server_cluster_endpoint)
if [ -z "${api_server_cluster_endpoint}" ] || [ "${api_server_cluster_endpoint}" == "null" ]; then
  log_notify "ERROR: Supervisor api_server_cluster_endpoint is undefined or null"
  exit 100
fi

# Note: the reference project has a real inconsistency here - this first
# vcf context create uses a bare endpoint (no scheme) while
# auth_vks_context.sh below (also the reference's own) hardcodes
# "https://" in front of the same field. Confirmed live against a real
# VCF 9.1 Supervisor cluster: the bare endpoint works fine here (vcf
# logs in successfully and auto-discovers every context), so this isn't
# a bug worth resolving - both forms are apparently accepted.
export VCF_CLI_VSPHERE_PASSWORD="${generic_password}"
vcf context create "${supervisor_cluster_name}" --auth-type basic --username "administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)" --endpoint="${api_server_cluster_endpoint}" --insecure-skip-tls-verify
unset VCF_CLI_VSPHERE_PASSWORD

cat > /home/ubuntu/supervisor/auth_supervisor_custer.sh <<AUTH_SUP_EOF
#!/bin/bash
export VCF_CLI_VSPHERE_PASSWORD='${generic_password}'
vcf context use ${supervisor_cluster_name}
kubectl config use-context ${supervisor_cluster_name}
AUTH_SUP_EOF
chmod u+x /home/ubuntu/supervisor/auth_supervisor_custer.sh

# Quoted heredoc (no substitution at all) + a targeted sed pass, matching
# the reference's own sed-templated-file approach exactly - safer here
# than inline heredoc interpolation, since this generated script has its
# own $1/$2/${ns}/${cluster_name} that must survive completely untouched
# for when it's actually run later.
cat > /tmp/auth_vks_context.sh.template <<'AUTH_VKS_TEMPLATE_EOF'
#!/bin/bash
show_help() {
    cat << HELP_EOF
Usage: $0 <namespace> <cluster_name>

This script requires two arguments:
  $1  - namespace: The namespace to use
  $2  - cluster_name: The cluster name to use

Options:
  -h, --help    Show this help message and exit

Examples:
  $0 my-namespace my-cluster
HELP_EOF
}

if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
    exit 0
fi

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Error: Missing required arguments" >&2
    echo ""
    show_help
    exit 1
fi

ns="${1}"
cluster_name="${2}"
export VCF_CLI_VSPHERE_PASSWORD='${generic_password}'

guest_context="${ns}:${cluster_name}:${cluster_name}"

if [[ $(vcf context list -o json | jq -c -r --arg arg "${guest_context}" '[.[] | select( .name == $arg)] | if length > 0 then .[0] else null end') == "null" ]] ; then
  vcf context create "${ns}:${cluster_name}" --type k8s --auth-type basic --endpoint=https://${api_server_cluster_endpoint} --username administrator@${ssoDomain} --workload-cluster-name "${cluster_name}" --workload-cluster-namespace "${ns}" --insecure-skip-tls-verify
  vcf context use "${guest_context}" --insecure-skip-tls-verify
  kubectl config set-context --current --namespace=default
  kubectl config use-context "${guest_context}"
else
  vcf context use "${guest_context}" --insecure-skip-tls-verify
  kubectl config set-context --current --namespace=default
  kubectl config use-context "${guest_context}"
fi
AUTH_VKS_TEMPLATE_EOF
sed -e "s/\${generic_password}/${generic_password}/" \
    -e "s/\${api_server_cluster_endpoint}/${api_server_cluster_endpoint}/" \
    -e "s/\${ssoDomain}/$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)/" \
    /tmp/auth_vks_context.sh.template > /home/ubuntu/supervisor/auth_vks_context.sh
rm -f /tmp/auth_vks_context.sh.template
chmod u+x /home/ubuntu/supervisor/auth_vks_context.sh

# vcfa_select_ns.sh / vcfa_select_vks_cluster.sh - interactive discovery
# scripts (browse org -> supervisor namespace -> VKS cluster via VCF
# Automation's provider API, then connect) - ported from the reference
# project's templates/vcfa_select_ns.sh.template and
# templates/vcfa_select_vks_cluster.sh.template verbatim. Same quoted-
# heredoc + targeted sed pattern as auth_vks_context.sh above, for the
# same reason - these generated scripts have their own $1/$2/${ns}/
# ${cluster_name}/etc that must survive completely untouched.
cat > /tmp/vcfa_select_vks_cluster.sh.template <<'VCFA_SELECT_VKS_TEMPLATE_EOF'
#!/bin/bash
#
# Logs into a VKS Kubernetes cluster via the vcf CLI. The namespace and
# cluster name can either be given directly, or discovered by browsing VCF
# Automation in provider mode (org -> supervisor namespace -> VKS cluster).
#
# Discovery auth uses the programmatic token-generation flow (provider bearer
# token -> org-scoped OAuth token via jwt-bearer exchange), not a service
# account: https://vrealize.it/2025/12/04/vcf-automation-9-programmatic-token-generation/
#
set -euo pipefail

show_help() {
    cat << EOF
Usage: $0 [<namespace> <cluster_name>]
       $0 [-H host] [-u username]

With <namespace> and <cluster_name> given directly, connects straight to that
VKS cluster. With no positional arguments, browses VCF Automation (provider
mode) to pick an org, a supervisor namespace, and a VKS cluster interactively,
then connects to the selection.

Options:
  -H, --host HOST        VCF Automation FQDN/URL, used only for discovery
                          (default: \$VCFA_HOST or https://sddc01-auto-vip.vcf9.lab)
  -u, --username USER    Provider username, used only for discovery
                          (default: \$VCFA_USERNAME or admin)
  -h, --help             Show this help message and exit

Discovery password is read from \$VCFA_PASSWORD if set, otherwise prompted for.

Examples:
  $0 my-namespace my-cluster     # skip discovery, connect directly
  $0                              # browse org/namespace/cluster interactively
EOF
}

HOST="https://${fqdn_vcfa}"
USERNAME="${VCFA_USERNAME:-admin}"
VCFA_PASSWORD='${generic_password}'
POSITIONAL=()

while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host) HOST="$2"; shift 2 ;;
        -u|--username) USERNAME="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        -*) echo "Unknown argument: $1" >&2; show_help; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

# Prompts among multiple choices; auto-selects if there's only one.
# Usage: prompt_choice "Prompt text" "${array[@]}" ; result left in CHOICE
prompt_choice() {
    local prompt="$1"; shift
    local -a options=("$@")
    if [ "${#options[@]}" -eq 0 ]; then
        echo "Error: no options available for: $prompt" >&2
        exit 1
    fi
    if [ "${#options[@]}" -eq 1 ]; then
        CHOICE="${options[0]}"
        echo "$prompt -> only one option, auto-selected: $CHOICE" >&2
        return
    fi
    echo "$prompt" >&2
    local PS3="Select a number: "
    select opt in "${options[@]}"; do
        if [ -n "${opt:-}" ]; then
            CHOICE="$opt"
            break
        fi
        echo "Invalid selection, try again." >&2
    done
}

# Browses VCF Automation (provider mode) and sets ns/cluster_name from the
# selected org/namespace/cluster.
discover_namespace_and_cluster() {
    for cmd in curl jq base64; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required but not installed." >&2; exit 1; }
    done

    if [ -n "${VCFA_PASSWORD:-}" ]; then
        local password="$VCFA_PASSWORD"
    else
        read -rsp "Password for ${USERNAME}@${HOST}: " password
        echo >&2
    fi

    local accept="Accept: application/json;version=9.0.0"

    echo "Logging in to ${HOST} as provider..." >&2
    local creds provider_resp provider_token client_id
    creds=$(printf '%s@system:%s' "$USERNAME" "$password" | base64 -w0)
    provider_resp=$(curl -sk -i -X POST "${HOST}/cloudapi/1.0.0/sessions/provider" \
        -H "$accept" \
        -H "Content-Type: application/json;version=9.0.0" \
        -H "Authorization: Basic ${creds}")

    provider_token=$(printf '%s' "$provider_resp" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
    if [ -z "$provider_token" ]; then
        echo "Error: provider login failed. Response:" >&2
        printf '%s\n' "$provider_resp" >&2
        exit 1
    fi

    client_id=$(curl -sk "${HOST}/cloudapi/1.0.0/openIdProvider/relyingParties" \
        -H "$accept" \
        -H "Authorization: Bearer ${provider_token}" \
        | jq -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
    if [ -z "$client_id" ] || [ "$client_id" == "null" ]; then
        echo "Error: could not determine the automation relying party clientId." >&2
        exit 1
    fi

    # "System" is the built-in provider bucket, not a real tenant org - exclude it.
    local org_lines org_names org_urn org_uuid selected_org
    readarray -t org_lines < <(curl -sk "${HOST}/cloudapi/1.0.0/orgs" \
        -H "$accept" \
        -H "Authorization: Bearer ${provider_token}" \
        | jq -r '.values[] | select(.name != "System") | "\(.name)\t\(.id)"')
    if [ "${#org_lines[@]}" -eq 0 ]; then
        echo "Error: no organizations found." >&2
        exit 1
    fi
    org_names=()
    for line in "${org_lines[@]}"; do org_names+=("${line%%$'\t'*}"); done

    prompt_choice "Available organizations:" "${org_names[@]}"
    selected_org="$CHOICE"
    for line in "${org_lines[@]}"; do
        if [ "${line%%$'\t'*}" == "$selected_org" ]; then
            org_urn="${line##*$'\t'}"
            break
        fi
    done
    org_uuid="${org_urn##*:}"

    echo "Requesting org-scoped token for '${selected_org}'..." >&2
    local org_token
    org_token=$(curl -sk -X POST "${HOST}/oidc/oauth2/token" \
        -H "$accept" \
        -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${provider_token}" \
        --data-urlencode "client_id=${client_id}" \
        | jq -r '.access_token')
    if [ -z "$org_token" ] || [ "$org_token" == "null" ]; then
        echo "Error: failed to obtain an org-scoped token for ${selected_org}." >&2
        exit 1
    fi

    local namespace_lines namespaces namespace_urn
    readarray -t namespace_lines < <(curl -sk "${HOST}/cci/kubernetes/apis/infrastructure.cci.vmware.com/v1alpha3/supervisornamespaces?limit=500" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${org_token}" \
        | jq -r '.items[] | "\(.metadata.name)\t\(.metadata.annotations["infrastructure.cci.vmware.com/id"])"')
    if [ "${#namespace_lines[@]}" -eq 0 ]; then
        echo "Error: no supervisor namespaces found in org '${selected_org}'." >&2
        exit 1
    fi
    namespaces=()
    for line in "${namespace_lines[@]}"; do namespaces+=("${line%%$'\t'*}"); done

    prompt_choice "Available namespaces in org '${selected_org}':" "${namespaces[@]}"
    ns="$CHOICE"
    for line in "${namespace_lines[@]}"; do
        if [ "${line%%$'\t'*}" == "$ns" ]; then
            namespace_urn="${line##*$'\t'}"
            break
        fi
    done

    local clusters
    readarray -t clusters < <(curl -sk "${HOST}/proxy/k8s/namespaces/${namespace_urn}/apis/cluster.x-k8s.io/v1beta2/namespaces/${ns}/clusters?limit=500" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${org_token}" \
        | jq -r '.items[].metadata.name')
    if [ "${#clusters[@]}" -eq 0 ]; then
        echo "Error: no Kubernetes clusters found in namespace '${ns}'." >&2
        exit 1
    fi

    prompt_choice "Available Kubernetes clusters in namespace '${ns}':" "${clusters[@]}"
    cluster_name="$CHOICE"
}

if [ "${#POSITIONAL[@]}" -eq 2 ]; then
    ns="${POSITIONAL[0]}"
    cluster_name="${POSITIONAL[1]}"
elif [ "${#POSITIONAL[@]}" -eq 0 ]; then
    discover_namespace_and_cluster
else
    echo "Error: expected either 0 or 2 positional arguments (namespace, cluster_name)." >&2
    show_help
    exit 1
fi

echo "Connecting to namespace '${ns}', cluster '${cluster_name}'..." >&2
export VCF_CLI_VSPHERE_PASSWORD='${generic_password}'

# vcf context create derives a namespace context named "${ns}:${cluster_name}" and,
# as a related child context, the actual guest/VKS cluster context named
# "${ns}:${cluster_name}:${cluster_name}" - the latter is what we want to log into.
guest_context="${ns}:${cluster_name}:${cluster_name}"

if [[ $(vcf context list -o json | jq -c -r --arg arg "${guest_context}" '[.[] | select( .name == $arg)] | if length > 0 then .[0] else null end') == "null" ]] ; then
  vcf context create "${ns}:${cluster_name}" --type k8s --auth-type basic --endpoint=https://${api_server_cluster_endpoint} --username administrator@vsphere.local --workload-cluster-name "${cluster_name}" --workload-cluster-namespace "${ns}" --insecure-skip-tls-verify
  # vcf context use can exit non-zero on a benign Harbor plugin-discovery
  # warning even after successfully activating the context - don't abort on it.
  vcf context use "${guest_context}" --insecure-skip-tls-verify || true
  kubectl config set-context --current --namespace=default
  kubectl config use-context "${guest_context}"
else
  # vcf context use can exit non-zero on a benign Harbor plugin-discovery
  # warning even after successfully activating the context - don't abort on it.
  vcf context use "${guest_context}" --insecure-skip-tls-verify || true
  kubectl config set-context --current --namespace=default
  kubectl config use-context "${guest_context}"
fi
VCFA_SELECT_VKS_TEMPLATE_EOF
sed -e "s/\${generic_password}/${generic_password}/" \
    -e "s/\${fqdn_vcfa}/${fqdn_vcfa}/" \
    -e "s/\${api_server_cluster_endpoint}/${api_server_cluster_endpoint}/" \
    /tmp/vcfa_select_vks_cluster.sh.template > /home/ubuntu/supervisor/vcfa_select_vks_cluster.sh
rm -f /tmp/vcfa_select_vks_cluster.sh.template
chmod u+x /home/ubuntu/supervisor/vcfa_select_vks_cluster.sh

cat > /tmp/vcfa_select_ns.sh.template <<'VCFA_SELECT_NS_TEMPLATE_EOF'
#!/bin/bash
#
# Browses VCF Automation in provider mode, lets you pick an org and a
# supervisor namespace within it, then assigns the chosen namespace to the
# variable "namespace" (auto-assigned if there's only one).
#
# Auth uses the programmatic token-generation flow (provider bearer token ->
# org-scoped OAuth token via jwt-bearer exchange), not a service account:
# https://vrealize.it/2025/12/04/vcf-automation-9-programmatic-token-generation/
#
set -euo pipefail

show_help() {
    cat << EOF
Usage: $0 [-H host] [-u username]

Browses VCF Automation (provider mode) to pick an org and a supervisor
namespace interactively (auto-selecting when there's only one option), then
assigns the result to the variable "namespace". Run with 'source $0' if you
want "namespace" to persist in your current shell.

Options:
  -H, --host HOST        VCF Automation FQDN/URL (default: \$VCFA_HOST or https://sddc01-auto-vip.vcf9.lab)
  -u, --username USER    Provider username (default: \$VCFA_USERNAME or admin)
  -h, --help             Show this help message and exit

Password is read from \$VCFA_PASSWORD if set, otherwise prompted for.
EOF
}

HOST="https://${fqdn_vcfa}"
USERNAME="${VCFA_USERNAME:-admin}"
VCFA_PASSWORD='${generic_password}'

# Files to update, paired with the jq path of the key to set in each.
NAMESPACE_UPDATE_FILES=(
    /home/ubuntu/yaml-files/secret_vault.yaml
    /home/ubuntu/yaml-files/vault_issuer.yaml
)
NAMESPACE_UPDATE_JQ_PATHS=(
    .metadata.namespace
    .metadata.namespace
)


while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host) HOST="$2"; shift 2 ;;
        -u|--username) USERNAME="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; show_help; exit 1 ;;
    esac
done

for cmd in curl jq base64; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required but not installed." >&2; exit 1; }
done

if [ -n "${VCFA_PASSWORD:-}" ]; then
    PASSWORD="$VCFA_PASSWORD"
else
    read -rsp "Password for ${USERNAME}@${HOST}: " PASSWORD
    echo
fi

ACCEPT="Accept: application/json;version=9.0.0"

# Prompts among multiple choices; auto-selects if there's only one.
# Usage: prompt_choice "Prompt text" "${array[@]}" ; result left in CHOICE
prompt_choice() {
    local prompt="$1"; shift
    local -a options=("$@")
    if [ "${#options[@]}" -eq 0 ]; then
        echo "Error: no options available for: $prompt" >&2
        exit 1
    fi
    if [ "${#options[@]}" -eq 1 ]; then
        CHOICE="${options[0]}"
        echo "$prompt -> only one option, auto-selected: $CHOICE" >&2
        return
    fi
    echo "$prompt" >&2
    local PS3="Select a number: "
    select opt in "${options[@]}"; do
        if [ -n "${opt:-}" ]; then
            CHOICE="$opt"
            break
        fi
        echo "Invalid selection, try again." >&2
    done
}

echo "Logging in to ${HOST} as provider..." >&2
CREDS=$(printf '%s@system:%s' "$USERNAME" "$PASSWORD" | base64 -w0)
PROVIDER_RESP=$(curl -sk -i -X POST "${HOST}/cloudapi/1.0.0/sessions/provider" \
    -H "$ACCEPT" \
    -H "Content-Type: application/json;version=9.0.0" \
    -H "Authorization: Basic ${CREDS}")

PROVIDER_TOKEN=$(printf '%s' "$PROVIDER_RESP" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
if [ -z "$PROVIDER_TOKEN" ]; then
    echo "Error: provider login failed. Response:" >&2
    printf '%s\n' "$PROVIDER_RESP" >&2
    exit 1
fi

CLIENT_ID=$(curl -sk "${HOST}/cloudapi/1.0.0/openIdProvider/relyingParties" \
    -H "$ACCEPT" \
    -H "Authorization: Bearer ${PROVIDER_TOKEN}" \
    | jq -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" == "null" ]; then
    echo "Error: could not determine the automation relying party clientId." >&2
    exit 1
fi

# "System" is the built-in provider bucket, not a real tenant org - exclude it.
readarray -t ORG_LINES < <(curl -sk "${HOST}/cloudapi/1.0.0/orgs" \
    -H "$ACCEPT" \
    -H "Authorization: Bearer ${PROVIDER_TOKEN}" \
    | jq -r '.values[] | select(.name != "System") | "\(.name)\t\(.id)"')
if [ "${#ORG_LINES[@]}" -eq 0 ]; then
    echo "Error: no organizations found." >&2
    exit 1
fi
ORG_NAMES=()
for line in "${ORG_LINES[@]}"; do ORG_NAMES+=("${line%%$'\t'*}"); done

prompt_choice "Available organizations:" "${ORG_NAMES[@]}"
SELECTED_ORG="$CHOICE"
for line in "${ORG_LINES[@]}"; do
    if [ "${line%%$'\t'*}" == "$SELECTED_ORG" ]; then
        ORG_URN="${line##*$'\t'}"
        break
    fi
done
ORG_UUID="${ORG_URN##*:}"

echo "Requesting org-scoped token for '${SELECTED_ORG}'..." >&2
ORG_TOKEN=$(curl -sk -X POST "${HOST}/oidc/oauth2/token" \
    -H "$ACCEPT" \
    -H "x-vmware-vcloud-tenant-context: ${ORG_UUID}" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "scope=openid profile email phone groups vcd_idp" \
    --data-urlencode "assertion=${PROVIDER_TOKEN}" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    | jq -r '.access_token')
if [ -z "$ORG_TOKEN" ] || [ "$ORG_TOKEN" == "null" ]; then
    echo "Error: failed to obtain an org-scoped token for ${SELECTED_ORG}." >&2
    exit 1
fi

readarray -t NAMESPACES < <(curl -sk "${HOST}/cci/kubernetes/apis/infrastructure.cci.vmware.com/v1alpha3/supervisornamespaces?limit=500" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${ORG_TOKEN}" \
    | jq -r '.items[].metadata.name')
if [ "${#NAMESPACES[@]}" -eq 0 ]; then
    echo "Error: no supervisor namespaces found in org '${SELECTED_ORG}'." >&2
    exit 1
fi

prompt_choice "Available namespaces in org '${SELECTED_ORG}':" "${NAMESPACES[@]}"

export namespace="$CHOICE"
echo "Selected namespace: ${namespace}" >&2
echo "namespace=${namespace}"

echo "Updating namespace in the following YAML files:" >&2
for i in "${!NAMESPACE_UPDATE_FILES[@]}"; do
    echo "  - ${NAMESPACE_UPDATE_FILES[$i]} (${NAMESPACE_UPDATE_JQ_PATHS[$i]})" >&2
done

yaml_to_json() { python3 -c 'import sys, json, yaml; json.dump(yaml.safe_load(sys.stdin), sys.stdout)'; }
# width=100000 prevents PyYAML from line-folding long plain scalars (e.g. base64 blobs).
json_to_yaml() { python3 -c 'import sys, json, yaml; yaml.safe_dump(json.load(sys.stdin), sys.stdout, default_flow_style=False, sort_keys=False, width=100000)'; }

for i in "${!NAMESPACE_UPDATE_FILES[@]}"; do
    f="${NAMESPACE_UPDATE_FILES[$i]}"
    jq_path="${NAMESPACE_UPDATE_JQ_PATHS[$i]}"
    if [ ! -f "$f" ]; then
        echo "Error: ${f} not found." >&2
        exit 1
    fi
    tmp=$(mktemp)
    yaml_to_json < "$f" | jq --arg ns "$namespace" "${jq_path} = \$ns" | json_to_yaml > "$tmp"
    mv "$tmp" "$f"
done
VCFA_SELECT_NS_TEMPLATE_EOF
sed -e "s/\${generic_password}/${generic_password}/" \
    -e "s/\${fqdn_vcfa}/${fqdn_vcfa}/" \
    /tmp/vcfa_select_ns.sh.template > /home/ubuntu/supervisor/vcfa_select_ns.sh
rm -f /tmp/vcfa_select_ns.sh.template
chmod u+x /home/ubuntu/supervisor/vcfa_select_ns.sh

# enable_supervisor_service.sh - registers + activates a Carvel-packaged
# Supervisor Service (e.g. ArgoCD) via vCenter's own API, then enables it
# on a Supervisor-enabled cluster. Ported from the reference project's
# templates/enable_supervisor_service.sh.template verbatim (same quoted-
# heredoc + targeted sed pattern as above).
cat > /tmp/enable_supervisor_service.sh.template <<'ENABLE_SUPERVISOR_SERVICE_TEMPLATE_EOF'
#!/bin/bash
#
# Registers and activates a vCenter Supervisor Service from a Carvel package
# YAML manifest (a "Package" doc plus a "PackageMetadata" doc), via the
# vCenter REST API (com.vmware.vcenter.namespace_management.supervisor_services).
#
# A single POST with version_spec.registered_by_default=true both registers
# and activates the service and its version in one call.
#
set -euo pipefail

show_help() {
    cat << EOF
Usage: $0 [-H host] [-u username] <path-to-supervisor-service-yaml> [path-to-values-yaml]

Registers and activates a vCenter Supervisor Service from the given YAML
manifest. The service identifier, version, display name and description are
derived from the manifest's own Package/PackageMetadata content.

The optional second argument is a fully-rendered values YAML (already
substituted, no \${...} placeholders left) to use as this service's
yaml_service_config on enable - for services needing more than just a
namespace (e.g. Harbor's secrets/storageClass/etc.). When omitted, behavior
is unchanged: just "namespace: <the manifest's own valuesSchema default>".
A "namespace: <default>" line is always prepended, so the values file itself
doesn't need to (and normally shouldn't) set its own namespace key.

Options:
  -H, --host HOST        vCenter FQDN/URL (default: \$VC_HOST or https://sddc01-vc01.vcf9.lab)
  -u, --username USER    vCenter username (default: \$VC_USERNAME or administrator@vsphere.local)
  -h, --help             Show this help message and exit

Password is read from \$VC_PASSWORD if set, otherwise prompted for.

Examples:
  $0 /home/ubuntu/supervisor/supervisor-service-argocd-1.2.0-25642124.yml
  $0 /home/ubuntu/supervisor/supervisor-service-harbor-v2.15.2+vmware.1-vks.1-25639075.yml /tmp/harbor-values-rendered.yml
EOF
}

VC_HOST="https://${vcsa_fqdn}"
VC_USERNAME="${vsphere_nested_username}@${ssoDomain}"
VC_PASSWORD='${generic_password}'
POSITIONAL=()

while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host) VC_HOST="$2"; shift 2 ;;
        -u|--username) VC_USERNAME="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        -*) echo "Unknown argument: $1" >&2; show_help; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [ "${#POSITIONAL[@]}" -lt 1 ] || [ "${#POSITIONAL[@]}" -gt 2 ]; then
    echo "Error: expected one or two arguments - the path to the Supervisor Service YAML, and optionally a rendered values YAML." >&2
    show_help
    exit 1
fi
YAML_FILE="${POSITIONAL[0]}"
VALUES_FILE="${POSITIONAL[1]:-}"

if [ ! -f "$YAML_FILE" ]; then
    echo "Error: ${YAML_FILE} not found." >&2
    exit 1
fi
if [ -n "${VALUES_FILE}" ] && [ ! -f "${VALUES_FILE}" ]; then
    echo "Error: ${VALUES_FILE} not found." >&2
    exit 1
fi

for cmd in curl python3 base64; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required but not installed." >&2; exit 1; }
done

if [ -n "${VC_PASSWORD:-}" ]; then
    PASSWORD="$VC_PASSWORD"
else
    read -rsp "Password for ${VC_USERNAME}@${VC_HOST}: " PASSWORD
    echo
fi

# Prompts among multiple choices; auto-selects if there's only one.
# Usage: prompt_choice "Prompt text" "${array[@]}" ; result left in CHOICE
prompt_choice() {
    local prompt="$1"; shift
    local -a options=("$@")
    if [ "${#options[@]}" -eq 0 ]; then
        echo "Error: no options available for: $prompt" >&2
        exit 1
    fi
    if [ "${#options[@]}" -eq 1 ]; then
        CHOICE="${options[0]}"
        echo "$prompt -> only one option, auto-selected: $CHOICE" >&2
        return
    fi
    echo "$prompt" >&2
    local PS3="Select a number: "
    select opt in "${options[@]}"; do
        if [ -n "${opt:-}" ]; then
            CHOICE="$opt"
            break
        fi
        echo "Invalid selection, try again." >&2
    done
}

# Derive a FALLBACK service identity from the manifest's own refName -
# only actually used below if this turns out to be a genuinely new
# registration (nothing in vCenter's own list matches this manifest's
# displayName yet), since in that case this script's own caller is free
# to pick the id being registered under.
IFS=$'\t' read -r REF_DERIVED_SERVICE_ID VERSION DISPLAY_NAME DESCRIPTION DEFAULT_NAMESPACE < <(python3 - "$YAML_FILE" <<'PYEOF'
import sys, yaml

docs = list(yaml.safe_load_all(open(sys.argv[1])))
package = next(d for d in docs if d.get("kind") == "Package")
metadata = next(d for d in docs if d.get("kind") == "PackageMetadata")

ref_name = package["spec"]["refName"]
version = package["spec"]["version"]
supervisor_service = ref_name.split(".")[0]
if supervisor_service.endswith("-service"):
    supervisor_service = supervisor_service[: -len("-service")]
display_name = metadata["spec"]["displayName"]
description = metadata["spec"]["shortDescription"]
default_namespace = package["spec"]["valuesSchema"]["openAPIv3"]["properties"]["namespace"]["default"]

print(f"{supervisor_service}\t{version}\t{display_name}\t{description}\t{default_namespace}")
PYEOF
)

echo "Logging in to ${VC_HOST}..." >&2
SESSION_ID=$(curl -sk -X POST "${VC_HOST}/api/session" -u "${VC_USERNAME}:${PASSWORD}" | tr -d '"')
if [ -z "$SESSION_ID" ]; then
    echo "Error: vCenter login failed." >&2
    exit 1
fi

# Match by displayName against vCenter's own already-registered list
# first, rather than trusting the refName-derived guess above - a
# built-in service's real supervisor_service identifier can bear no
# resemblance to its own refName (e.g. Harbor: refName
# "harbor.tanzu.vmware.com" but the refName-derived guess above yields
# just "harbor", while the REAL registered id is the full
# "harbor.tanzu.vmware.com" - confirmed live this mismatch made the
# script think Harbor wasn't registered yet, attempt a spurious
# duplicate registration under the wrong id "harbor", which then failed
# on its own downstream k8s object-naming validation since Harbor's
# version string contains a literal "+", invalid in a k8s object name).
# Only falls back to the refName-derived guess for a genuinely new
# registration, where this script's own caller picks the id freely.
echo "Checking whether a service matching '${DISPLAY_NAME}' is already registered..." >&2
LOOKUP=$(curl -sk "${VC_HOST}/api/vcenter/namespace-management/supervisor-services" \
    -H "vmware-api-session-id: ${SESSION_ID}" \
    | python3 -c "
import sys, json
services = json.load(sys.stdin)
match = next((s for s in services if s.get('display_name') == '''${DISPLAY_NAME}'''), None)
if match:
    print(f\"{match['supervisor_service']}\t{match['state']}\")
")
if [ -n "${LOOKUP}" ]; then
    SUPERVISOR_SERVICE="${LOOKUP%%$'\t'*}"
    EXISTING_STATE="${LOOKUP##*$'\t'}"
else
    SUPERVISOR_SERVICE="${REF_DERIVED_SERVICE_ID}"
    EXISTING_STATE=""
fi

if [ -n "$EXISTING_STATE" ]; then
    echo "Supervisor Service '${SUPERVISOR_SERVICE}' is already registered (state: ${EXISTING_STATE})." >&2
else
    echo "Registering and activating '${SUPERVISOR_SERVICE}' (version ${VERSION}) from ${YAML_FILE}..." >&2
    CONTENT_B64=$(base64 -w0 "$YAML_FILE")

    # carvel_spec, not custom_spec - confirmed live by capturing the exact
    # request vSphere Client's own UI sends for this operation (browser
    # devtools). custom_spec (this project's own original design, also
    # what the upstream reference project's own captured guess used) is a
    # generic/simplified wrapper that does NOT retain the manifest's own
    # valuesSchema - it appeared to register successfully, but the later
    # enable-on-cluster step then rejected any nested yaml_service_config
    # with "Nested maps are not allowed for given content type", even
    # though the exact same nested config works fine against a natively
    # (carvel_spec-equivalent) pre-registered service. carvel_spec just
    # takes the raw Package+PackageMetadata YAML content - the server
    # derives supervisor_service/display_name/description/version and,
    # critically, the full valuesSchema itself from the real manifest, so
    # this correctly matches the identifier the "already registered"
    # check ends up looking for too (this project's own DISPLAY_NAME/
    # VERSION variables above are still used for that check and for
    # logging, just not sent back to the server here anymore).
    python3 -c "
import json
body = {
    'carvel_spec': {
        'version_spec': {
            'content': '${CONTENT_B64}'
        }
    }
}
print(json.dumps(body))
" > /tmp/supervisor_service_create_body.json

    HTTP_CODE=$(curl -sk -o /tmp/supervisor_service_create_response.json -w "%{http_code}" \
        -X POST "${VC_HOST}/api/vcenter/namespace-management/supervisor-services" \
        -H "vmware-api-session-id: ${SESSION_ID}" -H "Content-Type: application/json" \
        --data-binary @/tmp/supervisor_service_create_body.json)
    rm -f /tmp/supervisor_service_create_body.json

    if [ "$HTTP_CODE" != "201" ]; then
        echo "Error: failed to create Supervisor Service (HTTP ${HTTP_CODE}):" >&2
        cat /tmp/supervisor_service_create_response.json >&2
        rm -f /tmp/supervisor_service_create_response.json
        exit 1
    fi
    rm -f /tmp/supervisor_service_create_response.json

    # carvel_spec doesn't let the caller pick the id - the server derives
    # it from the manifest's own refName, which does NOT always match the
    # REF_DERIVED_SERVICE_ID guess above (that's the whole reason this
    # falls back to it only when nothing was found - see comment above).
    # Re-run the same displayName lookup now to discover the REAL id the
    # server just assigned, instead of trusting the stale guess: confirmed
    # live this guess is wrong for Harbor (registers as
    # "harbor.tanzu.vmware.com", guess was "harbor"), which made the next
    # status GET 404 and crash on a missing 'state' key before ever
    # reaching the enable-on-cluster step below.
    REGISTERED=$(curl -sk "${VC_HOST}/api/vcenter/namespace-management/supervisor-services" \
        -H "vmware-api-session-id: ${SESSION_ID}" \
        | python3 -c "
import sys, json
services = json.load(sys.stdin)
match = next((s for s in services if s.get('display_name') == '''${DISPLAY_NAME}'''), None)
if match:
    print(f\"{match['supervisor_service']}\t{match['state']}\")
")
    if [ -z "${REGISTERED}" ]; then
        echo "Error: registration reported success but '${DISPLAY_NAME}' can't be found afterwards." >&2
        exit 1
    fi
    SUPERVISOR_SERVICE="${REGISTERED%%$'\t'*}"
    STATE="${REGISTERED##*$'\t'}"
    echo "Supervisor Service '${SUPERVISOR_SERVICE}' registered. Current state: ${STATE}"
fi

# Pick which Supervisor cluster to enable the service on.
readarray -t CLUSTER_LINES < <(curl -sk "${VC_HOST}/api/vcenter/namespace-management/clusters" \
    -H "vmware-api-session-id: ${SESSION_ID}" \
    | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    print(f\"{c['cluster_name']}\t{c['cluster']}\")
")
if [ "${#CLUSTER_LINES[@]}" -eq 0 ]; then
    echo "Error: no Supervisor-enabled clusters found." >&2
    exit 1
fi
CLUSTER_NAMES=()
for line in "${CLUSTER_LINES[@]}"; do CLUSTER_NAMES+=("${line%%$'\t'*}"); done

prompt_choice "Available clusters:" "${CLUSTER_NAMES[@]}"
SELECTED_CLUSTER_NAME="$CHOICE"
for line in "${CLUSTER_LINES[@]}"; do
    if [ "${line%%$'\t'*}" == "$SELECTED_CLUSTER_NAME" ]; then
        CLUSTER_ID="${line##*$'\t'}"
        break
    fi
done

echo "Checking whether '${SUPERVISOR_SERVICE}' is already enabled on cluster '${SELECTED_CLUSTER_NAME}'..." >&2
CLUSTER_SVC_HTTP=$(curl -sk -o /tmp/cluster_svc_status.json -w "%{http_code}" \
    "${VC_HOST}/api/vcenter/namespace-management/clusters/${CLUSTER_ID}/supervisor-services/${SUPERVISOR_SERVICE}" \
    -H "vmware-api-session-id: ${SESSION_ID}")

if [ "$CLUSTER_SVC_HTTP" == "200" ]; then
    CONFIG_STATUS=$(python3 -c "import json; print(json.load(open('/tmp/cluster_svc_status.json')).get('config_status'))")
    rm -f /tmp/cluster_svc_status.json
    echo "Supervisor Service '${SUPERVISOR_SERVICE}' is already enabled on '${SELECTED_CLUSTER_NAME}' (config_status: ${CONFIG_STATUS})."
    exit 0
fi
rm -f /tmp/cluster_svc_status.json

echo "Enabling '${SUPERVISOR_SERVICE}' (version ${VERSION}) on cluster '${SELECTED_CLUSTER_NAME}'..." >&2
if [ -n "${VALUES_FILE}" ]; then
    CONFIG_B64=$( { printf 'namespace: %s\n' "$DEFAULT_NAMESPACE"; cat "${VALUES_FILE}"; } | base64 -w0)
else
    CONFIG_B64=$(printf 'namespace: %s\n' "$DEFAULT_NAMESPACE" | base64 -w0)
fi

python3 -c "
import json
body = {'supervisor_service': '${SUPERVISOR_SERVICE}', 'version': '${VERSION}', 'yaml_service_config': '${CONFIG_B64}'}
print(json.dumps(body))
" > /tmp/cluster_svc_enable_body.json

HTTP_CODE=$(curl -sk -o /tmp/cluster_svc_enable_response.json -w "%{http_code}" \
    -X POST "${VC_HOST}/api/vcenter/namespace-management/clusters/${CLUSTER_ID}/supervisor-services" \
    -H "vmware-api-session-id: ${SESSION_ID}" -H "Content-Type: application/json" \
    --data-binary @/tmp/cluster_svc_enable_body.json)
rm -f /tmp/cluster_svc_enable_body.json

if [ "$HTTP_CODE" != "204" ]; then
    echo "Error: failed to enable Supervisor Service on cluster (HTTP ${HTTP_CODE}):" >&2
    cat /tmp/cluster_svc_enable_response.json >&2
    rm -f /tmp/cluster_svc_enable_response.json
    exit 1
fi
rm -f /tmp/cluster_svc_enable_response.json

echo "Waiting for '${SUPERVISOR_SERVICE}' to reconcile on '${SELECTED_CLUSTER_NAME}'..." >&2
CONFIG_STATUS="CONFIGURING"
# 60x10s=10min, not 30x10s=5min - confirmed live a multi-component service
# like Harbor (7-8 pods: core/database/jobservice/nginx/portal/redis/
# registry/trivy, each pulling its own image and provisioning its own PVC)
# comfortably needs more than 5 minutes; a fast single-component service
# like ArgoCD still exits this loop on its first non-CONFIGURING check
# either way, so raising the ceiling doesn't slow that case down.
for i in $(seq 1 60); do
    POLL_HTTP_CODE=$(curl -sk -o /tmp/cluster_svc_poll.json -w "%{http_code}" \
        "${VC_HOST}/api/vcenter/namespace-management/clusters/${CLUSTER_ID}/supervisor-services/${SUPERVISOR_SERVICE}" \
        -H "vmware-api-session-id: ${SESSION_ID}")
    # A non-200 response here is a transient race right after enabling, not a real
    # terminal state - keep polling instead of treating it as done.
    if [ "$POLL_HTTP_CODE" == "200" ]; then
        CONFIG_STATUS=$(python3 -c "import json; print(json.load(open('/tmp/cluster_svc_poll.json')).get('config_status') or 'CONFIGURING')")
    fi
    rm -f /tmp/cluster_svc_poll.json
    echo "  [$i] (HTTP ${POLL_HTTP_CODE}) config_status=${CONFIG_STATUS}" >&2
    if [ "$CONFIG_STATUS" != "CONFIGURING" ]; then
        break
    fi
    sleep 10
done

echo "Supervisor Service '${SUPERVISOR_SERVICE}' on cluster '${SELECTED_CLUSTER_NAME}': config_status=${CONFIG_STATUS}"
ENABLE_SUPERVISOR_SERVICE_TEMPLATE_EOF
sed -e "s/\${generic_password}/${generic_password}/" \
    -e "s/\${ssoDomain}/${ssoDomain}/" \
    -e "s/\${vsphere_nested_username}/${vsphere_nested_username}/" \
    -e "s/\${vcsa_fqdn}/${vcsa_fqdn}/" \
    /tmp/enable_supervisor_service.sh.template > /home/ubuntu/supervisor/enable_supervisor_service.sh
rm -f /tmp/enable_supervisor_service.sh.template
chmod u+x /home/ubuntu/supervisor/enable_supervisor_service.sh

#
# harbor_rewrite_images.sh - generic, no baked-in environment values (unlike
# enable_supervisor_service.sh above), so no sed-render step: registry
# hostname/project are CLI args, not template placeholders, so this one
# script stays reusable standalone, any time after this environment's own
# Harbor is up, against any manifest referencing images pushed there (e.g.
# demo-http-apps.yaml's own tacobayle/busybox-vN Docker Hub references)
# without needing regeneration.
#
cat > /home/ubuntu/supervisor/harbor_rewrite_images.sh <<'HARBOR_REWRITE_IMAGES_EOF'
#!/bin/bash
#
# Rewrites every container image reference in a Kubernetes manifest (any
# number of YAML documents) to point at this environment's own Harbor
# instead of wherever it originally came from (e.g. Docker Hub) - lets an
# already-authored manifest be redirected with no other edits, once the
# same image has been pushed to Harbor under the given project (see
# vcf_bootstrap.sh's own harbor image-preload step for the push side).
#
# Usage: harbor_rewrite_images.sh <harbor-fqdn> <project> <yaml-file> [image-name ...]
#   <yaml-file> is rewritten in place.
#   [image-name ...] optionally restricts rewriting to only images whose
#   basename (the final path segment, before any tag) matches one of these
#   - omit to rewrite every container image in the file unconditionally.
#
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <harbor-fqdn> <project> <yaml-file> [image-name ...]" >&2
    exit 1
fi
HARBOR_FQDN="$1"
PROJECT="$2"
YAML_FILE="$3"
shift 3

if [ ! -f "${YAML_FILE}" ]; then
    echo "Error: ${YAML_FILE} not found." >&2
    exit 1
fi

HARBOR_FQDN="${HARBOR_FQDN}" PROJECT="${PROJECT}" python3 - "$YAML_FILE" "$@" <<'PYEOF'
import os, sys
import yaml

yaml_file = sys.argv[1]
names = set(sys.argv[2:])
harbor_fqdn = os.environ["HARBOR_FQDN"]
project = os.environ["PROJECT"]

def rewrite(image):
    base = image.rsplit("/", 1)[-1]
    name, _, tag = base.partition(":")
    if names and name not in names:
        return image
    return f"{harbor_fqdn}/{project}/{name}:{tag or 'latest'}"

def walk_containers(spec):
    if not spec:
        return
    for key in ("containers", "initContainers"):
        for c in spec.get(key, []) or []:
            if "image" in c:
                c["image"] = rewrite(c["image"])

docs = list(yaml.safe_load_all(open(yaml_file)))
for doc in docs:
    if not doc:
        continue
    kind = doc.get("kind")
    if kind == "Pod":
        walk_containers(doc.get("spec"))
    elif kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        walk_containers((doc.get("spec") or {}).get("template", {}).get("spec"))
    elif kind == "CronJob":
        walk_containers((((doc.get("spec") or {}).get("jobTemplate") or {}).get("spec") or {}).get("template", {}).get("spec"))

with open(yaml_file, "w") as f:
    yaml.safe_dump_all(docs, f, default_flow_style=False, sort_keys=False)
PYEOF
HARBOR_REWRITE_IMAGES_EOF
chmod u+x /home/ubuntu/supervisor/harbor_rewrite_images.sh

#
# Supervisor Services (spec.sddc.vcenter.supervisor_services) - unlike the
# reference project (which downloads each by url - gw here has no route to
# arbitrary external hosts), each entry names a file expected to already be
# sitting at /home/ubuntu/<name>, delivered there by gw-setup.sh.tpl's own
# generic vcf_cli_iso passthrough loop (add the file to that Iso CR's
# spec.files list - no cloud-init changes needed here). Optional - skipped
# entirely if unset/empty.
#
if [ -z "${supervisor_services}" ] || [ "${supervisor_services}" == "null" ] || [ "${supervisor_services}" == "[]" ]; then
  log_notify "no supervisor_services configured, skipping"
else
  while read -r item
  do
    svc_type="$(echo ${item} | jq -c -r '.type // "carvel-yaml"')"

    if [ "${svc_type}" == "harbor" ]; then
      #
      # Harbor is already globally registered/ACTIVATED in this VCF 9.1
      # environment (confirmed live via GET
      # api/vcenter/namespace-management/supervisor-services), so no real
      # Package/PackageMetadata registration is needed - but .name still
      # names the real upstream registration manifest (ISO-delivered like
      # everything else) so enable_supervisor_service.sh's own "already
      # registered, skip" check runs against real content, keeping this
      # portable to a VCF environment where Harbor isn't pre-registered.
      # What Harbor genuinely needs beyond that generic script is a much
      # richer yaml_service_config than "namespace: X" alone (6 required
      # secrets, 5 PVC storageClass entries, enableNginxLoadBalancer,
      # tlsSecretLabels) - values_template names a SECOND ISO-delivered
      # file (the actual data-values template, with ${...} placeholders)
      # rendered here and passed as enable_supervisor_service.sh's new
      # optional second argument.
      #
      # Confirmed live end-to-end on this exact environment:
      # enableNginxLoadBalancer: true (baked into the values template,
      # not overridden here) is required, not the Ingress path - there is
      # no IngressClass registered at the Supervisor level at all (AKO's
      # own IngressClass only exists inside guest VKS clusters), so
      # Avi/AKO instead reconciles plain type: LoadBalancer Services
      # directly, which is exactly what enableNginxLoadBalancer: true
      # produces. This also happens to be the one path that avoids
      # harbor-portal's own nginx crashing with "socket() [::]:8443
      # failed (97: Address family not supported by protocol)" on this
      # IPv6-less cluster - the Ingress path hits that crash regardless
      # of network.ipFamilies (confirmed live that setting has no effect
      # on the portal's own nginx template in this chart version).
      #
      name="$(echo ${item} | jq -c -r '.name // empty')"
      values_template_name="$(echo ${item} | jq -c -r '.values_template // empty')"
      # Not user-configurable - always the same well-known FQDN pattern
      # every other Avi-fronted hostname in this deployment already uses
      # (see avi_dns_domains_json/vsvip_json above), under the
      # Avi-delegated app.vcf9.lab-style zone so dns-vs can serve it once
      # registered below - no CRD/CR field needed.
      harbor_hostname="harbor.${avi_subdomain}.${domain}"
      if [ -z "${name}" ] || [ -z "${values_template_name}" ]; then
        log_notify "ERROR: harbor supervisor_services entry needs name and values_template, skipping: ${item}"
        continue
      fi
      service_file="/home/ubuntu/${name}"
      values_template_file="/home/ubuntu/${values_template_name}"
      if [ ! -f "${service_file}" ] || [ ! -f "${values_template_file}" ]; then
        log_notify "ERROR: harbor supervisor service file(s) not found (${service_file}, ${values_template_file}) - were they added to vms.gw.iso's Iso CR?"
        continue
      fi

      # Secrets are generated here, not authored in the CR - they're
      # meaningless random strings with no reason to be memorable or
      # CR-visible. storageClass reuses this project's own deterministic
      # naming convention (matches bash/variables.sh's own
      # cluster_name="${basename_sddc}-cluster") rather than deriving it
      # via VCFA's regionStoragePolicies API (VCFA org provisioning runs
      # much later in this script, and Harbor's PVCs are a direct
      # Supervisor-level StorageClass reference, unrelated to VCFA).
      harbor_storage_class="${cluster_name}-vsan-storage-policy"
      harbor_admin_password="${generic_password}"
      harbor_secret_key=$(echo -n "${generic_password}harbor-secretkey" | md5sum | cut -c1-16)
      harbor_database_password=$(echo -n "${generic_password}harbor-database" | md5sum | cut -c1-16)
      harbor_core_secret=$(echo -n "${generic_password}harbor-core" | md5sum | cut -c1-16)
      harbor_core_xsrf_key_raw=$(echo -n "${generic_password}harbor-xsrf" | md5sum)
      harbor_core_xsrf_key="${harbor_core_xsrf_key_raw}${harbor_core_xsrf_key_raw}"
      harbor_core_xsrf_key="${harbor_core_xsrf_key:0:32}"
      harbor_jobservice_secret=$(echo -n "${generic_password}harbor-jobservice" | md5sum | cut -c1-16)
      harbor_registry_secret=$(echo -n "${generic_password}harbor-registry" | md5sum | cut -c1-16)

      # Python literal string replacement, not sed - harbor_admin_password
      # is this deployment's own generic_password verbatim, which may
      # contain almost any character (confirmed live: this environment's
      # own password contains "@", which broke a sed s@...@...@ delimiter
      # here outright). Values are passed via environment variables, not
      # embedded into the Python source itself, so no shell-quoting or
      # string-escaping concern either regardless of what they contain.
      rendered_values_file="/tmp/harbor-values-rendered.yml"
      HARBOR_HOSTNAME="${harbor_hostname}" \
      HARBOR_ADMIN_PASSWORD="${harbor_admin_password}" \
      HARBOR_SECRET_KEY="${harbor_secret_key}" \
      HARBOR_DATABASE_PASSWORD="${harbor_database_password}" \
      HARBOR_CORE_SECRET="${harbor_core_secret}" \
      HARBOR_CORE_XSRF_KEY="${harbor_core_xsrf_key}" \
      HARBOR_JOBSERVICE_SECRET="${harbor_jobservice_secret}" \
      HARBOR_REGISTRY_SECRET="${harbor_registry_secret}" \
      HARBOR_STORAGE_CLASS="${harbor_storage_class}" \
      python3 -c "
import os
text = open('${values_template_file}').read()
for placeholder, env_var in [
    ('\${harbor_hostname}', 'HARBOR_HOSTNAME'),
    ('\${harbor_admin_password}', 'HARBOR_ADMIN_PASSWORD'),
    ('\${harbor_secret_key}', 'HARBOR_SECRET_KEY'),
    ('\${harbor_database_password}', 'HARBOR_DATABASE_PASSWORD'),
    ('\${harbor_core_secret}', 'HARBOR_CORE_SECRET'),
    ('\${harbor_core_xsrf_key}', 'HARBOR_CORE_XSRF_KEY'),
    ('\${harbor_jobservice_secret}', 'HARBOR_JOBSERVICE_SECRET'),
    ('\${harbor_registry_secret}', 'HARBOR_REGISTRY_SECRET'),
    ('\${harbor_storage_class}', 'HARBOR_STORAGE_CLASS'),
]:
    text = text.replace(placeholder, os.environ[env_var])
open('${rendered_values_file}', 'w').write(text)
"

      /home/ubuntu/supervisor/enable_supervisor_service.sh "${service_file}" "${rendered_values_file}"
      rm -f "${rendered_values_file}"

      # Register harbor_hostname with Avi now that harbor-nginx's own
      # LoadBalancer Service has a real VIP - app.vcf9.lab (or whatever
      # zone harbor_hostname falls under) is delegated to Avi's own
      # dns-vs Virtual Service (confirmed live: the dns-avi
      # IPAMDNSProviderProfile's dns_service_domain lists app.vcf9.lab),
      # and arbitrary FQDN->IP static mappings not tied to an
      # Avi-managed Ingress/Service belong on dns-vs's own
      # static_dns_records field directly (confirmed live via a
      # UI-added entry's resulting API payload) - not per-VS dns_info,
      # which only applies to VSes Avi itself created from an
      # Ingress/Service hostname.
      kubectl config use-context "${supervisor_cluster_name}" >&2
      harbor_namespace="$(kubectl get namespaces -o name | grep -o 'svc-harbor-[a-z0-9]*' | head -1)"
      if [ -z "${harbor_namespace}" ]; then
        log_notify "ERROR: harbor namespace (svc-harbor-*) not found - skipping DNS registration for ${harbor_hostname}"
      else
        harbor_ip=""
        for attempt_harbor_ip in $(seq 1 12); do
          harbor_ip="$(kubectl get svc -n "${harbor_namespace}" harbor-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
          [ -n "${harbor_ip}" ] && break
          sleep 10
        done
        if [ -z "${harbor_ip}" ]; then
          log_notify "ERROR: harbor-nginx Service in ${harbor_namespace} has no LoadBalancer IP after waiting - skipping DNS registration for ${harbor_hostname}"
        else
          avi_login
          avi_api 3 3 GET "" "api/virtualservice?name=dns-vs"
          dns_vs_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
          avi_api 3 3 GET "" "api/virtualservice/${dns_vs_uuid}"
          static_dns_records=$(echo ${response_body} | jq -c --arg fqdn "${harbor_hostname}" --arg ip "${harbor_ip}" \
            '[.static_dns_records[]? | select(.fqdn != [$fqdn])] + [{type: "DNS_RECORD_A", algorithm: "DNS_RECORD_RESPONSE_ROUND_ROBIN", fqdn: [$fqdn], ip_address: [{ip_address: {addr: $ip, type: "V4"}}]}]')
          avi_api 3 3 PATCH "$(jq -n --argjson records "${static_dns_records}" '{replace: {static_dns_records: $records}}')" "api/virtualservice/${dns_vs_uuid}"
          log_notify "Registered DNS record ${harbor_hostname} -> ${harbor_ip} on Avi's dns-vs"

          # Optional image preload (spec's 'images', ISO-delivered
          # OCI-archive tarballs) - pushed straight to Harbor's own
          # LoadBalancer IP rather than harbor_hostname, since the DNS
          # record above may take a moment to propagate through gw's own
          # BIND delegation to Avi's dns-vs even though it was already
          # confirmed live to resolve correctly end-to-end once settled.
          # harbor_admin_password was already derived above, alongside
          # this same entry's other secrets. Confirmed live: images
          # pushed here pull successfully (no trust.additionalTrustedCAs
          # ClusterClass variable needed) on any VKS cluster created
          # AFTER Harbor's own activation - VMware's own "managed-by:
          # vmware-vRegistry" mechanism (see the values template)
          # propagates Harbor's self-signed CA into new clusters'
          # trust stores automatically, just not retroactively into
          # clusters that already existed beforehand.
          harbor_images_json="$(echo ${item} | jq -c '.images // []')"
          if [ "${harbor_images_json}" != "[]" ]; then
            if ! command -v skopeo >/dev/null 2>&1; then
              sudo apt-get install -y skopeo || log_notify "ERROR: apt-get install skopeo failed, skipping harbor image preload"
            fi
            if command -v skopeo >/dev/null 2>&1; then
              harbor_registry_project="registry"
              project_check_code=$(curl -sk -o /dev/null -w "%{http_code}" -u "admin:${harbor_admin_password}" \
                "https://${harbor_ip}/api/v2.0/projects/${harbor_registry_project}")
              if [ "${project_check_code}" == "404" ]; then
                curl -sk -u "admin:${harbor_admin_password}" -X POST "https://${harbor_ip}/api/v2.0/projects" \
                  -H "Content-Type: application/json" \
                  -d "$(jq -n --arg name "${harbor_registry_project}" '{project_name: $name, public: true}')" >/dev/null
              fi
              echo "${harbor_images_json}" | jq -c -r .[] | while read -r image_file
              do
                image_path="/home/ubuntu/${image_file}"
                if [ ! -f "${image_path}" ]; then
                  log_notify "ERROR: harbor image ${image_file} not found at ${image_path} - was it added to vms.gw.iso's Iso CR?"
                  continue
                fi
                image_name="$(basename "${image_file}" .tar.gz)"
                image_name="$(basename "${image_name}" .tar)"
                if skopeo copy --dest-tls-verify=false --dest-creds "admin:${harbor_admin_password}" \
                    "oci-archive:${image_path}" "docker://${harbor_ip}/${harbor_registry_project}/${image_name}:latest"; then
                  log_notify "Pushed ${image_file} to Harbor as ${harbor_registry_project}/${image_name}:latest (pull via ${harbor_hostname}/${harbor_registry_project}/${image_name}:latest)"
                else
                  log_notify "ERROR: failed to push ${image_file} to Harbor"
                fi
              done
            fi
          fi
        fi
      fi

      continue
    fi

    # carvel-yaml (default) - existing behavior, unchanged.
    name="$(echo ${item} | jq -c -r '.name // empty')"
    if [ -z "${name}" ]; then
      log_notify "ERROR: supervisor_services entry has no name, skipping: ${item}"
      continue
    fi
    service_file="/home/ubuntu/${name}"
    if [ ! -f "${service_file}" ]; then
      log_notify "ERROR: supervisor service file ${name} not found at ${service_file} - was it added to vms.gw.vcf_cli_iso's Iso CR?"
      continue
    fi
    /home/ubuntu/supervisor/enable_supervisor_service.sh "${service_file}"
  done < <(echo "${supervisor_services}" | jq -c -r .[])
fi

log_notify "Supervisor cluster ready, auth helper scripts written to /home/ubuntu/supervisor/"

log_notify "vcf_bootstrap.sh complete (SDDC build + vCenter port groups + NSX config + Avi deployment + Avi configuration + Avi upgrade + NSX Project/VPC + vSAN alarm silencing + Supervisor enablement - full pipeline, no remaining standalone stages)"

#
#
#
# VCF Automation (VCFA) org configuration - ported from the reference
# project's vcf-automation/configure_vcfa.sh (kept as a single appended
# section here rather than a separate script, matching this project's own
# existing convention of inlining Avi deployment/configuration directly
# above instead of calling out to separate avi-deploy.sh/configure_avi.sh
# files). Entirely optional - every step below is already a no-op if
# spec.sddc.vcf_a is unset (vcf_a_regions/vcf_a_provider_gws/
# vcf_a_organizations/vcf_a_content_libraries all default to "[]").
#
# Setup below only re-derives what the original script's own top-of-file
# block needs beyond what vcf_bootstrap.sh already has - jsonFile and
# bash/variables.sh are already sourced (this project's variables.sh is a
# flat Python-rendered export list, not upstream's live jq-parsing script,
# so vcf_a_regions/vcf_a_ip_spaces/vcf_a_provider_gws/vcf_a_organizations/
# vcf_a_content_libraries already come pre-computed from userdata.py's
# derive_vcf_a_organizations()/derive_vcf_a_ip_space_template() instead of
# being derived here from $jsonFile). fqdn_vcfa is computed once near the
# top of this script (shared with the Supervisor auth helper scripts
# rendered further up) - default_storage_class is the only simple derived
# value needed here specifically, not a CR field.
# slack_webhook is left empty - this project only supports google_webhook
# notifications so far, and log_message below silently no-ops on an empty
# slack_url exactly like it does for google_url.
#
default_storage_class="${supervisor_cluster_name} vSAN Storage Policy"
slack_webhook=""
log_file="/home/ubuntu/vcf_bootstrap.log"
resultFile="/home/ubuntu/configure_vcfa.done"
touch "${log_file}"

# bash/log_message.sh, inlined (not sourced - this project doesn't
# distribute that file to gw separately).
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

# bash/download_file.sh, inlined (not sourced - same reason as above).
download_file_from_url_to_location () {
  local url=$1
  local download_location=$2
  local description=$3
  echo ""
  echo "==> Checking ${description} file"
  if [ -s "${download_location}" ]; then
    echo "   +++ ${description} file ${download_location} is not empty"
  else
    echo "   +++ Downloading ${description} file"
    response=$(curl -k -s --write-out "\n%{http_code}" -o ${download_location} ${url})
    response_code=$(tail -n1 <<< "$response")
    if [[ $response_code != 200 ]] ; then
      echo "   +++ HTTP URI does not look valid: ${url}"
      rm -f "${download_location}"
      exit 255
    else
      if [ -s "${download_location}" ]; then
        echo "   ++++++ ${description} file ${download_location} is not empty"
      else
        echo "   ++++++ ${description} file ${download_location} is empty"
        exit 255
      fi
    fi
  fi
}

VCFA_HOST="https://${fqdn_vcfa}"
VCFA_VERSION="9.1.0"
ACCEPT="Accept: application/json;version=${VCFA_VERSION}"
CONTENT_TYPE="Content-Type: application/json;version=${VCFA_VERSION}"

#
# Vault + cert-manager PKI bootstrap - ported from the reference project's
# own cloud-init (templates/userdata_external-gw-trunk.yaml.template), NOT
# from configure_vcfa.sh (that script assumes Vault is already up and only
# reads its root token/TLS cert). Deliberately done here in vcf_bootstrap.sh
# instead of gw's own cloud-init:
#   - gating is trivial here (vcf_a_organizations is already a plain bash
#     variable by this point) - doing it in cloud-init would mean computing
#     the same "does any org need vault" check a second time through a
#     separate Python code path, for a feature nothing else depends on.
#   - matches this project's existing convention of putting every other
#     big, optional, feature-specific phase (Avi deployment/config, NSX
#     Project/VPC, Supervisor enablement, VCFA org provisioning above) in
#     this script rather than cloud-init.
#   - cloud-init only ever runs once per gw - a bug in PKI/cert setup here
#     just needs a re-run of this script, not a fresh VM.
#   - vault_integration is per-namespace, but Vault itself is a single
#     shared instance on gw - only worth standing up once, gated on
#     whether ANY org in vcf_a_organizations actually wants it, not
#     repeated per org.
# apt's vault package and every vault_pki_*/vault_secret_file_path value
# used below are already provisioned/exported unconditionally regardless
# of this gate (cheap, harmless if unused) - only the actual service
# start/init/PKI setup is conditional.
#
if echo "${vcf_a_organizations}" | jq -e 'any(.[]; .namespace.vault_integration.enabled == true)' > /dev/null 2>&1; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: at least one org needs vault_integration, bootstrapping Vault" "${log_file}" "${slack_webhook}" "${google_webhook}"
  mkdir -p /opt/vault/tls
  key_file="/opt/vault/tls/tls.key"
  cert_conf_file="/opt/vault/tls/crt.conf"
  cert_file="/opt/vault/tls/tls.crt"
  openssl genrsa -out ${key_file} 4096
  cat > ${cert_conf_file} <<CERT_CONF_EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = ${domain}
O = Organization
L = City
ST = State
C = US

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = vault.${domain}
IP.1 = ${ip_gw}
CERT_CONF_EOF
  openssl req -new -x509 -key ${key_file} -out ${cert_file} -days 365 -config ${cert_conf_file} -extensions v3_req
  mkdir -p /etc/vault.d
  mv /etc/vault.d/vault.hcl /etc/vault.d/vault.hcl.ori 2>/dev/null
  export VAULT_ADDR="https://127.0.0.1:8200"
  vault_config='
  storage "file" {
    path    = "/opt/vault/data"
  }
    listener "tcp" {
      address     = "0.0.0.0:8200"
      tls_disable = "false"
      tls_cert_file = "/opt/vault/tls/tls.crt"
      tls_key_file = "/opt/vault/tls/tls.key"
    }
    ui = true
    api_addr = "https://${ip_gw}:8200"'
  echo "${vault_config}" | tee /etc/vault.d/vault.hcl
  systemctl start vault
  systemctl enable vault
  vault operator init -key-shares=1 -key-threshold=1 -tls-skip-verify -format json | tee ${vault_secret_file_path}
  vault operator unseal -tls-skip-verify $(jq -c -r .unseal_keys_hex[0] ${vault_secret_file_path})
  vault login -tls-skip-verify $(jq -c -r .root_token ${vault_secret_file_path})
  # root ca
  vault secrets enable -tls-skip-verify ${vault_pki_name}
  vault secrets tune -tls-skip-verify -max-lease-ttl=${vault_pki_max_lease_ttl} "${vault_pki_name}"
  vault write -tls-skip-verify -field=certificate ${vault_pki_name}/root/generate/internal common_name="${vault_pki_cert_common_name}" issuer_name="${vault_pki_cert_issuer_name}" ttl=${vault_pki_cert_ttl} > ${vault_pki_cert_path}
  vault write -tls-skip-verify ${vault_pki_name}/roles/${vault_pki_role_name} allow_any_name=true
  vault write -tls-skip-verify ${vault_pki_name}/config/urls issuing_certificates="https://${ip_gw}:8200/v1/${vault_pki_role_name}/ca" crl_distribution_points="https://${ip_gw}:8200/v1/${vault_pki_role_name}/crl"
  # intermediate ca
  vault secrets enable -tls-skip-verify -path=${vault_pki_intermediate_name} ${vault_pki_name}
  vault secrets tune -tls-skip-verify -max-lease-ttl=${vault_pki_intermediate_max_lease_ttl} ${vault_pki_intermediate_name}
  vault write -tls-skip-verify -format=json ${vault_pki_intermediate_name}/intermediate/generate/internal common_name="${vault_pki_intermediate_cert_common_name}" issuer_name="${vault_pki_intermediate_cert_issuer_name}" | jq -r '.data.csr' | tee ${vault_pki_intermediate_cert_path}
  vault write -tls-skip-verify -format=json ${vault_pki_name}/root/sign-intermediate issuer_ref="${vault_pki_cert_issuer_name}" csr=@${vault_pki_intermediate_cert_path} format=pem_bundle ttl="${vault_pki_intermediate_max_lease_ttl}" | jq -r '.data.certificate' | tee ${vault_pki_intermediate_cert_path_signed}
  vault write -tls-skip-verify ${vault_pki_intermediate_name}/intermediate/set-signed certificate=@${vault_pki_intermediate_cert_path_signed}
  vault write -tls-skip-verify ${vault_pki_intermediate_name}/roles/${vault_pki_intermediate_role_name} issuer_ref="$(vault read -tls-skip-verify -field=default ${vault_pki_intermediate_role_name}/config/issuers)" allowed_domains="${domain}" allow_subdomains=${vault_pki_intermediate_role_allow_subdomains} max_ttl="${vault_pki_intermediate_role_max_ttl}"
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Vault bootstrap complete" "${log_file}" "${slack_webhook}" "${google_webhook}"
else
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no org needs vault_integration, skipping Vault bootstrap" "${log_file}" "${slack_webhook}" "${google_webhook}"
fi

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

vcfa_login

#
# Retrieve NSX Manager id and name
#
vcfa_api GET "cloudapi/v1/nsxManagers" ""
nsx_manager_id=$(echo ${response_body} | jq -c -r '.values[0].id')
nsx_manager_name=$(echo ${response_body} | jq -c -r '.values[0].name')

#
# Retrieve Supervisor id and name
#
vcfa_api GET "cloudapi/v1/supervisors" ""
supervisor_id=$(echo ${response_body} | jq -c -r '.values[0].supervisorId')
supervisor_name=$(echo ${response_body} | jq -c -r '.values[0].name')

#
# configure regions - idempotent. region/ipSpace/providerGateway are
# shared, provider-wide resources (all three already existed for org-1 on
# the vcf9 lab, so this exact block was validated separately end-to-end
# against a second VCD/VCFA environment instead - see the header notes
# above).
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    region_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/regions" ""
    existing_region_id=$(echo ${response_body} | jq -c -r --arg arg "${region_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${existing_region_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: region ${region_name} already exists, skipping" "${log_file}" "" ""
      continue
    fi
    region_json=$(jq -n --arg n "${region_name}" --arg nsxid "${nsx_manager_id}" --arg nsxname "${nsx_manager_name}" \
      --arg supid "${supervisor_id}" --arg supname "${supervisor_name}" --arg sc "${default_storage_class}" \
      '{name: $n, description: "", nsxManager: {name: $nsxname, id: $nsxid}, supervisors: [{name: $supname, id: $supid}], storagePolicies: [$sc]}')
    vcfa_api POST "cloudapi/v1/regions" "${region_json}"
  fi
done < <(echo "${vcf_a_regions}" | jq -c -r .[])

#
# Create external IP spaces - idempotent
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    ip_space_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/ipSpaces" ""
    existing_ip_space_id=$(echo ${response_body} | jq -c -r --arg arg "${ip_space_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${existing_ip_space_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ip space ${ip_space_name} already exists, skipping" "${log_file}" "" ""
      continue
    fi
    vcfa_api GET "cloudapi/v1/regions" ""
    region_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${item} | jq -c -r '.region_ref')" '.values[] | select(.name == $arg) | .id')
    ip_space_json=$(jq -n --arg n "${ip_space_name}" --arg cidr "$(echo ${item} | jq -c -r '.cidr')" --arg regionid "${region_id}" \
      '{name: $n, description: "", internalScopeCidrBlocks: [{cidr: $cidr}], ipAddressRanges: [], reservedIpAddressRanges: [],
        providerVisibilityOnly: false, defaultQuota: {maxSubnetSize: 1, maxCidrCount: -1, maxIpCount: -1}, regionRef: {id: $regionid}}')
    vcfa_api POST "cloudapi/v1/ipSpaces" "${ip_space_json}"
  fi
done < <(echo "${vcf_a_ip_spaces}" | jq -c -r .[])

#
# Create provider gateways - idempotent
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    pgw_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/providerGateways" ""
    existing_pgw_id=$(echo ${response_body} | jq -c -r --arg arg "${pgw_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${existing_pgw_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: provider gateway ${pgw_name} already exists, skipping" "${log_file}" "" ""
      continue
    fi
    vcfa_api GET "cloudapi/v1/regions" ""
    region_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${item} | jq -c -r '.region_ref')" '.values[] | select(.name == $arg) | .id')
    #
    # ipSpaceRefs deliberately NOT set here - confirmed live it reads
    # back null regardless of what's sent and does not actually
    # associate/pool anything. The real, working association step
    # (POST cloudapi/v1/ipSpaceAssociations) happens separately below,
    # after every ip_space and provider gateway exist.
    #
    pgw_json=$(jq -n --arg n "${pgw_name}" --arg t0 "$(echo ${item} | jq -c -r '.tier0_ref')" --arg regionid "${region_id}" \
      '{name: $n, description: "", backingRef: {id: $t0, name: $t0}, backingType: "NSX_TIER0", regionRef: {id: $regionid}}')
    vcfa_api POST "cloudapi/v1/providerGateways" "${pgw_json}"
    #
    # This exact POST (no natConfig, no explicit gatewayConnectionBackingId)
    # was confirmed live on a separate VCD/VCFA environment: 202 ->
    # REALIZED with no errors, VCFA auto-populates gatewayConnectionBackingId
    # from the gateway's own name. The original script's own captured error
    # ("Provider Gateway test-ui must be backed by a shared Gateway
    # Connection") did not reproduce here.
    #
  fi
done < <(echo "${vcf_a_provider_gws}" | jq -c -r .[])

#
# Associate every ip_space with every provider gateway - idempotent.
# This, not the ipSpaceRefs field on providerGateways, is the real
# mechanism (confirmed live: ipSpaceRefs reads back null regardless of
# what's sent, and a gateway configured that way shows no association
# in the UI either). Deliberately full cross-product (every ip_space to
# every gateway) - only a valid simplification while there is a single
# provider gateway; a real ip_space-to-gateway mapping would be needed
# if a second gateway is ever introduced. Confirmed live (51-org x
# 20-VIP batch test) that once associated this way, VIP allocation
# pools cleanly across every associated ip_space in sequence as each
# one fills, with zero errors.
#
vcfa_api GET "cloudapi/v1/ipSpaces" ""
all_ip_spaces=$(echo ${response_body} | jq -c '[.values[] | {id, name}]')
vcfa_api GET "cloudapi/v1/providerGateways" ""
all_provider_gws=$(echo ${response_body} | jq -c '[.values[] | {id, name}]')

echo "${all_provider_gws}" | jq -c -r '.[]' | while read pgw
do
  pgw_id=$(echo ${pgw} | jq -c -r '.id')
  pgw_name=$(echo ${pgw} | jq -c -r '.name')
  echo "${all_ip_spaces}" | jq -c -r '.[]' | while read ipspace
  do
    ipspace_id=$(echo ${ipspace} | jq -c -r '.id')
    ipspace_name=$(echo ${ipspace} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/ipSpaceAssociations?filter=ipSpaceRef.id==${ipspace_id};providerGatewayRef.id==${pgw_id}" ""
    existing_assoc=$(echo ${response_body} | jq -c -r '.values[0].id // empty')
    if [ -n "${existing_assoc}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${ipspace_name} already associated with ${pgw_name}, skipping" "${log_file}" "" ""
      continue
    fi
    assoc_json=$(jq -n --arg pgwid "${pgw_id}" --arg pgwname "${pgw_name}" --arg ipsid "${ipspace_id}" --arg ipsname "${ipspace_name}" \
      '{providerGatewayRef: {id: $pgwid, name: $pgwname}, ipSpaceRef: {id: $ipsid, name: $ipsname}}')
    vcfa_api POST "cloudapi/v1/ipSpaceAssociations" "${assoc_json}"
  done
done

#
# Create content libraries - idempotent. Shared, provider-wide resource
# like region/ipSpace/providerGateway above (NOT nested per-org) -
# confirmed live that a content library created here (system/provider
# portal, libraryType: PROVIDER) is visible from every org's own portal
# by default (isShared: true, isProjectScoped: false out of the box, no
# per-org share/attach step needed) - one library serves every org.
#
# storage class is looked up via cloudapi/v1/storageClasses, NOT
# cloudapi/v1/regionStoragePolicies (used elsewhere in this script for
# vDC storage policy assignment) - confirmed live both endpoints return
# the same underlying policy (identical UUID) but under different URN
# type prefixes (storageClass vs regionStoragePolicy), and contentLibraries
# creation specifically rejects the regionStoragePolicy-typed id ("The
# VCF Automation Tenant Manager entity urn:vcloud:storageClass:X does not
# exist" - note it silently re-typed the id in its own error message).
#
# status starts NOT_READY and reaches READY after ~30s with no explicit
# sync/action needed (unlike edgeClusters/aviControllers above) - this is
# just eventual consistency, confirmed live by polling.
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    cl_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/contentLibraries" ""
    cl_id=$(echo ${response_body} | jq -c -r --arg arg "${cl_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${cl_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library ${cl_name} already exists, skipping creation" "${log_file}" "" ""
    else
      vcfa_api GET "cloudapi/v1/storageClasses" ""
      storage_class_id=$(echo ${response_body} | jq -c -r --arg arg "${default_storage_class}" '.values[] | select(.name == $arg) | .id')
      cl_json=$(jq -n --arg n "${cl_name}" --arg scid "${storage_class_id}" \
        '{name: $n, storageClasses: [{id: $scid}]}')
      vcfa_api POST "cloudapi/v1/contentLibraries" "${cl_json}"

      retry_cl=6 ; pause_cl=10 ; attempt_cl=1
      while true
      do
        sleep ${pause_cl}
        vcfa_api GET "cloudapi/v1/contentLibraries" ""
        cl_status=$(echo ${response_body} | jq -c -r --arg arg "${cl_name}" '.values[] | select(.name == $arg) | .status')
        if [[ "${cl_status}" == "READY" ]]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library ${cl_name} READY after ${attempt_cl} attempts of ${pause_cl} seconds" "${log_file}" "" ""
          break
        fi
        ((attempt_cl++))
        if [ ${attempt_cl} -eq ${retry_cl} ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library ${cl_name} not READY after ${attempt_cl} attempts of ${pause_cl} seconds (status=${cl_status})" "${log_file}" "${slack_webhook}" "${google_webhook}"
          break
        fi
      done
      vcfa_api GET "cloudapi/v1/contentLibraries" ""
      cl_id=$(echo ${response_body} | jq -c -r --arg arg "${cl_name}" '.values[] | select(.name == $arg) | .id')
    fi

    #
    # Content library items (OVAs) - idempotent per item, independent of
    # whether the library itself was just created or already existed
    # (previously this whole item step was unreachable on re-runs because
    # the library-exists branch used `continue` - fixed here).
    #
    # Exactly one of ova_url (sddc/vCenter use case)/name (vApp/VCD use
    # case) per item - see crd-vapp.yaml's own description. Either way,
    # once ova_file exists locally it's extracted (a .ova is a plain tar
    # archive) and its .ovf descriptor's bytes PUT to the transferUrl VCFA
    # hands back. Confirmed live end-to-end with a real multi-file OVA
    # (lab-web-test-base-2.8.ova: .ovf + .vmdk + .nvram, 40MB): PUT the
    # descriptor -> re-GET files -> server lists the .vmdk AND .nvram (by
    # their real original filenames, matched against the extracted
    # directory here) with their own transferUrls -> PUT each -> item
    # reaches status READY with a real imageIdentifier assigned. The .mf
    # manifest is never listed for separate upload. A deliberately-invalid
    # descriptor was also confirmed to correctly surface as status FAILED
    # rather than silently succeed.
    #
    while read cl_item
    do
      if [ -n "${cl_item}" ] && [ "${cl_item}" != "null" ]; then
        ova_url=$(echo ${cl_item} | jq -c -r '.ova_url // empty')
        ova_name=$(echo ${cl_item} | jq -c -r '.name // empty')
        if [ -n "${ova_name}" ]; then
          item_name="${ova_name%.ova}"
        else
          # No separate name field for the url case - derived from the
          # URL's own filename (basename, .ova extension stripped).
          item_name="${ova_url##*/}"
          item_name="${item_name%.ova}"
        fi

        vcfa_api GET "cloudapi/v1/contentLibraryItems" ""
        item_id=$(echo ${response_body} | jq -c -r --arg arg "${item_name}" '.values[] | select(.name == $arg) | .id')
        if [ -n "${item_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} already exists, skipping" "${log_file}" "" ""
          continue
        fi

        ova_dir="/home/ubuntu/vcf-automation"
        ova_file="${ova_dir}/${item_name}.ova"
        extract_dir="${ova_dir}/${item_name}"
        mkdir -p "${ova_dir}" "${extract_dir}"

        if [ -n "${ova_name}" ]; then
          # vApp/VCD use case - already delivered via spec.vms.gw.iso's
          # generic ISO-passthrough loop, no download needed.
          if [ ! -f "/home/ubuntu/${ova_name}" ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item file ${ova_name} not found at /home/ubuntu/${ova_name} - was it added to vms.gw.iso's Iso CR?, skipping item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
            continue
          fi
          cp "/home/ubuntu/${ova_name}" "${ova_file}"
        else
          download_file_from_url_to_location "${ova_url}" "${ova_file}" "content library item ${item_name}"
        fi

        if [ -z "$(ls -A "${extract_dir}" 2>/dev/null)" ]; then
          tar -xf "${ova_file}" -C "${extract_dir}"
        fi
        ovf_file=$(find "${extract_dir}" -maxdepth 1 -name '*.ovf' | head -1)
        if [ -z "${ovf_file}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no .ovf found after extracting ${ova_file}, skipping item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi

        item_json=$(jq -n --arg n "${item_name}" --arg clid "${cl_id}" \
          '{name: $n, contentLibrary: {id: $clid}, itemType: "TEMPLATE"}')
        vcfa_api POST "cloudapi/v1/contentLibraryItems" "${item_json}"
        vcfa_api GET "cloudapi/v1/contentLibraryItems" ""
        item_id=$(echo ${response_body} | jq -c -r --arg arg "${item_name}" '.values[] | select(.name == $arg) | .id')
        if [ -z "${item_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to create content library item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi

        # descriptor upload - the server does NOT preserve the original
        # uploaded filename for this entry, it always renames it to the
        # literal "descriptor.ovf" regardless of what the local .ovf is
        # actually called (confirmed live: a lab-web-test-base-2.8.ovf
        # upload comes back re-listed as descriptor.ovf, not under its
        # own name) - so excluding disk files by comparing against the
        # LOCAL .ovf basename below is wrong and lets this renamed
        # descriptor entry slip through the filter as if it were a
        # missing disk file. Capture the server's own name for this
        # entry here instead, before uploading it, and exclude by THAT.
        vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}/files" ""
        descriptor_name=$(echo ${response_body} | jq -c -r '.values[0].name')
        descriptor_transfer_url=$(echo ${response_body} | jq -c -r '.values[0].transferUrl')
        curl -sk -X PUT "${descriptor_transfer_url}" -H "Authorization: Bearer ${vcfa_token}" --data-binary @"${ovf_file}" > /dev/null

        # disk file(s) - discovered from the server AFTER the descriptor
        # upload (see the caveat above); uploaded by matching each
        # server-reported file name against the extracted directory.
        sleep 5
        vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}/files" ""
        disk_files=$(echo ${response_body} | jq -c -r --arg descname "${descriptor_name}" '.values[] | select(.name != $descname) | @base64')
        for encoded_file in ${disk_files}; do
          disk_name=$(echo "${encoded_file}" | base64 -d | jq -c -r '.name')
          disk_transfer_url=$(echo "${encoded_file}" | base64 -d | jq -c -r '.transferUrl')
          local_disk_path="${extract_dir}/${disk_name}"
          if [ -f "${local_disk_path}" ]; then
            curl -sk -X PUT "${disk_transfer_url}" -H "Authorization: Bearer ${vcfa_token}" --data-binary @"${local_disk_path}" > /dev/null
          else
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: server-requested disk file ${disk_name} not found locally under ${extract_dir} for item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          fi
        done

        retry_item=12 ; pause_item=15 ; attempt_item=1
        while true
        do
          sleep ${pause_item}
          vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}" ""
          item_status=$(echo ${response_body} | jq -c -r '.status')
          if [[ "${item_status}" == "READY" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} READY after ${attempt_item} attempts of ${pause_item} seconds" "${log_file}" "" ""
            break
          fi
          if [[ "${item_status}" == "FAILED" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} status FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"
            break
          fi
          ((attempt_item++))
          if [ ${attempt_item} -eq ${retry_item} ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} not READY after ${attempt_item} attempts of ${pause_item} seconds (status=${item_status})" "${log_file}" "${slack_webhook}" "${google_webhook}"
            break
          fi
        done
      fi
    done < <(echo "${item}" | jq -c -r '.items // [] | .[]')
  fi
done < <(echo "${vcf_a_content_libraries}" | jq -c -r .[])

#
# configure orgs - the part actually exercised end-to-end live (org-1
# already existed; org-2 and org-3 were created and fully verified this
# way, including org-3 deliberately skipping the aviSetting step).
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    org_name=$(echo ${item} | jq -c -r '.name')
    region_ref_name=$(echo ${item} | jq -c -r '.region_ref')
    enable_avi=$(echo ${item} | jq -c -r '.enable_avi // true')

    #
    # org - idempotent. Uses filter=name==X (server-side exact match)
    # rather than an unpaginated GET + client-side jq select - confirmed
    # live at 50+ org scale that cloudapi/1.0.0/orgs silently caps its
    # response at 32 values NO MATTER what pageSize is requested (even
    # pageSize=200 made no difference), so beyond ~32 total orgs a plain
    # GET-and-jq-select lookup would falsely report a brand-new org as
    # "not found" even though it was created successfully, and the
    # script would then attempt to create it a second time. filter=
    # queries the server directly for the exact name and always returns
    # the right single record regardless of total org count.
    #
    vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
    org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
    if [ -z "${org_id}" ]; then
      org_json=$(jq -n --arg n "${org_name}" '{name: $n, displayName: $n, description: "", isClassicTenant: false, isEnabled: true}')
      vcfa_api POST "cloudapi/1.0.0/orgs" "${org_json}"
      sleep 3
      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: org ${org_name} already exists, skipping creation" "${log_file}" "" ""
    fi

    vcfa_api GET "cloudapi/v1/regions" ""
    region_id=$(echo ${response_body} | jq -c -r --arg arg "${region_ref_name}" '.values[] | select(.name == $arg) | .id')

    #
    # virtual datacenter - idempotent. Fixes two real bugs in the
    # original: a missing '}' after the supervisor id (invalid JSON,
    # would never actually have POSTed), and zoneResourceAllocation
    # referencing ${zone_id}/${zone_name} that were never actually set
    # anywhere in that script - now taken from each org's own input.
    #
    vdc_name="${org_name}_region-1"
    vcfa_api GET "cloudapi/v1/virtualDatacenters?filter=name==${vdc_name}" ""
    vdc_id=$(echo ${response_body} | jq -c -r --arg arg "${vdc_name}" '.values[] | select(.name == $arg) | .id')
    if [ -z "${vdc_id}" ]; then
      vcfa_api GET "cloudapi/v1/virtualMachineClasses" ""
      vm_classes=$(echo ${response_body} | jq -c -r '[.values[] | {id, name}]')
      # zone_ref/zone_id are NOT input fields - derived here the same way
      # as storage_class_ref (see the storage policy step below): each
      # region has exactly one zone (confirmed live), so filter
      # cloudapi/v1/zones by this org's region_id and take that one
      # match, instead of requiring a literal URN to be known up front -
      # a URN that, for a brand-new SDDC being built by this same
      # project, cannot exist yet at CR-authoring time.
      vcfa_api GET "cloudapi/v1/zones" ""
      zone_id=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .id' | head -1)
      zone_name=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .name' | head -1)
      cpu_limit_mhz=$(echo ${item} | jq -c -r '.cpu_limit_mhz')
      memory_limit_mib=$(echo ${item} | jq -c -r '.memory_limit_mib')

      vdc_json=$(jq -n --arg n "${vdc_name}" --arg orgid "${org_id}" --arg regionid "${region_id}" \
        --arg supname "${supervisor_name}" --arg supid "${supervisor_id}" \
        --arg zoneid "${zone_id}" --arg zonename "${zone_name}" \
        --argjson cpulimit "${cpu_limit_mhz}" --argjson memlimit "${memory_limit_mib}" \
        '{name: $n, description: null, org: {id: $orgid}, region: {id: $regionid},
          supervisors: [{name: $supname, id: $supid}],
          zoneResourceAllocation: [{zone: {id: $zoneid, name: $zonename},
            resourceAllocation: {cpuLimitMHz: $cpulimit, cpuReservationMHz: 0, memoryLimitMiB: $memlimit, memoryReservationMiB: 0}}],
          isFullAllocation: false}')
      vcfa_api POST "cloudapi/v1/virtualDatacenters" "${vdc_json}"
      sleep 3
      vcfa_api GET "cloudapi/v1/virtualDatacenters?filter=name==${vdc_name}" ""
      vdc_id=$(echo ${response_body} | jq -c -r --arg arg "${vdc_name}" '.values[] | select(.name == $arg) | .id')

      #
      # VM classes - assign every available class, matching org-1
      #
      vcfa_api PUT "cloudapi/v1/virtualDatacenters/${vdc_id}/virtualMachineClasses" "{\"values\":${vm_classes}}"

      #
      # Storage policy - fixes the original's bug where json_data was
      # built correctly here then immediately overwritten by the
      # previous step's vm_classes payload copy-pasted in by mistake.
      #
      # storage_policy_ref is not part of the org input - it's built from
      # ${default_storage_class} (bash/variables.sh), the same variable
      # already used to attach this policy to the region in the
      # "configure regions" step above, rather than requiring its name to
      # be duplicated in every org/template.
      storage_policy_ref="${default_storage_class}"
      vcfa_api GET "cloudapi/v1/regionStoragePolicies" ""
      storage_policy_id=$(echo ${response_body} | jq -c -r --arg arg "${storage_policy_ref}" '.values[] | select(.name == $arg) | .id')
      storage_limit_mib=$(echo ${item} | jq -c -r '.storage_limit // 102400')
      storage_json=$(jq -n --arg spid "${storage_policy_id}" --argjson limit "${storage_limit_mib}" --arg vdcid "${vdc_id}" \
        '{values: [{regionStoragePolicy: {id: $spid}, storageLimitMiB: $limit, virtualDatacenter: {id: $vdcid}}]}')
      vcfa_api PUT "cloudapi/v1/virtualDatacenters/${vdc_id}/virtualDatacenterStoragePolicies" "${storage_json}"
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vDC ${vdc_name} already exists, skipping creation" "${log_file}" "" ""
    fi

    #
    # Regional networking settings - idempotent. filter=orgRef.name==X
    # for the same reason as the org/vDC lookups above - confirmed live
    # this endpoint has the identical 32-item pageSize cap.
    #
    org_uuid="${org_id##*:}"
    vcfa_api GET "cloudapi/v1/regionalNetworkingSettings?filter=orgRef.name==${org_name}" ""
    rns_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .id')
    if [ -z "${rns_id}" ]; then
      pgw_name=$(echo ${item} | jq -c -r '.provider_gateway_ref')
      edge_cluster_name=$(echo ${item} | jq -c -r '.edge_cluster_ref')
      vcfa_api GET "cloudapi/v1/providerGateways" ""
      pgw_id=$(echo ${response_body} | jq -c -r --arg arg "${pgw_name}" '.values[] | select(.name == $arg) | .id')
      vcfa_api GET "cloudapi/v1/edgeClusters" ""
      edge_id=$(echo ${response_body} | jq -c -r --arg arg "${edge_cluster_name}" '.values[] | select(.name == $arg) | .id')
      if [ -z "${edge_id}" ]; then
        #
        # A brand-new region's edge cluster is not discovered automatically -
        # confirmed live (both the vcf9 lab and a second, independent
        # VCD/VCFA environment) that cloudapi/v1/edgeClusters/sync (no
        # region/id in the path, triggers NSX transport-node discovery) is
        # required first. Try it once, wait, and re-check before giving up.
        #
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: edge cluster ${edge_cluster_name} not found for ${org_name}, triggering cloudapi/v1/edgeClusters/sync" "${log_file}" "" ""
        vcfa_api POST "cloudapi/v1/edgeClusters/sync" ""
        sleep 60
        vcfa_api GET "cloudapi/v1/edgeClusters" ""
        edge_id=$(echo ${response_body} | jq -c -r --arg arg "${edge_cluster_name}" '.values[] | select(.name == $arg) | .id')
        if [ -z "${edge_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: edge cluster ${edge_cluster_name} still not found for ${org_name} after edgeClusters/sync" "${log_file}" "${slack_webhook}" "${google_webhook}"
          exit 100
        fi
      fi

      net_json=$(jq -n --arg n "${org_name}" --arg orgid "${org_id}" --arg rn "${region_ref_name}" --arg regionid "${region_id}" \
        --arg pgwn "${pgw_name}" --arg pgwid "${pgw_id}" --arg edgen "${edge_cluster_name}" --arg edgeid "${edge_id}" \
        '{orgRef: {name: $n, id: $orgid}, regionRef: {name: $rn, id: $regionid},
          providerGatewayRef: {name: $pgwn, id: $pgwid}, serviceEdgeClusterRef: {name: $edgen, id: $edgeid}}')

      #
      # Create + poll to REALIZED, then verify the underlying NSX Project
      # actually exists before trusting it - confirmed live at 50-org
      # scale that VCFA's regionalNetworkingSettings can report status
      # REALIZED while the NSX Project backing that org's VPC was never
      # actually created at all (root cause never fully pinned down;
      # observed as a clean alternating every-other-org failure when 51
      # orgs' regionalNetworkingSettings were POSTed back-to-back with no
      # pacing between them - real NSX Manager/Avi were both healthy).
      # This is a genuine backend gap: nothing in VCFA's own API surface
      # (status, aviSetting errors) reveals it - the only reliable check
      # is GETting the org's NSX Project directly. One delete+recreate
      # retry (confirmed live to fully resolve it every time across 25
      # affected orgs) before giving up for good.
      #
      for rns_attempt in 1 2; do
        vcfa_api POST "cloudapi/v1/regionalNetworkingSettings" "${net_json}"

        retry_rns=12 ; pause_rns=10 ; attempt_rns=1 ; rns_realized=false
        while true
        do
          sleep ${pause_rns}
          vcfa_api GET "cloudapi/v1/regionalNetworkingSettings?filter=orgRef.name==${org_name}" ""
          rns_status=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .status')
          rns_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .id')
          if [[ "${rns_status}" == "REALIZED" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} REALIZED after ${attempt_rns} attempts of ${pause_rns} seconds" "${log_file}" "" ""
            rns_realized=true
            break
          fi
          ((attempt_rns++))
          if [ ${attempt_rns} -eq ${retry_rns} ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} not REALIZED after ${attempt_rns} attempts of ${pause_rns} seconds (status=${rns_status})" "${log_file}" "${slack_webhook}" "${google_webhook}"
            exit 100
          fi
        done

        nsx_project_id=$(curl -sk -u "admin:${generic_password}" "https://${ip_nsx_vip}/policy/api/v1/orgs/default/projects/${org_uuid}" | jq -r '.id // empty')
        if [ "${nsx_project_id}" == "${org_uuid}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: NSX Project confirmed present for ${org_name}" "${log_file}" "" ""
          break
        fi

        if [ ${rns_attempt} -eq 2 ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: NSX Project still missing for ${org_name} after delete+recreate retry - regionalNetworkingSettings reports REALIZED but is not actually backed by NSX, giving up" "${log_file}" "${slack_webhook}" "${google_webhook}"
          exit 100
        fi
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: NSX Project missing for ${org_name} despite REALIZED status - deleting and recreating regionalNetworkingSettings once" "${log_file}" "" ""
        vcfa_api DELETE "cloudapi/v1/regionalNetworkingSettings/${rns_id}" ""
        sleep 10
      done
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} already exists, skipping creation" "${log_file}" "" ""
    fi

    #
    # Avi / Load Balancing regional setting - not present anywhere in the
    # original script; found only via the VCFA UI's own network calls.
    # Optional per-org via enable_avi (defaults to true) - set to false to
    # leave an org's Load Balancing section deliberately empty.
    #
    # Two modes, each with a DIFFERENT quota field name (confirmed live,
    # not documented anywhere):
    #   - TENANT_MANAGED: org self-provisions its own service engines.
    #     Quota -> serviceEngineQuota. No SEG reference needed.
    #   - PROVIDER_MANAGED: org is pinned to one specific, already-existing
    #     provider Avi service engine group. Quota -> applicationLimit
    #     instead, and serviceEngineGroupRefs (resolved by name via
    #     cloudapi/v1/loadBalancer/aviServiceEngineGroups, filtered by
    #     this org's region) is required.
    #
    if [ "${enable_avi}" == "true" ]; then
      avi_mode=$(echo ${item} | jq -c -r '.avi_mode // "TENANT_MANAGED"')
      avi_quota=$(echo ${item} | jq -c -r '.avi_quota // 10')
      if [ "${avi_mode}" == "PROVIDER_MANAGED" ]; then
        #
        # Confirmed live: VCFA can reject a PROVIDER_MANAGED aviSetting
        # ("service engine group has not been assigned") even though the
        # PUT itself returns 202 and the SEG is already GET-able, unless
        # the avi controller has been synced first. Sync once per script
        # run (avi_synced flag), not once per org - it's a controller-wide
        # action, not org- or SEG-scoped.
        #
        if [ -z "${avi_synced:-}" ]; then
          vcfa_api GET "cloudapi/v1/loadBalancer/aviControllers?filter=regionRef.id==${region_id}" ""
          avi_controller_id=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.regionRef.id == $arg) | .id' | head -1)
          if [ -n "${avi_controller_id}" ]; then
            vcfa_api POST "cloudapi/v1/loadBalancer/aviControllers/${avi_controller_id}/sync" ""
            sleep 30
          fi
          avi_synced=true
        fi
        seg_name=$(echo ${item} | jq -c -r '.avi_service_engine_group_ref')
        vcfa_api GET "cloudapi/v1/loadBalancer/aviServiceEngineGroups?filter=regionRef.id==${region_id}" ""
        seg_id=$(echo ${response_body} | jq -c -r --arg arg "${seg_name}" '.values[] | select(.name == $arg) | .id')
        if [ -z "${seg_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: avi service engine group ${seg_name} not found for ${org_name}, skipping aviSetting" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          avi_json=$(jq -n --argjson limit "${avi_quota}" --arg segid "${seg_id}" \
            '{active: true, serviceEngineGroupMode: "PROVIDER_MANAGED", applicationLimit: $limit, serviceEngineGroupRefs: [{id: $segid}]}')
          vcfa_api PUT "cloudapi/v1/regionalNetworkingSettings/${rns_id}/aviSetting" "${avi_json}"
        fi
      else
        avi_json=$(jq -n --argjson quota "${avi_quota}" \
          '{active: true, serviceEngineGroupMode: "TENANT_MANAGED", serviceEngineQuota: $quota}')
        vcfa_api PUT "cloudapi/v1/regionalNetworkingSettings/${rns_id}/aviSetting" "${avi_json}"
      fi
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: enable_avi=false for ${org_name}, leaving aviSetting inactive" "${log_file}" "" ""
    fi

    #
    # Assign a user to the VCF-A org - optional, deliberately left
    # commented out here: the original script hardcoded a real username
    # AND plaintext password directly in the file. Never commit real
    # credentials to a script - source both from this project's own
    # secrets handling (e.g. the same generic_password/vault mechanism
    # used elsewhere) if you need this step.
    #
    # user_json=$(jq -n --arg u "${org_admin_username}" --arg p "${org_admin_password}" --arg roleid "${org_admin_role_id}" \
    #   '{username: $u, password: $p, roleEntityRefs: [{id: $roleid, name: "Organization Administrator"}], providerType: "LOCAL"}')
    # vcfa_api POST "cloudapi/1.0.0/users" "${user_json}"
  fi
done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

#
# Namespace provisioning - org-portal phase, run AFTER every org above is
# fully configured from the system/provider portal. One supervisor
# namespace per eligible org (item.namespace.enabled == true), created via
# an org-scoped OAuth token rather than the provider Bearer token used
# everywhere above - VCFA has no provider-level API for this, it's
# inherently a tenant self-service action.
#
# PROVIDER_MANAGED ONLY for now: namespace creation requires a segName
# unconditionally ("SEG is required when creating namespace on region with
# NSX_REGISTERED_AVI LB type..."), confirmed live - for PROVIDER_MANAGED
# orgs that's just avi_service_engine_group_ref. TENANT_MANAGED orgs have
# no equivalent SEG yet (needs its own new SEG created via VCF-A first) -
# deliberately parked, so any org with namespace.enabled but avi_mode !=
# PROVIDER_MANAGED is skipped with a log message rather than guessed at.
#
# Auth: provider Bearer token -> org-scoped OAuth token via jwt-bearer
# exchange, matching templates/vcfa_select_ns.sh.template's documented
# flow (https://vrealize.it/2025/12/04/vcf-automation-9-programmatic-token-generation/).
# A fresh org token is requested per org (org tokens are short-lived and
# org-specific, unlike the one long-lived provider token reused above).
# KNOWN LIMITATION: unlike vcfa_api, cci_api below does not re-request the
# org token on expiry mid-poll - the poll loop (up to 12x15s=3min after
# creation) could plausibly outlast a short-lived org token on some
# systems. Not yet hit live; if the poll starts failing partway through
# with 401s, that's the fix needed.
#
# VPC and namespace name are deliberately not input fields (see the CRD's
# own comments on organization_templates.namespace) - the org's default
# VPC is deterministically named "default-${region_ref}" (confirmed live:
# org-3's is "default-region-1"), and the API requires
# metadata.generateName (never a fixed name), so idempotency here is by
# name PREFIX match ("${org_name}-ns-") rather than exact name.
#
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

vcfa_api GET "cloudapi/1.0.0/openIdProvider/relyingParties" ""
client_id=$(echo ${response_body} | jq -c -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
if [ -z "${client_id}" ] || [ "${client_id}" == "null" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: could not determine the automation relying party clientId, skipping all namespace provisioning" "${log_file}" "${slack_webhook}" "${google_webhook}"
else
  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
      region_ref_name=$(echo ${item} | jq -c -r '.region_ref')
      namespace_enabled=$(echo ${item} | jq -c -r '.namespace.enabled // false')
      if [ "${namespace_enabled}" != "true" ]; then
        continue
      fi
      avi_mode=$(echo ${item} | jq -c -r '.avi_mode // "TENANT_MANAGED"')
      seg_name=$(echo ${item} | jq -c -r '.avi_service_engine_group_ref')
      if [ "${avi_mode}" != "PROVIDER_MANAGED" ] || [ -z "${seg_name}" ] || [ "${seg_name}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${org_name} has namespace.enabled but avi_mode is not PROVIDER_MANAGED (or has no SEG) - TENANT_MANAGED namespace provisioning is not yet supported, skipping" "${log_file}" "" ""
        continue
      fi

      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
      org_uuid="${org_id##*:}"

      vcfa_api GET "cloudapi/v1/regions" ""
      region_id=$(echo ${response_body} | jq -c -r --arg arg "${region_ref_name}" '.values[] | select(.name == $arg) | .id')

      vcfa_api GET "cloudapi/v1/regionStoragePolicies" ""
      storage_class_k8s_name=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .kubernetesCompliantName' | head -1)

      org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
        -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${vcfa_token}" \
        --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
      if [ -z "${org_token}" ] || [ "${org_token}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to obtain an org-scoped token for ${org_name}, skipping its namespace" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      project="default-project"
      cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces" "" "${org_token}"
      ns_name=$(echo ${response_body} | jq -c -r --arg arg "${org_name}-ns-" '.items[] | select(.metadata.name | startswith($arg)) | .metadata.name' | head -1)
      if [ -n "${ns_name}" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace for ${org_name} already exists (${ns_name}), skipping creation" "${log_file}" "" ""
      else
        # zone_ref is NOT an input field here either - same derivation
        # as the vDC creation step above (one zone per region).
        vcfa_api GET "cloudapi/v1/zones" ""
        zone_name=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .name' | head -1)
        namespace_class=$(echo ${item} | jq -c -r '.namespace.class // "small"')
        namespace_cpu_limit_mhz=$(echo ${item} | jq -c -r '.namespace.cpu_limit_mhz')
        namespace_memory_limit_mib=$(echo ${item} | jq -c -r '.namespace.memory_limit_mib')
        namespace_storage_limit_mib=$(echo ${item} | jq -c -r '.namespace.storage_limit_mib')

        ns_json=$(jq -n --arg prefix "${org_name}-ns-" --arg project "${project}" \
          --arg region "${region_ref_name}" --arg class "${namespace_class}" \
          --arg vpc "default-${region_ref_name}" --arg seg "${seg_name}" \
          --arg zonename "${zone_name}" --arg cpulimit "${namespace_cpu_limit_mhz}M" --arg memlimit "${namespace_memory_limit_mib}Mi" \
          --arg storagename "${storage_class_k8s_name}" --arg storagelimit "${namespace_storage_limit_mib}Mi" \
          '{apiVersion: "infrastructure.cci.vmware.com/v1alpha3", kind: "SupervisorNamespace",
            metadata: {generateName: $prefix, namespace: $project},
            spec: {regionName: $region, className: $class, vpcName: $vpc, segName: $seg,
              classConfigOverrides: {
                zones: [{name: $zonename, cpuLimit: $cpulimit, cpuReservation: "0", memoryLimit: $memlimit, memoryReservation: "0"}],
                storageClasses: [{name: $storagename, limit: $storagelimit}]
              }}}')
        cci_api POST "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces" "${ns_json}" "${org_token}"
        if [ $? -ne 0 ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace creation for ${org_name} FAILED, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi
        ns_name=$(echo ${response_body} | jq -c -r '.metadata.name')

        retry_ns=12 ; pause_ns=15 ; attempt_ns=1
        while true
        do
          sleep ${pause_ns}
          cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces/${ns_name}" "" "${org_token}"
          ns_phase=$(echo ${response_body} | jq -c -r '.status.phase')
          if [[ "${ns_phase}" == "Created" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace ${ns_name} for ${org_name} reached phase Created after ${attempt_ns} attempts of ${pause_ns} seconds" "${log_file}" "" ""
            break
          fi
          ((attempt_ns++))
          if [ ${attempt_ns} -eq ${retry_ns} ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace ${ns_name} for ${org_name} not Created after ${attempt_ns} attempts of ${pause_ns} seconds (phase=${ns_phase})" "${log_file}" "${slack_webhook}" "${google_webhook}"
            break
          fi
        done
      fi

      #
      # VM Service content library binding - a separate, lower layer than
      # VCFA's own "content library visible from every org's portal"
      # sharing above (cloudapi/v1/contentLibraries, done once for all
      # orgs) - confirmed live (blueprint admission webhook error:
      # VirtualMachineImage "vmi-..." not found, traced down to vCenter's
      # own API) that VM Service only projects a content library's items
      # into a namespace as VirtualMachineImage objects if that library's
      # vCenter-NATIVE uuid is explicitly listed in the namespace's own
      # vm_service_spec.content_libraries (vCenter's
      # api/vcenter/namespaces/instances/{ns} API) - a completely
      # different id space than VCFA's own urn:vcloud:contentLibrary:...
      # id, so the two can't just be string-matched. VCFA-level "shared"
      # visibility alone does NOT populate this. Every
      # vcf_a_content_libraries entry is provider-wide/shared by design
      # (see the "one library serves every org" comment above), so all of
      # them are bound to every eligible org's namespace here
      # automatically - no new CRD field needed. Existing entries (e.g. a
      # tenant's own org-created library, confirmed live to exist
      # side-by-side) are preserved by merging rather than overwriting.
      # Runs regardless of whether ns_name was just created above or
      # already existed, same as the Vault step below, since an
      # already-existing namespace from before this step existed would
      # otherwise never get the binding retrofitted.
      #
      if [ -n "${ns_name}" ]; then
        create_vcenter_api_session
        vcenter_api 3 3 GET "api/content/library" ""
        all_lib_ids=$(echo "${response_body}" | jq -r '.[]')
        vc_lib_uuids=""
        while read -r shared_cl_name
        do
          [ -z "${shared_cl_name}" ] && continue
          for lib_id in ${all_lib_ids}; do
            vcenter_api 3 3 GET "api/content/library/${lib_id}" ""
            lib_name=$(echo "${response_body}" | jq -r '.name')
            if [ "${lib_name}" == "${shared_cl_name}" ]; then
              vc_lib_uuids="${vc_lib_uuids} ${lib_id}"
              break
            fi
          done
        done < <(echo "${vcf_a_content_libraries}" | jq -c -r '.[].name')

        if [ -n "$(echo ${vc_lib_uuids})" ]; then
          vcenter_api 3 3 GET "api/vcenter/namespaces/instances/${ns_name}" ""
          existing_libs=$(echo "${response_body}" | jq -c '.vm_service_spec.content_libraries // []')
          merged_libs=$(jq -n --argjson existing "${existing_libs}" --arg new "${vc_lib_uuids}" \
            '$existing + ($new | split(" ") | map(select(length > 0))) | unique')
          patch_json=$(jq -n --argjson libs "${merged_libs}" '{vm_service_spec: {content_libraries: $libs}}')
          vcenter_api 3 3 PATCH "api/vcenter/namespaces/instances/${ns_name}" "${patch_json}"
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: bound shared content libraries to namespace ${ns_name}'s vm_service_spec.content_libraries (${merged_libs})" "${log_file}" "" ""
        fi
      fi

      #
      # Vault cert-manager bootstrap - runs kubectl directly against the
      # Supervisor cluster (NOT VCFA's own API - these are plain K8s
      # objects VCFA doesn't manage), once this org's namespace is
      # confirmed present, regardless of whether it was just created
      # above or already existed (kubectl apply is idempotent, safe to
      # re-run every time this script runs).
      #
      # secret_vault.yaml/vault_issuer.yaml are raw placeholder templates
      # from demoavi/dev-avi-vcf (gw's own userdata clones that repo and
      # copies every yamls/*.yaml file into /home/ubuntu/${yaml_folder}/
      # untouched, since neither Kind is in the demo-yaml by-Kind dispatch
      # there) - ALL their real values are filled in here instead, per
      # org/namespace, using yq (mikefarah/yq, installed at
      # /usr/local/bin/yq by gw's own userdata). This has to happen here
      # rather than in cloud-init because the actual namespace name isn't
      # known until VCF-A creates it under this org (well after gw's own
      # first boot) - cloud-init is simply too early for that value, even
      # though the OTHER fields (vault token/server/path/caBundle) are
      # already knowable at cloud-init time. Keeping every substitution in
      # one place (here) rather than splitting them across cloud-init and
      # this script is deliberate, since this script is the one meant to
      # be ported to the local epc-vapp project later - having the whole
      # mechanism self-contained here keeps that port simple.
      #
      # A source-file kind/name sanity check guards against silently
      # patching the wrong file if the templates in dev-avi-vcf/yamls/
      # ever get renamed/restructured.
      #
      # auth_supervisor_custer.sh switches the local kubectl/vcf CLI
      # context to the Supervisor cluster itself (sup-admin-01) -
      # confirmed live this must run first, since a stale context left
      # over from other kubectl usage (e.g. a VKS workload cluster's own
      # context) otherwise causes TLS/cert errors reaching the
      # Supervisor's namespaces. Re-run per org rather than once for the
      # whole script, since a long batch run across many orgs could
      # plausibly outlast the CLI's own token (not yet observed live,
      # but a real risk given how long the aviSetting/
      # regionalNetworkingSettings polling elsewhere in this script can
      # already run).
      #
      vault_integration_enabled=$(echo ${item} | jq -c -r '.namespace.vault_integration.enabled // false')
      if [ -n "${ns_name}" ] && [ "${vault_integration_enabled}" == "true" ]; then
        bash /home/ubuntu/supervisor/auth_supervisor_custer.sh >/dev/null 2>&1

        secret_kind="$(yq '.kind' /home/ubuntu/${yaml_folder}/secret_vault.yaml)"
        secret_name="$(yq '.metadata.name' /home/ubuntu/${yaml_folder}/secret_vault.yaml)"
        issuer_kind="$(yq '.kind' /home/ubuntu/${yaml_folder}/vault_issuer.yaml)"
        if [ "${secret_kind}" != "Secret" ] || [ "${secret_name}" != "cert-manager-vault-token" ] || [ "${issuer_kind}" != "Issuer" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: secret_vault.yaml/vault_issuer.yaml have unexpected kind/name (secret_kind=${secret_kind}, secret_name=${secret_name}, issuer_kind=${issuer_kind}), skipping vault bootstrap for ${org_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          cp /home/ubuntu/${yaml_folder}/secret_vault.yaml "/tmp/${org_name}-secret_vault.yaml"
          yq -i ".metadata.namespace = \"${ns_name}\"" "/tmp/${org_name}-secret_vault.yaml"
          yq -i ".data.token = \"$(echo -n $(jq -c -r .root_token ${vault_secret_file_path}) | base64)\"" "/tmp/${org_name}-secret_vault.yaml"

          cp /home/ubuntu/${yaml_folder}/vault_issuer.yaml "/tmp/${org_name}-vault_issuer.yaml"
          yq -i ".metadata.namespace = \"${ns_name}\"" "/tmp/${org_name}-vault_issuer.yaml"
          yq -i ".spec.vault.server = \"https://${ip_gw}:8200\"" "/tmp/${org_name}-vault_issuer.yaml"
          yq -i ".spec.vault.path = \"${vault_pki_intermediate_name}/sign/${vault_pki_intermediate_role_name}\"" "/tmp/${org_name}-vault_issuer.yaml"
          # /opt/vault/tls/tls.crt is vault:vault 0600 - unreadable by this
          # script's own ubuntu user (unlike cloud-init, which built this
          # same value while still running as root) - confirmed live this
          # user has passwordless sudo, so read it that way instead.
          yq -i ".spec.vault.caBundle = \"$(sudo cat /opt/vault/tls/tls.crt | base64 -w0)\"" "/tmp/${org_name}-vault_issuer.yaml"

          kubectl_out=$( { kubectl apply -f "/tmp/${org_name}-secret_vault.yaml" && kubectl apply -f "/tmp/${org_name}-vault_issuer.yaml"; } 2>&1 )
          if [ $? -eq 0 ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vault secret + issuer applied for ${org_name} in namespace ${ns_name}" "${log_file}" "" ""
          else
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vault secret/issuer apply FAILED for ${org_name} in namespace ${ns_name}, output: ${kubectl_out}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          fi
          rm -f "/tmp/${org_name}-secret_vault.yaml" "/tmp/${org_name}-vault_issuer.yaml"
        fi
      fi

      #
      # VKS cluster - very simple data model (vks_cluster.enabled only,
      # everything else stays at the UI's own "create with defaults"
      # values) - confirmed live against org-3's own namespace using the
      # exact topology observed on org-1's manually-created cluster
      # (kubernetes-cluster-q4md): ClusterClass builtin-generic-v3.6.0,
      # k8s v1.35.5+vmware.1, 1 control-plane + 1 worker replica,
      # vmClass best-effort-medium. Confirmed live it's
      # cluster.x-k8s.io/v1beta2 that the UI actually uses (v1beta1 is
      # accepted but deprecated AND rejects the request unless
      # clusterNetwork.services is also set - v1beta2 doesn't need that
      # worked around). storageClass reuses ${storage_class_k8s_name}
      # already derived above for the namespace step, rather than
      # re-deriving it. The cluster starts with spec.paused: true
      # (set automatically by an admission webhook) and clears itself
      # within seconds with no action needed - confirmed live the
      # cluster then proceeds through normal machine provisioning
      # (phase: Provisioned, InfrastructureReady: True) with no
      # equivalent of org-1's "run.tanzu.vmware.com/resolve-os-image"
      # annotation required (the ClusterClass resolves a default OS
      # image on its own when that annotation is omitted).
      #
      # Confirmed live end-to-end (not just Provisioned): a second test
      # cluster created in org-1's own namespace with this exact payload
      # reached status.conditions[type=Available].status == "True"
      # (fully Ready) after ~8-10 minutes - CNI (Antrea) and the
      # vsphere-csi addon both take a few minutes to finish reconciling
      # after the nodes first come up, which is normal and not itself a
      # failure signal even though AddonsReconciled briefly reports
      # ReconcileFailed/timed-out during that window. A separate cluster
      # created in org-3's namespace stayed stuck well past that window
      # in this same test session - suspected to be an environment-
      # specific resource constraint (e.g. underlying vSAN capacity) on
      # that particular namespace/org, not a payload or script issue.
      #
      # Idempotency is by PRESENCE, not name (the API only supports
      # generateName, never a fixed name) - "one default cluster per
      # org" is the intent per vks_cluster's simple enable/disable model,
      # so if ANY cluster already exists in the namespace, none is
      # created.
      #
      vks_enabled=$(echo ${item} | jq -c -r '.vks_cluster.enabled // false')
      vks_count=$(echo ${item} | jq -c -r '.vks_cluster.count // 1')
      if [ "${vks_count}" != "1" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${org_name} has vks_cluster.count=${vks_count}, but only 1 is supported today - creating exactly 1" "${log_file}" "" ""
      fi
      if [ "${vks_enabled}" == "true" ] && [ -n "${ns_name}" ]; then
        cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces/${ns_name}" "" "${org_token}"
        ns_endpoint=$(echo ${response_body} | jq -c -r '.status.namespaceEndpointURL')
        if [ -z "${ns_endpoint}" ] || [ "${ns_endpoint}" == "null" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no namespaceEndpointURL for ${ns_name} (${org_name}), skipping VKS cluster" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          ns_k8s_api GET "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters" "" "${org_token}"
          existing_vks=$(echo ${response_body} | jq -c -r '.items[0].metadata.name')
          if [ -n "${existing_vks}" ] && [ "${existing_vks}" != "null" ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster for ${org_name} already exists (${existing_vks}), skipping creation" "${log_file}" "" ""
          else
            vks_json=$(jq -n --arg ns "${ns_name}" --arg storagename "${storage_class_k8s_name}" \
              '{apiVersion: "cluster.x-k8s.io/v1beta2", kind: "Cluster",
                metadata: {generateName: "vks-cluster-", namespace: $ns},
                spec: {
                  clusterNetwork: {serviceDomain: "cluster.local", services: {cidrBlocks: ["10.96.0.0/12"]}},
                  topology: {
                    classRef: {name: "builtin-generic-v3.6.0", namespace: "vmware-system-vks-public"},
                    version: "v1.35.5+vmware.1",
                    controlPlane: {replicas: 1},
                    workers: {machineDeployments: [{class: "node-pool", name: "node-pool-1", replicas: 1}]},
                    variables: [
                      {name: "vmClass", value: "best-effort-medium"},
                      {name: "storageClass", value: $storagename}
                    ]
                  }
                }}')
            ns_k8s_api POST "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters" "${vks_json}" "${org_token}"
            if [ $? -ne 0 ]; then
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster creation for ${org_name} FAILED, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
            else
              vks_name=$(echo ${response_body} | jq -c -r '.metadata.name')
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} created, will check Available status in a later pass (see below) once every org's cluster has been created" "${log_file}" "" ""
            fi
          fi
        fi
      fi
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

  #
  # VKS cluster status polling - a SEPARATE pass, run only after every
  # org's cluster has already been created above. Deliberately decoupled
  # from creation so N clusters bootstrap in parallel server-side, rather
  # than this script blocking org 1's several-minutes-long node bootstrap
  # before even starting org 2's cluster creation.
  #
  # Terminates on status.conditions[] type=="Available" status=="True" -
  # confirmed live this is CAPI's own top-level cluster-wide readiness
  # signal (control plane + all workers healthy), NOT the same as
  # phase=="Provisioned" (only means the topology/infra request was
  # accepted - observed within seconds of creation while nodes were
  # still booting, long before Available flips true).
  #
  # Re-derives org token/namespace/cluster name from scratch per org
  # rather than reusing anything from the creation loop above, since bash
  # doesn't carry per-iteration loop state across two separate while-read
  # loops - same GET-by-name approach used throughout this script.
  #
  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
      vks_enabled=$(echo ${item} | jq -c -r '.vks_cluster.enabled // false')
      if [ "${vks_enabled}" != "true" ]; then
        continue
      fi

      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
      org_uuid="${org_id##*:}"
      org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
        -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${vcfa_token}" \
        --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
      if [ -z "${org_token}" ] || [ "${org_token}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to obtain an org-scoped token for ${org_name}, skipping its VKS status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      project="default-project"
      cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces" "" "${org_token}"
      ns_name=$(echo ${response_body} | jq -c -r --arg arg "${org_name}-ns-" '.items[] | select(.metadata.name | startswith($arg)) | .metadata.name' | head -1)
      if [ -z "${ns_name}" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no namespace found for ${org_name}, skipping VKS status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi
      cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces/${ns_name}" "" "${org_token}"
      ns_endpoint=$(echo ${response_body} | jq -c -r '.status.namespaceEndpointURL')
      if [ -z "${ns_endpoint}" ] || [ "${ns_endpoint}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no namespaceEndpointURL for ${ns_name} (${org_name}), skipping VKS status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      ns_k8s_api GET "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters" "" "${org_token}"
      vks_name=$(echo ${response_body} | jq -c -r '.items[0].metadata.name')
      if [ -z "${vks_name}" ] || [ "${vks_name}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no VKS cluster found for ${org_name} in namespace ${ns_name}, skipping status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      retry_vks=40 ; pause_vks=30 ; attempt_vks=1
      while true
      do
        ns_k8s_api GET "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters/${vks_name}" "" "${org_token}"
        vks_available=$(echo ${response_body} | jq -c -r '.status.conditions[]? | select(.type=="Available") | .status')
        if [[ "${vks_available}" == "True" ]]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} is Available after ${attempt_vks} attempts of ${pause_vks} seconds" "${log_file}" "" ""
          break
        fi
        ((attempt_vks++))
        if [ ${attempt_vks} -eq ${retry_vks} ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} NOT Available after ${attempt_vks} attempts of ${pause_vks} seconds (last Available status=${vks_available:-unknown})" "${log_file}" "${slack_webhook}" "${google_webhook}"
          break
        fi
        sleep ${pause_vks}
      done
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])
fi

#
# Blueprints (org-portal phase) - idempotent, one independent copy
# uploaded+released per org with blueprints.enabled, from every
# *.yaml.template file in the bootstrap repo's own blueprints/ dir (a
# dedicated folder there, deliberately separate from yamls/ - that one's
# entries are k8s-shaped manifests dispatched by .kind in
# gw-setup.sh.tpl; these are Aria Automation Cloud Template YAML, a
# different schema with no .kind field at all). Unrelated to
# namespace/vks_cluster gating - blueprints are a plain Aria Automation
# Cloud Template concept, no Avi/segName dependency.
#
# NOT cross-org shared (confirmed live: organizationSharings requires a
# rights-bundle right that, even granted, still didn't clear the "does
# not have required privileges to share catalog items" error - root
# cause not found yet). Each enabled org gets its own separate upload.
#
# ${avi_subdomain} in each template is deliberately substituted with
# THIS ORG'S OWN NAME, not the deployment's actual avi_subdomain value -
# substituting the real (single, deployment-wide) avi_subdomain would
# give every org's copy of a blueprint the exact same FQDN (e.g.
# app.alb.vcf9.lab for org-1 AND org-2 alike), a real routing conflict
# once more than one org has the same blueprint deployed. Using the org
# name instead keeps every org's instance unique (app.org-1.vcf9.lab,
# app.org-2.vcf9.lab, ...) with no extra CR field needed. domain is
# still the real, shared domain value - no per-org conflict there.
# Substitution happens HERE, not in gw-setup.sh.tpl, because that file
# is itself rendered through userdata.py's own ${name} Python templating
# before it ever reaches gw - any ${avi_subdomain}/${domain}/org_name
# placeholder text put there gets consumed by THAT pass instead of
# surviving to run as a real sed command. vcf_bootstrap.sh has no such
# pass (delivered verbatim via git clone), so ${domain} below is a
# genuine, already-set bash variable (same one used elsewhere in this
# script, e.g. the Avi DNS profile step above) - safe to substitute
# with here, and ${org_name} is this loop's own per-iteration variable.
#
blueprints_src_dir="/home/ubuntu/dev-avi-vcf/blueprints"
if [ ! -d "${blueprints_src_dir}" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${blueprints_src_dir} does not exist, skipping all blueprint provisioning" "${log_file}" "" ""
else
  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
      blueprints_enabled=$(echo ${item} | jq -c -r '.blueprints.enabled // false')
      if [ "${blueprints_enabled}" != "true" ]; then
        continue
      fi

      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
      org_uuid="${org_id##*:}"
      org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
        -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${vcfa_token}" \
        --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
      if [ -z "${org_token}" ] || [ "${org_token}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to obtain an org-scoped token for ${org_name}, skipping its blueprints" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      blueprint_api GET "project-service/api/projects" "" "${org_token}"
      project_id=$(echo ${response_body} | jq -c -r '.content[0].id')
      if [ -z "${project_id}" ] || [ "${project_id}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no VCF-A project found for ${org_name}, skipping its blueprints" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      for bp_file in "${blueprints_src_dir}"/*.yaml.template; do
        [ -e "${bp_file}" ] || continue
        bp_name=$(basename "${bp_file}" .yaml.template)

        blueprint_api GET "blueprint/api/blueprints" "" "${org_token}"
        bp_id=$(echo ${response_body} | jq -c -r --arg arg "${bp_name}" '.content[] | select(.name == $arg) | .id')
        if [ -n "${bp_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: blueprint ${bp_name} already exists for ${org_name}, skipping creation" "${log_file}" "" ""
          continue
        fi

        bp_content=$(sed -e "s@\${avi_subdomain}@${org_name}@g" -e "s/\${domain}/${domain}/g" "${bp_file}")
        bp_json=$(jq -n --arg n "${bp_name}" --arg pid "${project_id}" --arg content "${bp_content}" \
          '{name: $n, description: null, valid: true, content: $content, projectId: $pid, requestScopeOrg: true, iconId: null}')
        blueprint_api POST "blueprint/api/blueprints?apiVersion=2020-08-25" "${bp_json}" "${org_token}"
        bp_id=$(echo ${response_body} | jq -c -r '.id')
        if [ -z "${bp_id}" ] || [ "${bp_id}" == "null" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to create blueprint ${bp_name} for ${org_name}, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi

        # Confirmed live: the release step can transiently 500 on an
        # unrelated internal VCFA microservice call
        # (provisioning-service -> tenant-manager over the internal
        # service mesh, "failure when writing TLS control frames") that
        # has nothing to do with this payload - a plain retry a few
        # seconds later succeeds cleanly every time observed. The
        # blueprint draft itself (bp_id above) is unaffected either way.
        rel_json='{"version":"1","description":"initial release","changeLog":"initial release","release":true}'
        released=false
        for rel_attempt in 1 2 3; do
          if blueprint_api POST "blueprint/api/blueprints/${bp_id}/versions" "${rel_json}" "${org_token}"; then
            released=true
            break
          fi
          sleep 10
        done
        if [ "${released}" == "true" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: blueprint ${bp_name} created and released for ${org_name}" "${log_file}" "" ""
        else
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: blueprint ${bp_name} created but release FAILED for ${org_name} after retries, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        fi
      done
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])
fi

log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: End of ${0%.*}.sh" "${log_file}" "${slack_webhook}" "${google_webhook}"
touch "${resultFile}"
