#!/bin/bash
#
# Power on/wait for the nested ESXi VMs in VCD and customize them (SSD marking, etc.) - first real infrastructure phase of the VCD/vApp use case, called by vcf_bootstrap.sh.
# vApp use case: the gw powers the hosts on itself when vms.esx.powerOn is false (see "the gw starts the ESXi VMs itself" below), takes their TLS thumbprints,
# reboots them cleanly once, and ends non-zero, with the list, when a host is not usable.
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
# The per-host SSD step further down points govc at the ESXi host itself (GOVC_URL=<host>, root, no datacenter), so the
# underlay settings are (re)applied at the top of every iteration, not only once: without that, host 2 and later were
# looked up in host 1's own inventory (never found, a silent 60-minute wait per host).
govc_underlay_env() {
  export GOVC_URL="${vsphere_underlay_vcsa}"
  export GOVC_USERNAME="${vsphere_underlay_username}"
  export GOVC_PASSWORD="${vsphere_underlay_password}"
  export GOVC_DATACENTER="${vsphere_underlay_datacenter}"
  export GOVC_DATASTORE="${vsphere_underlay_datastore}"
  export GOVC_CLUSTER="${vsphere_underlay_cluster}"
  export GOVC_RESOURCE_POOL="${vsphere_underlay_cluster}/Resources"
  export GOVC_INSECURE=true
  unset GOVC_PERSIST_SESSION GOVC_DEBUG
}
if [ "${deployment_kind}" == "sddc" ]; then
  govc_underlay_env
fi

