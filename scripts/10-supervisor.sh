#!/bin/bash
# Supervisor (Tanzu) cluster enablement (merged from the reference project's supervisor/configure_supervisor.sh).
# Part of the split-up vcf_bootstrap.sh (see 00-lib.sh for why) - run
# standalone as:
#   bash 10-supervisor.sh /home/ubuntu/json/deployment.json
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-lib.sh"
log_notify "10-supervisor.sh started"
#
# Supervisor (Tanzu) cluster enablement (merged from the reference
# project's supervisor/configure_supervisor.sh - applies to both 9.0 and
# 9.1 there, so no version branch to drop here). Chains directly off
# earlier work in this same script: workloads.network below uses NSX_VPC
# mode against the "default" project / vpc_connectivity_profile-default
# the NSX Project/VPC section already created, and authenticates via the
# vcf CLI staged from the gw tools ISO. Reuses
# create_vcenter_api_session/vcenter_api from the NSX configuration
# section above (already targeting our nested vCenter) - re-authenticating
# before each call, matching the reference's own defensive pattern, since
# the 600-second wait partway through risks the session expiring.
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
log_notify "VCF-I: Supervisor cluster enablement started"
log_only "VCF-I: waiting 600 seconds"
sleep 600

retry_supervisor=121 ; pause_supervisor=60 ; attempt_supervisor=1
while true ; do
  create_vcenter_api_session
  vcenter_api 3 3 GET "api/vcenter/namespace-management/clusters" ""
  config_status=$(echo ${response_body} | jq -c -r '.[0].config_status')
  k8s_status=$(echo ${response_body} | jq -c -r '.[0].kubernetes_status')
  if [[ "${config_status}" == "RUNNING" && "${k8s_status}" == "READY" ]]; then
    log_notify "VCF-I: Supervisor config_status ${config_status}, kubernetes_status ${k8s_status} after ${attempt_supervisor} attempts of ${pause_supervisor} seconds"
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

# Note: kept faithful to a real inconsistency in the reference project -
# this first vcf context create uses a bare endpoint (no scheme) while
# auth_vks_context.sh below (also the reference's own) hardcodes
# "https://" in front of the same field. Not something this port
# resolves without a live environment to check which one's actually
# correct.
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

log_notify "VCF-I: Supervisor cluster ready, auth helper scripts written to /home/ubuntu/supervisor/"

log_notify "10-supervisor.sh complete"
