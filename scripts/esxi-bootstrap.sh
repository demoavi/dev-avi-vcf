#!/bin/bash
#
# Power on/wait for the nested ESXi VMs in VCD and customize them (SSD marking, etc.) - first real infrastructure phase of the VCD/vApp use case, called by vcf_bootstrap.sh.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"
# sddc use case has no VCD at all - vcd_login (and everything it sets:
# vcd_host/vcd_auth_token/vcd_api_version/gw_vm_href) only makes sense
# for the vApp use case. log_notify below tolerates gw_vm_href being
# unset either way (its VCD-metadata-posting branch is gated on it),
# so skipping this is safe for sddc.
if [ "${deployment_kind}" == "vApp" ]; then
  vcd_login
fi
log_notify "esxi-bootstrap.sh started"

#
#
#
echo '------------------------------------------------------------'
echo "Cloud Builder JSON file creation"

#
# sddc use case's power-cycle (below) talks to the underlying/external
# vCenter directly via govc, not VCD - these vars are constant for the
# whole run (one external vCenter, not one per ESXi host), so exported
# once here rather than per-host. Names match the reference project's
# own vsphere_underlay_* convention (bash/variables.sh, commit
# 7ee6094408ed7281fdc8c2990a65b30747611a1f) so no renaming is needed if/
# when the sddc use case gets its own CRD/operator rendering these into
# variables.sh - until then they're simply unset and this whole branch
# is unreachable, since deployment_kind only ever resolves to "sddc" via
# functions.sh's fallback default, never set explicitly by anything yet.
#
if [ "${deployment_kind}" == "sddc" ]; then
  export GOVC_URL="${vsphere_underlay_vcsa}"
  export GOVC_USERNAME="${vsphere_underlay_username}"
  export GOVC_PASSWORD="${vsphere_underlay_password}"
  export GOVC_DATACENTER="${vsphere_underlay_datacenter}"
  export GOVC_DATASTORE="${vsphere_underlay_datastore}"
  export GOVC_CLUSTER="${vsphere_underlay_cluster}"
  export GOVC_RESOURCE_POOL="${vsphere_underlay_cluster}/Resources"
  export GOVC_INSECURE=true
fi

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

  # vApp use case: VM already exists in VCD (created by the operator) -
  # wait for VCD's own POWERED_ON status. sddc use case: VM already
  # exists directly on the underlying/external vCenter instead - wait
  # for govc's own poweredOn state there.
  wait_powered_on_fn="vcd_wait_vm_powered_on"
  [ "${deployment_kind}" == "sddc" ] && wait_powered_on_fn="govc_wait_vm_powered_on"
  if ! "${wait_powered_on_fn}" "${name_esxi}"; then
    echo "ERROR: ${name_esxi} never reached powered-on state, skipping this host"
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
  # Power-cycle this host now that we know it's genuinely up (thumbprint
  # just captured above) - a clean reboot after the kickstart install.
  # vApp use case does this via VCD's own REST API (govc has no session
  # that can power-cycle a VM inside a VCD-managed vApp from the
  # outside); sddc use case's ESXi VMs live directly on the underlying/
  # external vCenter instead, so the original vCenter-based reference
  # flow's own govc vm.power cycle applies unchanged there.
  #
  if [ "${deployment_kind}" == "vApp" ]; then
    vm_href=$(vcd_find_vm_href "${name_esxi}")
    curl -sk -X POST "${vm_href}/power/action/powerOff" \
      -H "Authorization: Bearer ${vcd_auth_token}" \
      -H "Accept: application/*+xml;version=${vcd_api_version}" > /dev/null
    sleep 30
    curl -sk -X POST "${vm_href}/power/action/powerOn" \
      -H "Authorization: Bearer ${vcd_auth_token}" \
      -H "Accept: application/*+xml;version=${vcd_api_version}" > /dev/null
  elif [ "${deployment_kind}" == "sddc" ]; then
    govc vm.power -s "${name_esxi}"
    sleep 30
    govc vm.power -on "${name_esxi}"
  fi

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
  # A standalone ESXi endpoint has no datacenter/cluster/resource-pool of
  # its own, so any of those left exported from the sddc branch's
  # power-cycle step above (pointed at the underlying/external vCenter)
  # must be cleared first - confirmed live they otherwise make govc fail
  # outright ("datacenter 'X' not found") instead of being silently
  # ignored. Harmless no-op for the vApp use case, where these are never
  # set in the first place.
  #
  unset GOVC_DATACENTER GOVC_DATASTORE GOVC_CLUSTER GOVC_RESOURCE_POOL
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

#
# sddc use case only: eject each ESXi host's kickstart ISO from its
# CD-ROM device and delete it from the datastore, now that the kickstart
# install has completed - ported verbatim from the reference project's
# own sddc.sh (lines ~483-486). vApp use case has no equivalent step:
# its kickstart ISOs are served over HTTP from gw (see gw-setup.sh.tpl),
# never inserted as a per-VM CD-ROM device at all, so there's nothing to
# eject/clean up there.
#
# iso_location and folder are both expected as plain bash variables from
# bash/variables.sh, not derived here - matching the reference project's
# own convention (commit 7fdc1378dbf2a3749ddfa7e172158801d5f200b3 moved
# iso_location="/tmp/esxi" out of sddc.sh's own function body and into
# bash/variables.sh, right alongside the vsphere_underlay_* exports).
# folder is the vSphere VM Folder these ESXi VMs live in on the
# underlying/external vCenter - bash/variables.sh's own bare "folder"
# name (sourced from .vsphere_underlay.folder), deliberately not
# prefixed vsphere_underlay_* like the GOVC_* vars above, matching
# upstream exactly (see that project's own bash/variables.sh, which
# doesn't rename this one either).
#
if [ "${deployment_kind}" == "sddc" ]; then
  export GOVC_URL="${vsphere_underlay_vcsa}"
  export GOVC_USERNAME="${vsphere_underlay_username}"
  export GOVC_PASSWORD="${vsphere_underlay_password}"
  export GOVC_DATACENTER="${vsphere_underlay_datacenter}"
  export GOVC_DATASTORE="${vsphere_underlay_datastore}"
  export GOVC_CLUSTER="${vsphere_underlay_cluster}"
  export GOVC_RESOURCE_POOL="${vsphere_underlay_cluster}/Resources"
  export GOVC_INSECURE=true

  for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
  do
    group=$(( (esxi-1)/4 ))
    if [[ ${group} -eq 0 ]] ; then
      name_esxi="${basename_sddc}-mgmt-esx0${esxi}"
    else
      pos_in_group=$(( esxi - group*4 ))
      name_esxi="${basename_sddc}-wld0${group}-esx0${pos_in_group}"
    fi

    cdrom_name=$(govc device.ls -vm "${folder}/${name_esxi}" -json | jq -r --arg arg "VirtualCdrom" '.devices[] | select( .type == $arg).name')
    govc device.cdrom.eject -vm "${folder}/${name_esxi}" -device "${cdrom_name}" nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
    sleep 10
    govc device.cdrom.eject -vm "${folder}/${name_esxi}" -device "${cdrom_name}" nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
    govc datastore.rm nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
  done

  # Once every per-host ISO is gone, the now-empty nested-vcf folder
  # itself is removed too - one-shot, not per-host, still under the same
  # GOVC_* session exported above.
  govc datastore.rm nested-vcf > /dev/null
fi
