#!/bin/bash
# NSX Project/VPC/Transit-Gateway setup (merged from the reference project's nsx/vpc_avi.sh).
# Part of the split-up vcf_bootstrap.sh (see 00-lib.sh for why) - run
# standalone as:
#   bash 08-nsx-vpc.sh /home/ubuntu/json/deployment.json
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-lib.sh"
log_notify "08-nsx-vpc.sh started"
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

log_notify "VCF-I: NSX Project/VPC setup complete"

log_notify "08-nsx-vpc.sh complete"
