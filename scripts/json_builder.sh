#!/bin/bash
jsonFile=${1}
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
templates_dir="${script_dir}/../templates"
mkdir -p /home/ubuntu/html /home/ubuntu/json
source /home/ubuntu/bash/variables.sh
if [ -n "${google_webhook}" ] ; then curl -s -X POST -H 'Content-Type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': json_builder.sh started"}' "${google_webhook}" >/dev/null 2>&1; fi
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
  vm_href=$(curl -sk "https://${vcd_host}/api/query?type=vm&format=records&pageSize=128" \
    -H "Authorization: Bearer ${vcd_auth_token}" \
    -H "Accept: application/*+json;version=${vcd_api_version}" \
    | jq -r --arg name "${name_esxi}" '.record[] | select(.name == $name) | .href')
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
  if [ -n "${google_webhook}" ] ; then curl -s -X POST -H 'Content-Type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': nested ESXi '${name_esxi}' disks marked as SSD"}' "${google_webhook}" >/dev/null 2>&1; fi
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
if [ -n "${google_webhook}" ] ; then curl -s -X POST -H 'Content-Type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': json_builder.sh finished - details for cloud deployment available at http://'${ip_gw}'/"}' "${google_webhook}" >/dev/null 2>&1; fi
