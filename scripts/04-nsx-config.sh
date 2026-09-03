#!/bin/bash
# NSX Manager configuration (merged from the reference project's nsx/configure_nsx.sh).
# Part of the split-up vcf_bootstrap.sh (see 00-lib.sh for why) - run
# standalone as:
#   bash 04-nsx-config.sh /home/ubuntu/json/deployment.json
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-lib.sh"
log_notify "04-nsx-config.sh started"
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


log_notify "04-nsx-config.sh complete"
