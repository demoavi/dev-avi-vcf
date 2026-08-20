#!/bin/bash
jsonFile=${1}
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
templates_dir="${script_dir}/../templates"
mkdir -p /home/ubuntu/html /home/ubuntu/json
source /home/ubuntu/bash/variables.sh

# log_only just echoes (already captured by the caller's stdout redirect
# into vcf_bootstrap.log); log_notify also posts to gchat for milestones -
# jq builds the JSON body so message text is never hand-quoted into a
# curl argument (the same class of bug that broke the kickstart heredoc
# earlier in this project).
log_only() {
  echo "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: $1"
}
log_notify() {
  local message="$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: $1"
  echo "${message}"
  if [ -n "${google_webhook}" ]; then
    curl -s -X POST -H 'Content-Type: application/json' --data "$(jq -n --arg text "${message}" '{text: $text}')" "${google_webhook}" >/dev/null 2>&1
  fi
}

log_notify "vcf_bootstrap.sh started"
#
#
#
echo '------------------------------------------------------------'
echo "Cloud Builder JSON file creation"

# VCD session for the power-cycle step below - govc has no session that can
# power-cycle a VCD-managed VM (GOVC_URL against the ESXi guest itself only
# reaches its own management API, not the layer that controls its power
# state), so this talks to VCD's REST API directly instead. Logged in once
# and reused for all hosts.
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
  govc host.storage.info -json -rescan | jq -c -r '.storageDeviceInfo.scsiLun[] | select( .deviceType == "disk" ) | .deviceName' | while read -r disk_device
  do
    govc host.storage.mark -ssd "${disk_device}" > /dev/null
  done
  log_notify "nested ESXi ${name_esxi} disks marked as SSD"
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
sed -e "s@\${ip_gw}@${ip_gw}@" "${templates_dir}/socks.html.template" | tee /home/ubuntu/html/socks.html > /dev/null
sudo mv /home/ubuntu/html/index.html /var/www/html/index.html
sudo mv /home/ubuntu/html/socks.html /var/www/html/socks.html
sudo chown root /var/www/html/index.html
sudo chgrp root /var/www/html/index.html
sudo chown root /var/www/html/socks.html
sudo chgrp root /var/www/html/socks.html
sudo cat /var/lib/bind/db.${domain} | grep avi | sudo tee /var/www/html/avi_raw.html
while read -r line; do echo \"\$line<br>\" ; done < /var/www/html/avi_raw.html | sudo tee /var/www/html/avi.html
sudo cat /var/lib/bind/db.${domain} | grep wld | sudo tee /var/www/html/esxi_raw.html
while read -r line; do echo \"$line<br>\" ; done < /var/www/html/esxi_raw.html | sudo tee /var/www/html/esxi.html
sudo cp /home/ubuntu/json/${basename_sddc}.json /var/www/html/${basename_sddc}.json
sudo chown root /var/www/html/${basename_sddc}.json
sudo chgrp root /var/www/html/${basename_sddc}.json
log_notify "deployment JSON ready, details available at http://${ip_gw}/"
#
#
#
# VCF Installer configuration (merged from vcf-installer/vcfi.sh) -
# exchanges the license-service credentials for an activation code, waits
# for the install bundles to download, then submits/validates/builds the
# SDDC. Only the VCF 9.1 path is kept - see the earlier json_builder.sh
# simplification for why the 9.0/Cloud Builder branches were dropped.
#
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
# back the same way.
#
gw_vm_href=$(vcd_find_vm_href "gw")
curl -sk -X POST "${gw_vm_href}/metadata" \
  -H "Authorization: Bearer ${vcd_auth_token}" \
  -H "Accept: application/*+xml;version=${vcd_api_version}" \
  -H "Content-Type: application/vnd.vmware.vcloud.metadata+xml" \
  --data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Metadata xmlns=\"http://www.vmware.com/vcloud/v1.5\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><MetadataEntry><Key>vcfi_machineId</Key><TypedValue xsi:type=\"MetadataStringValue\"><Value>${vcfi_machineId}</Value></TypedValue></MetadataEntry></Metadata>" > /dev/null

log_notify "VCF-I: posted machineId to VCD metadata, waiting for the operator to relay the activation code"
retry_activation=60 ; pause_activation=30 ; attempt_activation=1
while true; do
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
    log_only "VCF-I: bundles are populated"
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
    log_notify "VCF-I: SDDC JSON validation not finished after ${attempt_validation} attempts of ${pause_validation} seconds"
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
    exit 100
  fi
done

log_notify "vcf_bootstrap.sh complete"
