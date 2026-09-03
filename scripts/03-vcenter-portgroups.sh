#!/bin/bash
# vCenter port groups (merged from the reference project's vcenter/vcsa.sh).
# Part of the split-up vcf_bootstrap.sh (see 00-lib.sh for why) - run
# standalone as:
#   bash 03-vcenter-portgroups.sh /home/ubuntu/json/deployment.json
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-lib.sh"
log_notify "03-vcenter-portgroups.sh started"
#
# port groups (merged from the reference project's vcenter/vcsa.sh - content
# library creation/OVA upload deliberately dropped, same as the earlier
# Cloud Builder/9.0 branches: VCF 9.1-only scope, so the EDGE_OVERLAY
# portgroup that reference script only creates for 9.0/8.0U3b is skipped
# too. govc here talks to the newly-built nested vCenter, not an ESXi host
# directly - GOVC_CLUSTER is unset since portgroups sit on the vDS itself,
# independent of any specific cluster.
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
  log_notify "VCF-I: portgroup ${basename_sddc}-pg-external created (vlan ${external_vlan_id})"
fi

pg_error=$(govc dvs.portgroup.add -dvs "${vds_name}" -vlan-mode=trunking "${basename_sddc}-edge-uplink1" 2>&1)
if [ $? -ne 0 ]; then
  log_notify "ERROR: govc dvs.portgroup.add ${basename_sddc}-edge-uplink1 failed: ${pg_error}"
else
  log_notify "VCF-I: portgroup ${basename_sddc}-edge-uplink1 created (trunking)"
fi


log_notify "03-vcenter-portgroups.sh complete"
