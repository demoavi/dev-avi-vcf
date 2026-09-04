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
  count=1
  until $(curl --output /dev/null --silent --head -k https://${ip_esxi})
  do
    echo "Attempt ${count}: Waiting for ESXi host at https://${ip_esxi} to be reachable..."
    sleep 10
    count=$((count+1))
    if [[ "${count}" -eq 60 ]]; then
      echo "ERROR: Unable to connect to ESXi host at https://${ip_esxi}"
      exit
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
      echo "ERROR: Unable to connect to ESXi host at https://${ip_esxi} after power cycle"
      exit
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
data_network_ids=$(echo ${response_body} | jq -c --arg u "${basename_sddc}-edge-uplink1" --arg e "${basename_sddc}-pg-external" \
  '[.[] | select(.name == $u or .name == $e) | .network]')
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

sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/bundles $(jq -c -r .accessToken /tmp/token_sddcm.json)
avi_bundle_id=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .id')
avi_download_status=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .downloadStatus')
if [[ ${avi_download_status} != "SUCCESSFUL" ]]; then
  sddc_manager_api 3 2 PATCH '{"bundleDownloadSpec":{"downloadNow":true}}' "${ip_sddcm}" v1/bundles/${avi_bundle_id} $(jq -c -r .accessToken /tmp/token_sddcm.json)
  log_only "VCF-I: waiting 120 seconds for Avi bundle download to start"
  sleep 120
fi

retry_avi_download=30 ; pause_avi_download=10 ; attempt_avi_download=1
while true ; do
  sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/bundles $(jq -c -r .accessToken /tmp/token_sddcm.json)
  avi_download_status=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .downloadStatus')
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
  log_notify "VCF-I: Avi cluster deployment started"
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
log_only "VCF-I: waiting 180 seconds for SDDC Manager services to restart"
sleep 180

avi_cluster_json=$(jq -n --arg pw "${generic_password}" --arg bundle "${avi_bundle_id}" --arg fqdn "${basename_sddc}-avi.${domain}" --arg nsx "${nsx_id}" --arg ip "$(echo ${ips_avi} | jq -r '.[0]')" \
  '{adminPassword: $pw, bundleId: $bundle, clusterFqdn: $fqdn, clusterName: "cluster-1", formFactor: "SMALL",
    nodes: [{ipAddress: $ip}], nsxIds: [$nsx], vcfopsAdminPassword: $pw}')
sddc_manager_api 3 2 POST "${avi_cluster_json}" "${ip_sddcm}" v1/alb-clusters $(jq -c -r .accessToken /tmp/token_sddcm.json)
log_notify "VCF-I: single-node Avi controller deployment started"
log_only "VCF-I: waiting 1800 seconds for Avi controller deployment"
sleep 1800

create_api_session "administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)" "${generic_password}" "${ip_sddcm}" /tmp/token_sddcm.json
retry_avi_deploy=60 ; pause_avi_deploy=10 ; attempt_avi_deploy=1
while true ; do
  sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/alb-clusters $(jq -c -r .accessToken /tmp/token_sddcm.json)
  avi_deploy_status=$(echo ${response_body} | jq -c -r '.elements[0].deploymentStatus')
  if [[ ${avi_deploy_status} == "ACTIVE" ]]; then
    log_notify "VCF-I: Avi controller deployed"
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

log_notify "vcf_bootstrap.sh complete (SDDC build + vCenter port groups + NSX config + Avi deployment - see scripts/0N-*.sh for the remaining pipeline stages, run standalone)"