# ---- vApp use case: the gw starts the ESXi VMs itself -------------------------------------------------------------------------------------------
# With vms.esx.powerOn: false the operator builds each host (boot ISO uploaded and inserted) and leaves it OFF; this script powers it on once the gw can really
# serve its kickstart. Before, the operator powered every host on right after creating it, and the first hosts could boot while gw-setup had not written the
# kickstart files yet: the installer got 404s / timeouts and stayed without its IP (2026-11-19, edu 12-org vApp). A CR without powerOn: false keeps working
# (the hosts are already on, nothing is done here). OLD scripts + powerOn: false = the hosts never start: push this script first, then set powerOn: false.
esx_kickstart_url() { echo "http://${ip_gw}/kickstart/KS_${1}.CFG"; }    # the URL of the boot line of the ISO (esx.mgmt_network_params: <management>.1 = ip_gw)
vcd_vm_state() {   # POWERED_ON | POWERED_OFF | ... | missing
  local resp; resp=$(curl -sk "https://${vcd_host}/api/query?type=vm&format=records&pageSize=128$(vcd_vm_filter "$1")" -H "Authorization: Bearer ${vcd_auth_token}" -H "Accept: application/*+json;version=${vcd_api_version}")
  echo "${resp}" | jq -r --arg n "$1" '[.record[]? | select(.name == $n) | .status][0] // "missing"'
}
vcd_vm_power_action() {   # <vm name> <powerOn|powerOff|shutdown|reset>: prints the HTTP code of the action
  local h; h=$(vcd_find_vm_href "$1"); [ -n "${h}" ] || { echo 000; return 1; }
  curl -sk -o /dev/null -w '%{http_code}' -X POST "${h}/power/action/$2" -H "Authorization: Bearer ${vcd_auth_token}" -H "Accept: application/*+xml;version=${vcd_api_version}"
}
vcd_vm_boot_iso_inserted() {   # the CD/DVD drive holds a boot ISO: the operator's last step before it powers a host on, so "the host is complete"
  local h xml; h=$(vcd_find_vm_href "$1"); [ -n "${h}" ] || return 1
  xml=$(curl -sk "${h}" -H "Authorization: Bearer ${vcd_auth_token}" -H "Accept: application/*+xml;version=${vcd_api_version}")
  echo "${xml}" | tr -d '\n' | sed -E 's#<((\w+:)?)Item>#\n<\1Item>#g' | grep -E 'ResourceType>[[:space:]]*15[[:space:]]*<' | grep -oE 'HostResource[^>]*>[^<]+<' | grep -qiE 'boot.*\.iso'
}
esx_host_ready_to_start() {   # <name>: complete (VM exists with its boot ISO inserted) and its kickstart answers 200 on the gw
  vcd_vm_boot_iso_inserted "$1" && curl -sf -m 5 -o /dev/null "$(esx_kickstart_url "$1")"
}
esx_power_on_when_ready() {   # every host, in order: wait until it is ready, then power it on; a host that is already on is left alone
  local esxi name state t0 last
  for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length')); do
    name="$(esxi_host_name ${esxi})"; t0=$(date +%s); last=${t0}
    while true; do
      state=$(vcd_vm_state "${name}")
      [ "${state}" == "POWERED_ON" ] && { echo "esx start: ${name} is already on"; break; }
      if [ "${state}" == "POWERED_OFF" ] && esx_host_ready_to_start "${name}"; then
        echo "esx start: ${name}: boot ISO inserted and $(esx_kickstart_url "${name}") answers: powering it on (HTTP $(vcd_vm_power_action "${name}" powerOn))"
        break
      fi
      if [ $(( $(date +%s) - t0 )) -ge 6000 ]; then echo "ERROR: esx start: ${name} not ready after 100 minutes (state ${state})"; echo "${name}" >> /tmp/esx_start_failed; break; fi
      if [ $(( $(date +%s) - last )) -ge 300 ]; then echo "esx start: still waiting for ${name} (state ${state}; boot ISO inserted: $(vcd_vm_boot_iso_inserted "${name}" && echo yes || echo no); kickstart: $(curl -s -m 5 -o /dev/null -w '%{http_code}' "$(esx_kickstart_url "${name}")"))"; last=$(date +%s); fi
      sleep 15
    done
  done
}
vcd_vm_clean_reboot() {   # guest shutdown (ESXi saves its configuration when it shuts down cleanly), the hard power off only as a fallback, then power on
  local name="$1" code t0
  code=$(vcd_vm_power_action "${name}" shutdown)
  t0=$(date +%s)
  if [[ "${code}" =~ ^2 ]]; then
    until [ "$(vcd_vm_state "${name}")" == "POWERED_OFF" ]; do [ $(( $(date +%s) - t0 )) -ge 240 ] && break; sleep 5; done
  fi
  if [ "$(vcd_vm_state "${name}")" != "POWERED_OFF" ]; then
    echo "WARNING: ${name}: guest shutdown not done (HTTP ${code}): hard power off"
    vcd_vm_power_action "${name}" powerOff > /dev/null; until [ "$(vcd_vm_state "${name}")" == "POWERED_OFF" ]; do [ $(( $(date +%s) - t0 )) -ge 420 ] && break; sleep 5; done
  fi
  sleep 10
  vcd_vm_power_action "${name}" powerOn > /dev/null
}

failed_hosts=""
poweron_pid=""
if [ "${deployment_kind}" == "vApp" ]; then
  rm -f /tmp/esx_start_failed
  esx_power_on_when_ready &     # in the background: the installs run in parallel, the loop below only waits for the hosts it needs
  poweron_pid=$!
  trap '[ -n "${poweron_pid}" ] && kill ${poweron_pid} 2> /dev/null' EXIT
fi

