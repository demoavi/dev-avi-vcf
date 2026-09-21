#!/bin/bash
#
# Power on/wait for the nested ESXi VMs in VCD and customize them (SSD marking, etc.) - first real infrastructure phase of the VCD/vApp use case, called by vcf_bootstrap.sh.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"
vcd_login
log_notify "esxi-bootstrap.sh started"

#
#
#
echo '------------------------------------------------------------'
echo "Cloud Builder JSON file creation"

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

# hostSpecs (built per-host above) is needed by vcf-installer-bootstrap.sh
# for the Cloud Builder JSON template it renders - handed off via a temp
# file since that runs as its own separate process (same pattern this
# project already uses elsewhere for cross-script state, e.g.
# /tmp/token_vcfi.json).
echo "${hostSpecs}" > /tmp/hostSpecs.json