hostSpecs="[]"
for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
do
  [ "${deployment_kind}" == "sddc" ] && govc_underlay_env
  if [ "${deployment_kind}" == "vApp" ]; then
    # names decided once by the operator (the dedicated host is not named by an index), see functions.sh
    name_esxi="$(esxi_host_name ${esxi})"
  else
    group=$(( (esxi-1)/4 ))
    if [[ ${group} -eq 0 ]] ; then
      name_esxi="${basename_sddc}-mgmt-esx0${esxi}"
    else
      pos_in_group=$(( esxi - group*4 ))
      name_esxi="${basename_sddc}-wld0${group}-esx0${pos_in_group}"
    fi
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
  wait_limit=90 ; [ "${deployment_kind}" == "vApp" ] && wait_limit=150   # the vApp use case: 25 minutes, then ONE reset of the VM (an installer that never got its kickstart), then another 25
  reset_done=false
  until $(curl --output /dev/null --silent --head -k https://${ip_esxi})
  do
    echo "Attempt ${count}: Waiting for ESXi host at https://${ip_esxi} to be reachable..."
    sleep 10
    count=$((count+1))
    if [[ "${count}" -ge "${wait_limit}" ]]; then
      if [ "${deployment_kind}" == "vApp" ] && [ "${reset_done}" == "false" ]; then
        echo "WARNING: ${name_esxi} does not answer on https after 25 minutes (installer stuck?): resetting the VM once (HTTP $(vcd_vm_power_action "${name_esxi}" reset))"
        reset_done=true ; count=1
      else
        echo "ERROR: Unable to connect to ESXi host at https://${ip_esxi}, skipping this host"
        failed_hosts="${failed_hosts} ${name_esxi}"
        continue 2
      fi
    fi
  done
  sleep 60
  # an empty thumbprint ends as "NO_SSL_THUMB" in the installer's validation 40 minutes later: ask again a few times (the TLS service of a fresh host can need a moment)
  esxi_sslThumbprint=""
  for try in 1 2 3 4 5 6; do
    esxi_sslThumbprint=$(echo | openssl s_client -servername ${ip_esxi} -connect ${ip_esxi}:443 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | awk -F'Fingerprint=' '{print $2}')
    [ -n "${esxi_sslThumbprint}" ] && break
    echo "Attempt ${try}: no TLS thumbprint from ${ip_esxi} yet"; sleep 10
  done
  if [ -z "${esxi_sslThumbprint}" ]; then
    echo "ERROR: no TLS thumbprint from ESXi host ${name_esxi} (${ip_esxi}) after 6 attempts"
    failed_hosts="${failed_hosts} ${name_esxi}"
    continue
  fi
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
    # a CLEAN reboot (guest shutdown): a hard power off right after the first boot lost what the kickstart's %firstboot had set (edu 12-org esx03 and esx06
    # came back without their static IP, 2026-11-18); ESXi saves its configuration when it shuts down cleanly. Hard power off only as a fallback.
    vcd_vm_clean_reboot "${name_esxi}"
  elif [ "${deployment_kind}" == "sddc" ]; then
    govc vm.power -s "${name_esxi}"
    sleep 30
    govc vm.power -on "${name_esxi}"
  fi

  count=1
  after_limit=60 ; [ "${deployment_kind}" == "vApp" ] && after_limit=91   # the vApp use case: 15 minutes (a clean reboot of a big nested host is not quick)
  until $(curl --output /dev/null --silent --head -k https://${ip_esxi})
  do
    echo "Attempt ${count}: Waiting for ESXi host at https://${ip_esxi} to be reachable after power cycle..."
    sleep 10
    count=$((count+1))
    if [[ "${count}" -ge "${after_limit}" ]]; then
      # hostSpec for this host was already appended to hostSpecs above -
      # a single stuck host here shouldn't abort the whole SDDC bootstrap,
      # so skip its remaining customization below rather than exiting.
      echo "ERROR: Unable to connect to ESXi host at https://${ip_esxi} after power cycle, skipping this host"
      failed_hosts="${failed_hosts} ${name_esxi}"
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

# vApp use case: a host that never started, never answered or gave no thumbprint makes the installer's validation fail 40 minutes later (NO_SSL_THUMB / ESXI_PING):
# stop here, with the list, instead. Re-run: vcf_bootstrap.sh <json> --from esxi-bootstrap (every step above can be run again).
if [ "${deployment_kind}" == "vApp" ]; then
  [ -n "${poweron_pid}" ] && wait ${poweron_pid} 2> /dev/null
  [ -s /tmp/esx_start_failed ] && failed_hosts="${failed_hosts} $(tr '\n' ' ' < /tmp/esx_start_failed)"
  if [ -n "${failed_hosts// /}" ]; then
    log_notify "ERROR: esxi-bootstrap.sh: these ESXi hosts are not usable:${failed_hosts}. Fix them (console in VCD: static IP, kickstart) and re-run: vcf_bootstrap.sh ${jsonFile} --from esxi-bootstrap"
    exit 1
  fi
fi

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
