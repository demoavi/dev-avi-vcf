#!/bin/bash
#
# Content library subscription + Supervisor (Tanzu) cluster enablement, and generation of the Supervisor auth helper scripts / harbor_rewrite_images.sh.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"
vcd_login
log_notify "supervisor-bootstrap.sh started"

# Also computed independently by vcf_bootstrap.sh itself (shared with the
# VCFA org-provisioning phase, which needs fqdn_vcfa too) - duplicated
# here rather than passed through, since this runs as its own process.
fqdn_vcfa="${basename_sddc}-auto-vip.${domain}"
vcsa_fqdn="${basename_sddc}-vc01.${domain}"
vsphere_nested_username="administrator"

# Supervisor (Tanzu) cluster enablement (merged from the reference
# project's supervisor/configure_supervisor.sh - applies to both 9.0 and
# 9.1 there, so no version branch to drop here). Chains directly off
# earlier work in this same script: workloads.network below uses NSX_VPC
# mode against the "default" project / vpc_connectivity_profile-default
# the NSX Project/VPC section already created, and authenticates via the
# vcf CLI staged from the gw tools ISO. Reuses create_vcenter_api_session/
# vcenter_api from the NSX configuration section above (already targeting
# our nested vCenter) - re-authenticating before each call, matching the
# reference's own defensive pattern, since the 600-second wait partway
# through risks the session expiring.
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
#
# Idempotency check - same gap as the Supervisor enablement POST below
# (confirmed live there, likely present here too on a re-run). No
# name-filter query param on this endpoint, so list all libraries and
# check by name individually, matching the exact pattern already used
# in configure_vcfa.sh's own vCenter content-library lookups.
#
create_vcenter_api_session
vcenter_api 3 3 GET "api/content/library" ""
existing_cl_id=""
for cl_id in $(echo ${response_body} | jq -r '.[]'); do
  create_vcenter_api_session
  vcenter_api 3 3 GET "api/content/library/${cl_id}" ""
  if [ "$(echo ${response_body} | jq -r '.name')" == "content_library_supervisor" ]; then
    existing_cl_id="${cl_id}"
    break
  fi
done
if [ -n "${existing_cl_id}" ]; then
  log_notify "content_library_supervisor already exists (${existing_cl_id}), skipping subscription"
else
  create_vcenter_api_session
  vcenter_api 3 3 POST "api/content/subscribed-library" "${cl_json}"
fi

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
#
# Idempotency check - confirmed live this POST had none at all, 400ing
# "A Supervisor with sup-admin-01 name already exists" on any re-run
# once enabled. Reuses the exact same LIST-form GET (and .[0] field
# names) the poll loop below already checks - list form returns 200
# with an empty array if nothing's enabled yet, unlike the single-
# resource GET (api/vcenter/namespace-management/clusters/{id}), which
# 404s in that case and would trip vcenter_api's own hard exit-100 on
# any non-2xx (it has no graceful "not found is fine" return path).
#
create_vcenter_api_session
vcenter_api 3 3 GET "api/vcenter/namespace-management/clusters" ""
existing_config_status=$(echo ${response_body} | jq -c -r '.[0].config_status // empty')
existing_k8s_status=$(echo ${response_body} | jq -c -r '.[0].kubernetes_status // empty')
supervisor_freshly_enabled=false
if [ "${existing_config_status}" == "RUNNING" ] && [ "${existing_k8s_status}" == "READY" ]; then
  log_notify "Supervisor already enabled on cluster ${cluster_id} (config_status=${existing_config_status}, kubernetes_status=${existing_k8s_status}), skipping enable_on_compute_cluster"
else
  supervisor_freshly_enabled=true
  create_vcenter_api_session
  vcenter_api 3 3 POST "api/vcenter/namespace-management/supervisors/${cluster_id}?action=enable_on_compute_cluster" "${supervisor_json}"
  log_notify "Supervisor cluster enablement started"
  log_only "waiting 600 seconds"
  sleep 600
fi

retry_supervisor=121 ; pause_supervisor=60 ; attempt_supervisor=1
while true ; do
  create_vcenter_api_session
  vcenter_api 3 3 GET "api/vcenter/namespace-management/clusters" ""
  config_status=$(echo ${response_body} | jq -c -r '.[0].config_status')
  k8s_status=$(echo ${response_body} | jq -c -r '.[0].kubernetes_status')
  if [[ "${config_status}" == "RUNNING" && "${k8s_status}" == "READY" ]]; then
    log_notify "Supervisor config_status ${config_status}, kubernetes_status ${k8s_status} after ${attempt_supervisor} attempts of ${pause_supervisor} seconds"
    break
  fi
  ((attempt_supervisor++))
  if [ ${attempt_supervisor} -eq ${retry_supervisor} ]; then
    log_notify "ERROR: Supervisor not RUNNING/READY after ${attempt_supervisor} attempts of ${pause_supervisor} seconds (config_status=${config_status}, kubernetes_status=${k8s_status})"
    exit 100
  fi
  sleep ${pause_supervisor}
done

# Extra settle time beyond config_status=RUNNING/kubernetes_status=READY -
# confirmed live this API-level readiness doesn't mean the Supervisor's own
# appplatform-operator has finished its own async backend init yet (per-
# service ServiceAccount creation, signature verification records): a
# Supervisor Service registered+enabled too soon after this point can fail
# with either "signature verification result not found" or "the service
# account is not ready. Please try again later" (both HTTP 500, both seen
# live, both cleared on a later retry with no config change) - a plain
# fixed wait here is simpler and cheaper than teaching every enable-on-
# cluster call its own retry-on-500 logic for what's a one-time startup
# race, not a recurring condition. Only actually a race right after a
# FRESH enable_on_compute_cluster - skip it entirely on a re-run against
# an already-enabled Supervisor (confirmed RUNNING/READY, likely for a
# while), since the backend has long since settled by then.
if [ "${supervisor_freshly_enabled}" == "true" ]; then
  log_only "waiting 300 more seconds for the Supervisor's own backend (appplatform-operator) to settle before registering/enabling any Supervisor Services"
  sleep 300
else
  log_only "Supervisor was already enabled (not freshly enabled this run), skipping the 300s backend-settle wait"
fi

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

# Note: the reference project has a real inconsistency here - this first
# vcf context create uses a bare endpoint (no scheme) while
# auth_vks_context.sh below (also the reference's own) hardcodes
# "https://" in front of the same field. Confirmed live against a real
# VCF 9.1 Supervisor cluster: the bare endpoint works fine here (vcf
# logs in successfully and auto-discovers every context), so this isn't
# a bug worth resolving - both forms are apparently accepted.
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

# vcfa_select_ns.sh / vcfa_select_vks_cluster.sh - interactive discovery
# scripts (browse org -> supervisor namespace -> VKS cluster via VCF
# Automation's provider API, then connect) - ported from the reference
# project's templates/vcfa_select_ns.sh.template and
# templates/vcfa_select_vks_cluster.sh.template verbatim. Same quoted-
# heredoc + targeted sed pattern as auth_vks_context.sh above, for the
# same reason - these generated scripts have their own $1/$2/${ns}/
# ${cluster_name}/etc that must survive completely untouched.
cat > /tmp/vcfa_select_vks_cluster.sh.template <<'VCFA_SELECT_VKS_TEMPLATE_EOF'
#!/bin/bash
#
# Logs into a VKS Kubernetes cluster via the vcf CLI. The namespace and
# cluster name can either be given directly, or discovered by browsing VCF
# Automation in provider mode (org -> supervisor namespace -> VKS cluster).
#
# Discovery auth uses the programmatic token-generation flow (provider bearer
# token -> org-scoped OAuth token via jwt-bearer exchange), not a service
# account: https://vrealize.it/2025/12/04/vcf-automation-9-programmatic-token-generation/
#
set -euo pipefail

show_help() {
    cat << EOF
Usage: $0 [<namespace> <cluster_name>]
       $0 [-H host] [-u username]

With <namespace> and <cluster_name> given directly, connects straight to that
VKS cluster. With no positional arguments, browses VCF Automation (provider
mode) to pick an org, a supervisor namespace, and a VKS cluster interactively,
then connects to the selection.

Options:
  -H, --host HOST        VCF Automation FQDN/URL, used only for discovery
                          (default: \$VCFA_HOST or https://sddc01-auto-vip.vcf9.lab)
  -u, --username USER    Provider username, used only for discovery
                          (default: \$VCFA_USERNAME or admin)
  -h, --help             Show this help message and exit

Discovery password is read from \$VCFA_PASSWORD if set, otherwise prompted for.

Examples:
  $0 my-namespace my-cluster     # skip discovery, connect directly
  $0                              # browse org/namespace/cluster interactively
EOF
}

HOST="https://${fqdn_vcfa}"
USERNAME="${VCFA_USERNAME:-admin}"
VCFA_PASSWORD='${generic_password}'
POSITIONAL=()

while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host) HOST="$2"; shift 2 ;;
        -u|--username) USERNAME="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        -*) echo "Unknown argument: $1" >&2; show_help; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

# Prompts among multiple choices; auto-selects if there's only one.
# Usage: prompt_choice "Prompt text" "${array[@]}" ; result left in CHOICE
prompt_choice() {
    local prompt="$1"; shift
    local -a options=("$@")
    if [ "${#options[@]}" -eq 0 ]; then
        echo "Error: no options available for: $prompt" >&2
        exit 1
    fi
    if [ "${#options[@]}" -eq 1 ]; then
        CHOICE="${options[0]}"
        echo "$prompt -> only one option, auto-selected: $CHOICE" >&2
        return
    fi
    echo "$prompt" >&2
    local PS3="Select a number: "
    select opt in "${options[@]}"; do
        if [ -n "${opt:-}" ]; then
            CHOICE="$opt"
            break
        fi
        echo "Invalid selection, try again." >&2
    done
}

# Browses VCF Automation (provider mode) and sets ns/cluster_name from the
# selected org/namespace/cluster.
discover_namespace_and_cluster() {
    for cmd in curl jq base64; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required but not installed." >&2; exit 1; }
    done

    if [ -n "${VCFA_PASSWORD:-}" ]; then
        local password="$VCFA_PASSWORD"
    else
        read -rsp "Password for ${USERNAME}@${HOST}: " password
        echo >&2
    fi

    local accept="Accept: application/json;version=9.0.0"

    echo "Logging in to ${HOST} as provider..." >&2
    local creds provider_resp provider_token client_id
    creds=$(printf '%s@system:%s' "$USERNAME" "$password" | base64 -w0)
    provider_resp=$(curl -sk -i -X POST "${HOST}/cloudapi/1.0.0/sessions/provider" \
        -H "$accept" \
        -H "Content-Type: application/json;version=9.0.0" \
        -H "Authorization: Basic ${creds}")

    provider_token=$(printf '%s' "$provider_resp" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
    if [ -z "$provider_token" ]; then
        echo "Error: provider login failed. Response:" >&2
        printf '%s\n' "$provider_resp" >&2
        exit 1
    fi

    client_id=$(curl -sk "${HOST}/cloudapi/1.0.0/openIdProvider/relyingParties" \
        -H "$accept" \
        -H "Authorization: Bearer ${provider_token}" \
        | jq -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
    if [ -z "$client_id" ] || [ "$client_id" == "null" ]; then
        echo "Error: could not determine the automation relying party clientId." >&2
        exit 1
    fi

    # "System" is the built-in provider bucket, not a real tenant org - exclude it.
    local org_lines org_names org_urn org_uuid selected_org
    readarray -t org_lines < <(curl -sk "${HOST}/cloudapi/1.0.0/orgs" \
        -H "$accept" \
        -H "Authorization: Bearer ${provider_token}" \
        | jq -r '.values[] | select(.name != "System") | "\(.name)\t\(.id)"')
    if [ "${#org_lines[@]}" -eq 0 ]; then
        echo "Error: no organizations found." >&2
        exit 1
    fi
    org_names=()
    for line in "${org_lines[@]}"; do org_names+=("${line%%$'\t'*}"); done

    prompt_choice "Available organizations:" "${org_names[@]}"
    selected_org="$CHOICE"
    for line in "${org_lines[@]}"; do
        if [ "${line%%$'\t'*}" == "$selected_org" ]; then
            org_urn="${line##*$'\t'}"
            break
        fi
    done
    org_uuid="${org_urn##*:}"

    echo "Requesting org-scoped token for '${selected_org}'..." >&2
    local org_token
    org_token=$(curl -sk -X POST "${HOST}/oidc/oauth2/token" \
        -H "$accept" \
        -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${provider_token}" \
        --data-urlencode "client_id=${client_id}" \
        | jq -r '.access_token')
    if [ -z "$org_token" ] || [ "$org_token" == "null" ]; then
        echo "Error: failed to obtain an org-scoped token for ${selected_org}." >&2
        exit 1
    fi

    local namespace_lines namespaces namespace_urn
    readarray -t namespace_lines < <(curl -sk "${HOST}/cci/kubernetes/apis/infrastructure.cci.vmware.com/v1alpha3/supervisornamespaces?limit=500" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${org_token}" \
        | jq -r '.items[] | "\(.metadata.name)\t\(.metadata.annotations["infrastructure.cci.vmware.com/id"])"')
    if [ "${#namespace_lines[@]}" -eq 0 ]; then
        echo "Error: no supervisor namespaces found in org '${selected_org}'." >&2
        exit 1
    fi
    namespaces=()
    for line in "${namespace_lines[@]}"; do namespaces+=("${line%%$'\t'*}"); done

    prompt_choice "Available namespaces in org '${selected_org}':" "${namespaces[@]}"
    ns="$CHOICE"
    for line in "${namespace_lines[@]}"; do
        if [ "${line%%$'\t'*}" == "$ns" ]; then
            namespace_urn="${line##*$'\t'}"
            break
        fi
    done

    local clusters
    readarray -t clusters < <(curl -sk "${HOST}/proxy/k8s/namespaces/${namespace_urn}/apis/cluster.x-k8s.io/v1beta2/namespaces/${ns}/clusters?limit=500" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${org_token}" \
        | jq -r '.items[].metadata.name')
    if [ "${#clusters[@]}" -eq 0 ]; then
        echo "Error: no Kubernetes clusters found in namespace '${ns}'." >&2
        exit 1
    fi

    prompt_choice "Available Kubernetes clusters in namespace '${ns}':" "${clusters[@]}"
    cluster_name="$CHOICE"
}

if [ "${#POSITIONAL[@]}" -eq 2 ]; then
    ns="${POSITIONAL[0]}"
    cluster_name="${POSITIONAL[1]}"
elif [ "${#POSITIONAL[@]}" -eq 0 ]; then
    discover_namespace_and_cluster
else
    echo "Error: expected either 0 or 2 positional arguments (namespace, cluster_name)." >&2
    show_help
    exit 1
fi

echo "Connecting to namespace '${ns}', cluster '${cluster_name}'..." >&2
export VCF_CLI_VSPHERE_PASSWORD='${generic_password}'

# vcf context create derives a namespace context named "${ns}:${cluster_name}" and,
# as a related child context, the actual guest/VKS cluster context named
# "${ns}:${cluster_name}:${cluster_name}" - the latter is what we want to log into.
guest_context="${ns}:${cluster_name}:${cluster_name}"

if [[ $(vcf context list -o json | jq -c -r --arg arg "${guest_context}" '[.[] | select( .name == $arg)] | if length > 0 then .[0] else null end') == "null" ]] ; then
  vcf context create "${ns}:${cluster_name}" --type k8s --auth-type basic --endpoint=https://${api_server_cluster_endpoint} --username administrator@vsphere.local --workload-cluster-name "${cluster_name}" --workload-cluster-namespace "${ns}" --insecure-skip-tls-verify
  # vcf context use can exit non-zero on a benign Harbor plugin-discovery
  # warning even after successfully activating the context - don't abort on it.
  vcf context use "${guest_context}" --insecure-skip-tls-verify || true
  kubectl config set-context --current --namespace=default
  kubectl config use-context "${guest_context}"
else
  # vcf context use can exit non-zero on a benign Harbor plugin-discovery
  # warning even after successfully activating the context - don't abort on it.
  vcf context use "${guest_context}" --insecure-skip-tls-verify || true
  kubectl config set-context --current --namespace=default
  kubectl config use-context "${guest_context}"
fi
VCFA_SELECT_VKS_TEMPLATE_EOF
sed -e "s/\${generic_password}/${generic_password}/" \
    -e "s/\${fqdn_vcfa}/${fqdn_vcfa}/" \
    -e "s/\${api_server_cluster_endpoint}/${api_server_cluster_endpoint}/" \
    /tmp/vcfa_select_vks_cluster.sh.template > /home/ubuntu/supervisor/vcfa_select_vks_cluster.sh
rm -f /tmp/vcfa_select_vks_cluster.sh.template
chmod u+x /home/ubuntu/supervisor/vcfa_select_vks_cluster.sh

cat > /tmp/vcfa_select_ns.sh.template <<'VCFA_SELECT_NS_TEMPLATE_EOF'
#!/bin/bash
#
# Browses VCF Automation in provider mode, lets you pick an org and a
# supervisor namespace within it, then assigns the chosen namespace to the
# variable "namespace" (auto-assigned if there's only one).
#
# Auth uses the programmatic token-generation flow (provider bearer token ->
# org-scoped OAuth token via jwt-bearer exchange), not a service account:
# https://vrealize.it/2025/12/04/vcf-automation-9-programmatic-token-generation/
#
set -euo pipefail

show_help() {
    cat << EOF
Usage: $0 [-H host] [-u username]

Browses VCF Automation (provider mode) to pick an org and a supervisor
namespace interactively (auto-selecting when there's only one option), then
assigns the result to the variable "namespace". Run with 'source $0' if you
want "namespace" to persist in your current shell.

Options:
  -H, --host HOST        VCF Automation FQDN/URL (default: \$VCFA_HOST or https://sddc01-auto-vip.vcf9.lab)
  -u, --username USER    Provider username (default: \$VCFA_USERNAME or admin)
  -h, --help             Show this help message and exit

Password is read from \$VCFA_PASSWORD if set, otherwise prompted for.
EOF
}

HOST="https://${fqdn_vcfa}"
USERNAME="${VCFA_USERNAME:-admin}"
VCFA_PASSWORD='${generic_password}'

# Files to update, paired with the jq path of the key to set in each.
NAMESPACE_UPDATE_FILES=(
    /home/ubuntu/yaml-files/secret_vault.yaml
    /home/ubuntu/yaml-files/vault_issuer.yaml
)
NAMESPACE_UPDATE_JQ_PATHS=(
    .metadata.namespace
    .metadata.namespace
)

while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host) HOST="$2"; shift 2 ;;
        -u|--username) USERNAME="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; show_help; exit 1 ;;
    esac
done

for cmd in curl jq base64; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required but not installed." >&2; exit 1; }
done

if [ -n "${VCFA_PASSWORD:-}" ]; then
    PASSWORD="$VCFA_PASSWORD"
else
    read -rsp "Password for ${USERNAME}@${HOST}: " PASSWORD
    echo
fi

ACCEPT="Accept: application/json;version=9.0.0"

# Prompts among multiple choices; auto-selects if there's only one.
# Usage: prompt_choice "Prompt text" "${array[@]}" ; result left in CHOICE
prompt_choice() {
    local prompt="$1"; shift
    local -a options=("$@")
    if [ "${#options[@]}" -eq 0 ]; then
        echo "Error: no options available for: $prompt" >&2
        exit 1
    fi
    if [ "${#options[@]}" -eq 1 ]; then
        CHOICE="${options[0]}"
        echo "$prompt -> only one option, auto-selected: $CHOICE" >&2
        return
    fi
    echo "$prompt" >&2
    local PS3="Select a number: "
    select opt in "${options[@]}"; do
        if [ -n "${opt:-}" ]; then
            CHOICE="$opt"
            break
        fi
        echo "Invalid selection, try again." >&2
    done
}

echo "Logging in to ${HOST} as provider..." >&2
CREDS=$(printf '%s@system:%s' "$USERNAME" "$PASSWORD" | base64 -w0)
PROVIDER_RESP=$(curl -sk -i -X POST "${HOST}/cloudapi/1.0.0/sessions/provider" \
    -H "$ACCEPT" \
    -H "Content-Type: application/json;version=9.0.0" \
    -H "Authorization: Basic ${CREDS}")

PROVIDER_TOKEN=$(printf '%s' "$PROVIDER_RESP" | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
if [ -z "$PROVIDER_TOKEN" ]; then
    echo "Error: provider login failed. Response:" >&2
    printf '%s\n' "$PROVIDER_RESP" >&2
    exit 1
fi

CLIENT_ID=$(curl -sk "${HOST}/cloudapi/1.0.0/openIdProvider/relyingParties" \
    -H "$ACCEPT" \
    -H "Authorization: Bearer ${PROVIDER_TOKEN}" \
    | jq -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" == "null" ]; then
    echo "Error: could not determine the automation relying party clientId." >&2
    exit 1
fi

# "System" is the built-in provider bucket, not a real tenant org - exclude it.
readarray -t ORG_LINES < <(curl -sk "${HOST}/cloudapi/1.0.0/orgs" \
    -H "$ACCEPT" \
    -H "Authorization: Bearer ${PROVIDER_TOKEN}" \
    | jq -r '.values[] | select(.name != "System") | "\(.name)\t\(.id)"')
if [ "${#ORG_LINES[@]}" -eq 0 ]; then
    echo "Error: no organizations found." >&2
    exit 1
fi
ORG_NAMES=()
for line in "${ORG_LINES[@]}"; do ORG_NAMES+=("${line%%$'\t'*}"); done

prompt_choice "Available organizations:" "${ORG_NAMES[@]}"
SELECTED_ORG="$CHOICE"
for line in "${ORG_LINES[@]}"; do
    if [ "${line%%$'\t'*}" == "$SELECTED_ORG" ]; then
        ORG_URN="${line##*$'\t'}"
        break
    fi
done
ORG_UUID="${ORG_URN##*:}"

echo "Requesting org-scoped token for '${SELECTED_ORG}'..." >&2
ORG_TOKEN=$(curl -sk -X POST "${HOST}/oidc/oauth2/token" \
    -H "$ACCEPT" \
    -H "x-vmware-vcloud-tenant-context: ${ORG_UUID}" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "scope=openid profile email phone groups vcd_idp" \
    --data-urlencode "assertion=${PROVIDER_TOKEN}" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    | jq -r '.access_token')
if [ -z "$ORG_TOKEN" ] || [ "$ORG_TOKEN" == "null" ]; then
    echo "Error: failed to obtain an org-scoped token for ${SELECTED_ORG}." >&2
    exit 1
fi

readarray -t NAMESPACES < <(curl -sk "${HOST}/cci/kubernetes/apis/infrastructure.cci.vmware.com/v1alpha3/supervisornamespaces?limit=500" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${ORG_TOKEN}" \
    | jq -r '.items[].metadata.name')
if [ "${#NAMESPACES[@]}" -eq 0 ]; then
    echo "Error: no supervisor namespaces found in org '${SELECTED_ORG}'." >&2
    exit 1
fi

prompt_choice "Available namespaces in org '${SELECTED_ORG}':" "${NAMESPACES[@]}"

export namespace="$CHOICE"
echo "Selected namespace: ${namespace}" >&2
echo "namespace=${namespace}"

echo "Updating namespace in the following YAML files:" >&2
for i in "${!NAMESPACE_UPDATE_FILES[@]}"; do
    echo "  - ${NAMESPACE_UPDATE_FILES[$i]} (${NAMESPACE_UPDATE_JQ_PATHS[$i]})" >&2
done

yaml_to_json() { python3 -c 'import sys, json, yaml; json.dump(yaml.safe_load(sys.stdin), sys.stdout)'; }
# width=100000 prevents PyYAML from line-folding long plain scalars (e.g. base64 blobs).
json_to_yaml() { python3 -c 'import sys, json, yaml; yaml.safe_dump(json.load(sys.stdin), sys.stdout, default_flow_style=False, sort_keys=False, width=100000)'; }

for i in "${!NAMESPACE_UPDATE_FILES[@]}"; do
    f="${NAMESPACE_UPDATE_FILES[$i]}"
    jq_path="${NAMESPACE_UPDATE_JQ_PATHS[$i]}"
    if [ ! -f "$f" ]; then
        echo "Error: ${f} not found." >&2
        exit 1
    fi
    tmp=$(mktemp)
    yaml_to_json < "$f" | jq --arg ns "$namespace" "${jq_path} = \$ns" | json_to_yaml > "$tmp"
    mv "$tmp" "$f"
done
VCFA_SELECT_NS_TEMPLATE_EOF
sed -e "s/\${generic_password}/${generic_password}/" \
    -e "s/\${fqdn_vcfa}/${fqdn_vcfa}/" \
    /tmp/vcfa_select_ns.sh.template > /home/ubuntu/supervisor/vcfa_select_ns.sh
rm -f /tmp/vcfa_select_ns.sh.template
chmod u+x /home/ubuntu/supervisor/vcfa_select_ns.sh

# enable_supervisor_service.sh - registers + activates a Carvel-packaged
# Supervisor Service (e.g. ArgoCD) via vCenter's own API, then enables it
# on a Supervisor-enabled cluster. Ported from the reference project's
# templates/enable_supervisor_service.sh.template verbatim (same quoted-
# heredoc + targeted sed pattern as above).
cat > /tmp/enable_supervisor_service.sh.template <<'ENABLE_SUPERVISOR_SERVICE_TEMPLATE_EOF'
#!/bin/bash
#
# Registers and activates a vCenter Supervisor Service from a Carvel package
# YAML manifest (a "Package" doc plus a "PackageMetadata" doc), via the
# vCenter REST API (com.vmware.vcenter.namespace_management.supervisor_services).
#
# A single POST with version_spec.registered_by_default=true both registers
# and activates the service and its version in one call.
#
set -euo pipefail

show_help() {
    cat << EOF
Usage: $0 [-H host] [-u username] <path-to-supervisor-service-yaml> [path-to-values-yaml]

Registers and activates a vCenter Supervisor Service from the given YAML
manifest. The service identifier, version, display name and description are
derived from the manifest's own Package/PackageMetadata content.

The optional second argument is a fully-rendered values YAML (already
substituted, no \${...} placeholders left) to use as this service's
yaml_service_config on enable - for services needing more than just a
namespace (e.g. Harbor's secrets/storageClass/etc.). When omitted, behavior
is unchanged: just "namespace: <the manifest's own valuesSchema default>".
A "namespace: <default>" line is always prepended, so the values file itself
doesn't need to (and normally shouldn't) set its own namespace key.

Options:
  -H, --host HOST        vCenter FQDN/URL (default: \$VC_HOST or https://sddc01-vc01.vcf9.lab)
  -u, --username USER    vCenter username (default: \$VC_USERNAME or administrator@vsphere.local)
  -h, --help             Show this help message and exit

Password is read from \$VC_PASSWORD if set, otherwise prompted for.

Examples:
  $0 /home/ubuntu/supervisor/supervisor-service-argocd-1.2.0-25642124.yml
  $0 /home/ubuntu/supervisor/supervisor-service-harbor-v2.15.2+vmware.1-vks.1-25639075.yml /tmp/harbor-values-rendered.yml
EOF
}

VC_HOST="https://${vcsa_fqdn}"
VC_USERNAME="${vsphere_nested_username}@${ssoDomain}"
VC_PASSWORD='${generic_password}'
POSITIONAL=()

while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host) VC_HOST="$2"; shift 2 ;;
        -u|--username) VC_USERNAME="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        -*) echo "Unknown argument: $1" >&2; show_help; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [ "${#POSITIONAL[@]}" -lt 1 ] || [ "${#POSITIONAL[@]}" -gt 2 ]; then
    echo "Error: expected one or two arguments - the path to the Supervisor Service YAML, and optionally a rendered values YAML." >&2
    show_help
    exit 1
fi
YAML_FILE="${POSITIONAL[0]}"
VALUES_FILE="${POSITIONAL[1]:-}"

if [ ! -f "$YAML_FILE" ]; then
    echo "Error: ${YAML_FILE} not found." >&2
    exit 1
fi
if [ -n "${VALUES_FILE}" ] && [ ! -f "${VALUES_FILE}" ]; then
    echo "Error: ${VALUES_FILE} not found." >&2
    exit 1
fi

for cmd in curl python3 base64; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required but not installed." >&2; exit 1; }
done

if [ -n "${VC_PASSWORD:-}" ]; then
    PASSWORD="$VC_PASSWORD"
else
    read -rsp "Password for ${VC_USERNAME}@${VC_HOST}: " PASSWORD
    echo
fi

# Prompts among multiple choices; auto-selects if there's only one.
# Usage: prompt_choice "Prompt text" "${array[@]}" ; result left in CHOICE
prompt_choice() {
    local prompt="$1"; shift
    local -a options=("$@")
    if [ "${#options[@]}" -eq 0 ]; then
        echo "Error: no options available for: $prompt" >&2
        exit 1
    fi
    if [ "${#options[@]}" -eq 1 ]; then
        CHOICE="${options[0]}"
        echo "$prompt -> only one option, auto-selected: $CHOICE" >&2
        return
    fi
    echo "$prompt" >&2
    local PS3="Select a number: "
    select opt in "${options[@]}"; do
        if [ -n "${opt:-}" ]; then
            CHOICE="$opt"
            break
        fi
        echo "Invalid selection, try again." >&2
    done
}

# Derive a FALLBACK service identity from the manifest's own refName -
# only actually used below if this turns out to be a genuinely new
# registration (nothing in vCenter's own list matches this manifest's
# displayName yet), since in that case this script's own caller is free
# to pick the id being registered under.
IFS=$'\t' read -r REF_DERIVED_SERVICE_ID VERSION DISPLAY_NAME DESCRIPTION DEFAULT_NAMESPACE < <(python3 - "$YAML_FILE" <<'PYEOF'
import sys, yaml

docs = list(yaml.safe_load_all(open(sys.argv[1])))
package = next(d for d in docs if d.get("kind") == "Package")
metadata = next(d for d in docs if d.get("kind") == "PackageMetadata")

ref_name = package["spec"]["refName"]
version = package["spec"]["version"]
supervisor_service = ref_name.split(".")[0]
if supervisor_service.endswith("-service"):
    supervisor_service = supervisor_service[: -len("-service")]
display_name = metadata["spec"]["displayName"]
description = metadata["spec"]["shortDescription"]
default_namespace = package["spec"]["valuesSchema"]["openAPIv3"]["properties"]["namespace"]["default"]

print(f"{supervisor_service}\t{version}\t{display_name}\t{description}\t{default_namespace}")
PYEOF
)

echo "Logging in to ${VC_HOST}..." >&2
SESSION_ID=$(curl -sk -X POST "${VC_HOST}/api/session" -u "${VC_USERNAME}:${PASSWORD}" | tr -d '"')
if [ -z "$SESSION_ID" ]; then
    echo "Error: vCenter login failed." >&2
    exit 1
fi

# Match by displayName against vCenter's own already-registered list
# first, rather than trusting the refName-derived guess above - a
# built-in service's real supervisor_service identifier can bear no
# resemblance to its own refName (e.g. Harbor: refName
# "harbor.tanzu.vmware.com" but the refName-derived guess above yields
# just "harbor", while the REAL registered id is the full
# "harbor.tanzu.vmware.com" - confirmed live this mismatch made the
# script think Harbor wasn't registered yet, attempt a spurious
# duplicate registration under the wrong id "harbor", which then failed
# on its own downstream k8s object-naming validation since Harbor's
# version string contains a literal "+", invalid in a k8s object name).
# Only falls back to the refName-derived guess for a genuinely new
# registration, where this script's own caller picks the id freely.
echo "Checking whether a service matching '${DISPLAY_NAME}' is already registered..." >&2
LOOKUP=$(curl -sk "${VC_HOST}/api/vcenter/namespace-management/supervisor-services" \
    -H "vmware-api-session-id: ${SESSION_ID}" \
    | python3 -c "
import sys, json
services = json.load(sys.stdin)
match = next((s for s in services if s.get('display_name') == '''${DISPLAY_NAME}'''), None)
if match:
    print(f\"{match['supervisor_service']}\t{match['state']}\")
")
if [ -n "${LOOKUP}" ]; then
    SUPERVISOR_SERVICE="${LOOKUP%%$'\t'*}"
    EXISTING_STATE="${LOOKUP##*$'\t'}"
else
    SUPERVISOR_SERVICE="${REF_DERIVED_SERVICE_ID}"
    EXISTING_STATE=""
fi

if [ -n "$EXISTING_STATE" ]; then
    echo "Supervisor Service '${SUPERVISOR_SERVICE}' is already registered (state: ${EXISTING_STATE})." >&2
else
    echo "Registering and activating '${SUPERVISOR_SERVICE}' (version ${VERSION}) from ${YAML_FILE}..." >&2
    CONTENT_B64=$(base64 -w0 "$YAML_FILE")

    # carvel_spec, not custom_spec - confirmed live by capturing the exact
    # request vSphere Client's own UI sends for this operation (browser
    # devtools). custom_spec (this project's own original design, also
    # what the upstream reference project's own captured guess used) is a
    # generic/simplified wrapper that does NOT retain the manifest's own
    # valuesSchema - it appeared to register successfully, but the later
    # enable-on-cluster step then rejected any nested yaml_service_config
    # with "Nested maps are not allowed for given content type", even
    # though the exact same nested config works fine against a natively
    # (carvel_spec-equivalent) pre-registered service. carvel_spec just
    # takes the raw Package+PackageMetadata YAML content - the server
    # derives supervisor_service/display_name/description/version and,
    # critically, the full valuesSchema itself from the real manifest, so
    # this correctly matches the identifier the "already registered"
    # check ends up looking for too (this project's own DISPLAY_NAME/
    # VERSION variables above are still used for that check and for
    # logging, just not sent back to the server here anymore).
    python3 -c "
import json
body = {
    'carvel_spec': {
        'version_spec': {
            'content': '${CONTENT_B64}'
        }
    }
}
print(json.dumps(body))
" > /tmp/supervisor_service_create_body.json

    HTTP_CODE=$(curl -sk -o /tmp/supervisor_service_create_response.json -w "%{http_code}" \
        -X POST "${VC_HOST}/api/vcenter/namespace-management/supervisor-services" \
        -H "vmware-api-session-id: ${SESSION_ID}" -H "Content-Type: application/json" \
        --data-binary @/tmp/supervisor_service_create_body.json)
    rm -f /tmp/supervisor_service_create_body.json

    if [ "$HTTP_CODE" != "201" ]; then
        echo "Error: failed to create Supervisor Service (HTTP ${HTTP_CODE}):" >&2
        cat /tmp/supervisor_service_create_response.json >&2
        rm -f /tmp/supervisor_service_create_response.json
        exit 1
    fi
    rm -f /tmp/supervisor_service_create_response.json

    # carvel_spec doesn't let the caller pick the id - the server derives
    # it from the manifest's own refName, which does NOT always match the
    # REF_DERIVED_SERVICE_ID guess above (that's the whole reason this
    # falls back to it only when nothing was found - see comment above).
    # Re-run the same displayName lookup now to discover the REAL id the
    # server just assigned, instead of trusting the stale guess: confirmed
    # live this guess is wrong for Harbor (registers as
    # "harbor.tanzu.vmware.com", guess was "harbor"), which made the next
    # status GET 404 and crash on a missing 'state' key before ever
    # reaching the enable-on-cluster step below.
    REGISTERED=$(curl -sk "${VC_HOST}/api/vcenter/namespace-management/supervisor-services" \
        -H "vmware-api-session-id: ${SESSION_ID}" \
        | python3 -c "
import sys, json
services = json.load(sys.stdin)
match = next((s for s in services if s.get('display_name') == '''${DISPLAY_NAME}'''), None)
if match:
    print(f\"{match['supervisor_service']}\t{match['state']}\")
")
    if [ -z "${REGISTERED}" ]; then
        echo "Error: registration reported success but '${DISPLAY_NAME}' can't be found afterwards." >&2
        exit 1
    fi
    SUPERVISOR_SERVICE="${REGISTERED%%$'\t'*}"
    STATE="${REGISTERED##*$'\t'}"
    echo "Supervisor Service '${SUPERVISOR_SERVICE}' registered. Current state: ${STATE}"
fi

# Pick which Supervisor cluster to enable the service on.
readarray -t CLUSTER_LINES < <(curl -sk "${VC_HOST}/api/vcenter/namespace-management/clusters" \
    -H "vmware-api-session-id: ${SESSION_ID}" \
    | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    print(f\"{c['cluster_name']}\t{c['cluster']}\")
")
if [ "${#CLUSTER_LINES[@]}" -eq 0 ]; then
    echo "Error: no Supervisor-enabled clusters found." >&2
    exit 1
fi
CLUSTER_NAMES=()
for line in "${CLUSTER_LINES[@]}"; do CLUSTER_NAMES+=("${line%%$'\t'*}"); done

prompt_choice "Available clusters:" "${CLUSTER_NAMES[@]}"
SELECTED_CLUSTER_NAME="$CHOICE"
for line in "${CLUSTER_LINES[@]}"; do
    if [ "${line%%$'\t'*}" == "$SELECTED_CLUSTER_NAME" ]; then
        CLUSTER_ID="${line##*$'\t'}"
        break
    fi
done

echo "Checking whether '${SUPERVISOR_SERVICE}' is already enabled on cluster '${SELECTED_CLUSTER_NAME}'..." >&2
CLUSTER_SVC_HTTP=$(curl -sk -o /tmp/cluster_svc_status.json -w "%{http_code}" \
    "${VC_HOST}/api/vcenter/namespace-management/clusters/${CLUSTER_ID}/supervisor-services/${SUPERVISOR_SERVICE}" \
    -H "vmware-api-session-id: ${SESSION_ID}")

if [ "$CLUSTER_SVC_HTTP" == "200" ]; then
    CONFIG_STATUS=$(python3 -c "import json; print(json.load(open('/tmp/cluster_svc_status.json')).get('config_status'))")
    rm -f /tmp/cluster_svc_status.json
    echo "Supervisor Service '${SUPERVISOR_SERVICE}' is already enabled on '${SELECTED_CLUSTER_NAME}' (config_status: ${CONFIG_STATUS})."
    exit 0
fi
rm -f /tmp/cluster_svc_status.json

echo "Enabling '${SUPERVISOR_SERVICE}' (version ${VERSION}) on cluster '${SELECTED_CLUSTER_NAME}'..." >&2
if [ -n "${VALUES_FILE}" ]; then
    CONFIG_B64=$( { printf 'namespace: %s\n' "$DEFAULT_NAMESPACE"; cat "${VALUES_FILE}"; } | base64 -w0)
else
    CONFIG_B64=$(printf 'namespace: %s\n' "$DEFAULT_NAMESPACE" | base64 -w0)
fi

python3 -c "
import json
body = {'supervisor_service': '${SUPERVISOR_SERVICE}', 'version': '${VERSION}', 'yaml_service_config': '${CONFIG_B64}'}
print(json.dumps(body))
" > /tmp/cluster_svc_enable_body.json

# Retry - confirmed live this can 500 with "signature verification
# result not found for Supervisor Service ... on Supervisor ..." right
# after registration, since vCenter/WCP's own async compatibility/
# signature check for the just-registered service version hasn't
# caught up yet. Same class of "backend needs a moment" race as
# several other fixes in this project (Avi controller discovery, VCF
# instance refresh, region network-stack checks) - safe to retry since
# nothing here is destructive, just re-POSTing the same enable request.
ENABLE_RETRY=6
for enable_attempt in $(seq 1 ${ENABLE_RETRY}); do
    HTTP_CODE=$(curl -sk -o /tmp/cluster_svc_enable_response.json -w "%{http_code}" \
        -X POST "${VC_HOST}/api/vcenter/namespace-management/clusters/${CLUSTER_ID}/supervisor-services" \
        -H "vmware-api-session-id: ${SESSION_ID}" -H "Content-Type: application/json" \
        --data-binary @/tmp/cluster_svc_enable_body.json)
    if [ "$HTTP_CODE" == "204" ]; then
        break
    fi
    if [ "${enable_attempt}" == "${ENABLE_RETRY}" ]; then
        echo "Error: failed to enable Supervisor Service on cluster (HTTP ${HTTP_CODE}) after ${ENABLE_RETRY} attempts:" >&2
        cat /tmp/cluster_svc_enable_response.json >&2
        rm -f /tmp/cluster_svc_enable_body.json /tmp/cluster_svc_enable_response.json
        exit 1
    fi
    echo "  attempt ${enable_attempt}/${ENABLE_RETRY}: HTTP ${HTTP_CODE}, retrying in 15s..." >&2
    sleep 15
done
rm -f /tmp/cluster_svc_enable_body.json
rm -f /tmp/cluster_svc_enable_response.json

echo "Waiting for '${SUPERVISOR_SERVICE}' to reconcile on '${SELECTED_CLUSTER_NAME}'..." >&2
CONFIG_STATUS="CONFIGURING"
# 60x10s=10min, not 30x10s=5min - confirmed live a multi-component service
# like Harbor (7-8 pods: core/database/jobservice/nginx/portal/redis/
# registry/trivy, each pulling its own image and provisioning its own PVC)
# comfortably needs more than 5 minutes; a fast single-component service
# like ArgoCD still exits this loop on its first non-CONFIGURING check
# either way, so raising the ceiling doesn't slow that case down.
for i in $(seq 1 60); do
    POLL_HTTP_CODE=$(curl -sk -o /tmp/cluster_svc_poll.json -w "%{http_code}" \
        "${VC_HOST}/api/vcenter/namespace-management/clusters/${CLUSTER_ID}/supervisor-services/${SUPERVISOR_SERVICE}" \
        -H "vmware-api-session-id: ${SESSION_ID}")
    # A non-200 response here is a transient race right after enabling, not a real
    # terminal state - keep polling instead of treating it as done.
    if [ "$POLL_HTTP_CODE" == "200" ]; then
        CONFIG_STATUS=$(python3 -c "import json; print(json.load(open('/tmp/cluster_svc_poll.json')).get('config_status') or 'CONFIGURING')")
    fi
    rm -f /tmp/cluster_svc_poll.json
    echo "  [$i] (HTTP ${POLL_HTTP_CODE}) config_status=${CONFIG_STATUS}" >&2
    if [ "$CONFIG_STATUS" != "CONFIGURING" ]; then
        break
    fi
    sleep 10
done

echo "Supervisor Service '${SUPERVISOR_SERVICE}' on cluster '${SELECTED_CLUSTER_NAME}': config_status=${CONFIG_STATUS}"
ENABLE_SUPERVISOR_SERVICE_TEMPLATE_EOF
#
# ssoDomain is never a plain bash variable in this script's own scope
# (only available via jq against $jsonFile, see the vcf-context-create
# render a few hundred lines up) - using bare ${ssoDomain} here
# substituted empty, baking VC_USERNAME="administrator@" (no domain)
# into the rendered enable_supervisor_service.sh, which made every
# vCenter API call in it 401 (confirmed live: 401 UNAUTHENTICATED on
# /api/vcenter/namespace-management/supervisor-services, its raw error
# object then iterated by the Python one-liner as if it were a service
# list, producing "AttributeError: 'str' object has no attribute
# 'get'").
#
sed -e "s/\${generic_password}/${generic_password}/" \
    -e "s/\${ssoDomain}/$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)/" \
    -e "s/\${vsphere_nested_username}/${vsphere_nested_username}/" \
    -e "s/\${vcsa_fqdn}/${vcsa_fqdn}/" \
    /tmp/enable_supervisor_service.sh.template > /home/ubuntu/supervisor/enable_supervisor_service.sh
rm -f /tmp/enable_supervisor_service.sh.template
chmod u+x /home/ubuntu/supervisor/enable_supervisor_service.sh

#
# harbor_rewrite_images.sh - generic, no baked-in environment values (unlike
# enable_supervisor_service.sh above), so no sed-render step: registry
# hostname/project are CLI args, not template placeholders, so this one
# script stays reusable standalone, any time after this environment's own
# Harbor is up, against any manifest referencing images pushed there (e.g.
# demo-http-apps.yaml's own tacobayle/busybox-vN Docker Hub references)
# without needing regeneration.
#
cat > /home/ubuntu/supervisor/harbor_rewrite_images.sh <<'HARBOR_REWRITE_IMAGES_EOF'
#!/bin/bash
#
# Rewrites every container image reference in a Kubernetes manifest (any
# number of YAML documents) to point at this environment's own Harbor
# instead of wherever it originally came from (e.g. Docker Hub) - lets an
# already-authored manifest be redirected with no other edits, once the
# same image has been pushed to Harbor under the given project (see
# vcf_bootstrap.sh's own harbor image-preload step for the push side).
#
# Usage: harbor_rewrite_images.sh <harbor-fqdn> <project> <yaml-file> [image-name ...]
#   <yaml-file> is rewritten in place.
#   [image-name ...] optionally restricts rewriting to only images whose
#   basename (the final path segment, before any tag) matches one of these
#   - omit to rewrite every container image in the file unconditionally.
#
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <harbor-fqdn> <project> <yaml-file> [image-name ...]" >&2
    exit 1
fi
HARBOR_FQDN="$1"
PROJECT="$2"
YAML_FILE="$3"
shift 3

if [ ! -f "${YAML_FILE}" ]; then
    echo "Error: ${YAML_FILE} not found." >&2
    exit 1
fi

HARBOR_FQDN="${HARBOR_FQDN}" PROJECT="${PROJECT}" python3 - "$YAML_FILE" "$@" <<'PYEOF'
import os, sys
import yaml

yaml_file = sys.argv[1]
names = set(sys.argv[2:])
harbor_fqdn = os.environ["HARBOR_FQDN"]
project = os.environ["PROJECT"]

def rewrite(image):
    base = image.rsplit("/", 1)[-1]
    name, _, tag = base.partition(":")
    if names and name not in names:
        return image
    return f"{harbor_fqdn}/{project}/{name}:{tag or 'latest'}"

def walk_containers(spec):
    if not spec:
        return
    for key in ("containers", "initContainers"):
        for c in spec.get(key, []) or []:
            if "image" in c:
                c["image"] = rewrite(c["image"])

docs = list(yaml.safe_load_all(open(yaml_file)))
for doc in docs:
    if not doc:
        continue
    kind = doc.get("kind")
    if kind == "Pod":
        walk_containers(doc.get("spec"))
    elif kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        walk_containers((doc.get("spec") or {}).get("template", {}).get("spec"))
    elif kind == "CronJob":
        walk_containers((((doc.get("spec") or {}).get("jobTemplate") or {}).get("spec") or {}).get("template", {}).get("spec"))

with open(yaml_file, "w") as f:
    yaml.safe_dump_all(docs, f, default_flow_style=False, sort_keys=False)
PYEOF
HARBOR_REWRITE_IMAGES_EOF
chmod u+x /home/ubuntu/supervisor/harbor_rewrite_images.sh

#
# Supervisor Services (spec.sddc.vcenter.supervisor_services) - unlike the
# reference project (which downloads each by url - gw here has no route to
# arbitrary external hosts), each entry names a file expected to already be
# sitting at /home/ubuntu/<name>, delivered there by gw-setup.sh.tpl's own
# generic vcf_cli_iso passthrough loop (add the file to that Iso CR's
# spec.files list - no cloud-init changes needed here). Optional - skipped
# entirely if unset/empty.
#
if [ -z "${supervisor_services}" ] || [ "${supervisor_services}" == "null" ] || [ "${supervisor_services}" == "[]" ]; then
  log_notify "no supervisor_services configured, skipping"
else
  while read -r item
  do
    svc_type="$(echo ${item} | jq -c -r '.type // "carvel-yaml"')"

    if [ "${svc_type}" == "harbor" ]; then
      #
      # Harbor is already globally registered/ACTIVATED in this VCF 9.1
      # environment (confirmed live via GET
      # api/vcenter/namespace-management/supervisor-services), so no real
      # Package/PackageMetadata registration is needed - but .name still
      # names the real upstream registration manifest (ISO-delivered like
      # everything else) so enable_supervisor_service.sh's own "already
      # registered, skip" check runs against real content, keeping this
      # portable to a VCF environment where Harbor isn't pre-registered.
      # What Harbor genuinely needs beyond that generic script is a much
      # richer yaml_service_config than "namespace: X" alone (6 required
      # secrets, 5 PVC storageClass entries, enableNginxLoadBalancer,
      # tlsSecretLabels) - values_template names a SECOND ISO-delivered
      # file (the actual data-values template, with ${...} placeholders)
      # rendered here and passed as enable_supervisor_service.sh's new
      # optional second argument.
      #
      # Confirmed live end-to-end on this exact environment:
      # enableNginxLoadBalancer: true (baked into the values template,
      # not overridden here) is required, not the Ingress path - there is
      # no IngressClass registered at the Supervisor level at all (AKO's
      # own IngressClass only exists inside guest VKS clusters), so
      # Avi/AKO instead reconciles plain type: LoadBalancer Services
      # directly, which is exactly what enableNginxLoadBalancer: true
      # produces. This also happens to be the one path that avoids
      # harbor-portal's own nginx crashing with "socket() [::]:8443
      # failed (97: Address family not supported by protocol)" on this
      # IPv6-less cluster - the Ingress path hits that crash regardless
      # of network.ipFamilies (confirmed live that setting has no effect
      # on the portal's own nginx template in this chart version).
      #
      name="$(echo ${item} | jq -c -r '.name // empty')"
      values_template_name="$(echo ${item} | jq -c -r '.values_template // empty')"
      # Not user-configurable - always the same well-known FQDN pattern
      # every other Avi-fronted hostname in this deployment already uses
      # (see avi_dns_domains_json/vsvip_json above), under the
      # Avi-delegated app.vcf9.lab-style zone so dns-vs can serve it once
      # registered below - no CRD/CR field needed.
      harbor_hostname="harbor.${avi_subdomain}.${domain}"
      if [ -z "${name}" ] || [ -z "${values_template_name}" ]; then
        log_notify "ERROR: harbor supervisor_services entry needs name and values_template, skipping: ${item}"
        continue
      fi
      service_file="/home/ubuntu/${name}"
      values_template_file="/home/ubuntu/${values_template_name}"
      if [ ! -f "${service_file}" ] || [ ! -f "${values_template_file}" ]; then
        log_notify "ERROR: harbor supervisor service file(s) not found (${service_file}, ${values_template_file}) - were they added to vms.gw.iso's Iso CR?"
        continue
      fi

      # Secrets are generated here, not authored in the CR - they're
      # meaningless random strings with no reason to be memorable or
      # CR-visible. storageClass reuses this project's own deterministic
      # cluster-naming convention ("${basename_sddc}-cluster", same
      # pattern as VC_CLUSTER in vcenter-bootstrap.sh and the cluster_id
      # lookups in nsx-bootstrap.sh) rather than deriving it via VCFA's
      # regionStoragePolicies API (VCFA org provisioning runs much later
      # in this script, and Harbor's PVCs are a direct Supervisor-level
      # StorageClass reference, unrelated to VCFA). Confirmed live
      # (2026-09-24) this previously referenced a bare ${cluster_name}
      # that was never actually assigned anywhere in this script nor
      # exported by bash/variables.sh - resolved to empty, silently
      # producing "-vsan-storage-policy" instead.
      harbor_storage_class="${basename_sddc}-cluster-vsan-storage-policy"
      harbor_admin_password="${generic_password}"
      harbor_secret_key=$(echo -n "${generic_password}harbor-secretkey" | md5sum | cut -c1-16)
      harbor_database_password=$(echo -n "${generic_password}harbor-database" | md5sum | cut -c1-16)
      harbor_core_secret=$(echo -n "${generic_password}harbor-core" | md5sum | cut -c1-16)
      harbor_core_xsrf_key_raw=$(echo -n "${generic_password}harbor-xsrf" | md5sum)
      harbor_core_xsrf_key="${harbor_core_xsrf_key_raw}${harbor_core_xsrf_key_raw}"
      harbor_core_xsrf_key="${harbor_core_xsrf_key:0:32}"
      harbor_jobservice_secret=$(echo -n "${generic_password}harbor-jobservice" | md5sum | cut -c1-16)
      harbor_registry_secret=$(echo -n "${generic_password}harbor-registry" | md5sum | cut -c1-16)

      # Python literal string replacement, not sed - harbor_admin_password
      # is this deployment's own generic_password verbatim, which may
      # contain almost any character (confirmed live: this environment's
      # own password contains "@", which broke a sed s@...@...@ delimiter
      # here outright). Values are passed via environment variables, not
      # embedded into the Python source itself, so no shell-quoting or
      # string-escaping concern either regardless of what they contain.
      rendered_values_file="/tmp/harbor-values-rendered.yml"
      HARBOR_HOSTNAME="${harbor_hostname}" \
      HARBOR_ADMIN_PASSWORD="${harbor_admin_password}" \
      HARBOR_SECRET_KEY="${harbor_secret_key}" \
      HARBOR_DATABASE_PASSWORD="${harbor_database_password}" \
      HARBOR_CORE_SECRET="${harbor_core_secret}" \
      HARBOR_CORE_XSRF_KEY="${harbor_core_xsrf_key}" \
      HARBOR_JOBSERVICE_SECRET="${harbor_jobservice_secret}" \
      HARBOR_REGISTRY_SECRET="${harbor_registry_secret}" \
      HARBOR_STORAGE_CLASS="${harbor_storage_class}" \
      python3 -c "
import os
text = open('${values_template_file}').read()
for placeholder, env_var in [
    ('\${harbor_hostname}', 'HARBOR_HOSTNAME'),
    ('\${harbor_admin_password}', 'HARBOR_ADMIN_PASSWORD'),
    ('\${harbor_secret_key}', 'HARBOR_SECRET_KEY'),
    ('\${harbor_database_password}', 'HARBOR_DATABASE_PASSWORD'),
    ('\${harbor_core_secret}', 'HARBOR_CORE_SECRET'),
    ('\${harbor_core_xsrf_key}', 'HARBOR_CORE_XSRF_KEY'),
    ('\${harbor_jobservice_secret}', 'HARBOR_JOBSERVICE_SECRET'),
    ('\${harbor_registry_secret}', 'HARBOR_REGISTRY_SECRET'),
    ('\${harbor_storage_class}', 'HARBOR_STORAGE_CLASS'),
]:
    text = text.replace(placeholder, os.environ[env_var])
open('${rendered_values_file}', 'w').write(text)
"

      /home/ubuntu/supervisor/enable_supervisor_service.sh "${service_file}" "${rendered_values_file}"
      rm -f "${rendered_values_file}"

      # Register harbor_hostname with Avi now that harbor-nginx's own
      # LoadBalancer Service has a real VIP - app.vcf9.lab (or whatever
      # zone harbor_hostname falls under) is delegated to Avi's own
      # dns-vs Virtual Service (confirmed live: the dns-avi
      # IPAMDNSProviderProfile's dns_service_domain lists app.vcf9.lab),
      # and arbitrary FQDN->IP static mappings not tied to an
      # Avi-managed Ingress/Service belong on dns-vs's own
      # static_dns_records field directly (confirmed live via a
      # UI-added entry's resulting API payload) - not per-VS dns_info,
      # which only applies to VSes Avi itself created from an
      # Ingress/Service hostname.
      kubectl config use-context "${supervisor_cluster_name}" >&2
      harbor_namespace="$(kubectl get namespaces -o name | grep -o 'svc-harbor-[a-z0-9]*' | head -1)"
      if [ -z "${harbor_namespace}" ]; then
        log_notify "ERROR: harbor namespace (svc-harbor-*) not found - skipping DNS registration for ${harbor_hostname}"
      else
        #
        # Harbor generates its own self-signed root ("Harbor CA", confirmed
        # live 2026-09-25 via the harbor-ca-key-pair secret's ca.crt -
        # subject and issuer both "CN = Harbor CA") - no external cert-
        # manager/Vault issuer is involved despite the values template's
        # tlsSecretLabels field. Guest VKS clusters do NOT trust this
        # automatically (disproves this block's own prior comment below,
        # which claimed a "managed-by: vmware-vRegistry" auto-propagation
        # mechanism handled it - live testing on org-1's vks-cluster-p6fn8,
        # created well after this point in the run, showed
        # "x509: certificate signed by unknown authority" pulling from
        # Harbor). Persisted to a well-known file here (separate process
        # from configure_vcfa.sh, which is what actually creates VKS
        # clusters and needs this content for each one's
        # trust.additionalTrustedCAs ClusterClass variable).
        #
        harbor_ca_cert_path="/home/ubuntu/harbor-ca.crt"
        if [ ! -s "${harbor_ca_cert_path}" ]; then
          kubectl get secret -n "${harbor_namespace}" harbor-ca-key-pair -o jsonpath='{.data.ca\.crt}' | base64 -d > "${harbor_ca_cert_path}"
          log_notify "Saved Harbor's self-signed CA to ${harbor_ca_cert_path} for VKS clusters' trust.additionalTrustedCAs"
        fi

        harbor_ip=""
        for attempt_harbor_ip in $(seq 1 12); do
          harbor_ip="$(kubectl get svc -n "${harbor_namespace}" harbor-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
          [ -n "${harbor_ip}" ] && break
          sleep 10
        done
        if [ -z "${harbor_ip}" ]; then
          log_notify "ERROR: harbor-nginx Service in ${harbor_namespace} has no LoadBalancer IP after waiting - skipping DNS registration for ${harbor_hostname}"
        else
          #
          # ip_avi is never a bash/variables.sh export - confirmed live
          # this was always empty here, making avi_login's own curl POST
          # go to https:///login (no host at all), failing fast and
          # consistently with "csrftoken is undefined after login" every
          # run. avi-bootstrap.sh only ever computes this itself, locally
          # (ip_avi=$(echo ${ips_avi} | jq -r '.[0]')) - since every phase
          # script is its own separate process, that never carries over
          # here. Same derivation, reused verbatim.
          #
          ip_avi=$(echo ${ips_avi} | jq -r '.[0]')
          avi_login
          avi_api 3 3 GET "" "api/virtualservice?name=dns-vs"
          dns_vs_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
          avi_api 3 3 GET "" "api/virtualservice/${dns_vs_uuid}"
          static_dns_records=$(echo ${response_body} | jq -c --arg fqdn "${harbor_hostname}" --arg ip "${harbor_ip}" \
            '[.static_dns_records[]? | select(.fqdn != [$fqdn])] + [{type: "DNS_RECORD_A", algorithm: "DNS_RECORD_RESPONSE_ROUND_ROBIN", fqdn: [$fqdn], ip_address: [{ip_address: {addr: $ip, type: "V4"}}]}]')
          avi_api 3 3 PATCH "$(jq -n --argjson records "${static_dns_records}" '{replace: {static_dns_records: $records}}')" "api/virtualservice/${dns_vs_uuid}"
          log_notify "Registered DNS record ${harbor_hostname} -> ${harbor_ip} on Avi's dns-vs"

          # Optional image preload (spec's 'images', ISO-delivered
          # OCI-archive tarballs) - pushed straight to Harbor's own
          # LoadBalancer IP rather than harbor_hostname, since the DNS
          # record above may take a moment to propagate through gw's own
          # BIND delegation to Avi's dns-vs even though it was already
          # confirmed live to resolve correctly end-to-end once settled.
          # harbor_admin_password was already derived above, alongside
          # this same entry's other secrets. This push itself only needs
          # --dest-tls-verify=false (skopeo talking directly to Harbor,
          # not through a VKS guest cluster's own trust store) - the
          # earlier claim here that guest clusters trust Harbor's CA
          # automatically was disproven live 2026-09-25 (see
          # harbor_ca_cert_path above) and is fixed in configure_vcfa.sh's
          # VKS cluster creation instead.
          harbor_images_json="$(echo ${item} | jq -c '.images // []')"
          if [ "${harbor_images_json}" != "[]" ]; then
            if ! command -v skopeo >/dev/null 2>&1; then
              sudo apt-get install -y skopeo || log_notify "ERROR: apt-get install skopeo failed, skipping harbor image preload"
            fi
            if command -v skopeo >/dev/null 2>&1; then
              harbor_registry_project="registry"
              project_check_code=$(curl -sk -o /dev/null -w "%{http_code}" -u "admin:${harbor_admin_password}" \
                "https://${harbor_ip}/api/v2.0/projects/${harbor_registry_project}")
              if [ "${project_check_code}" == "404" ]; then
                curl -sk -u "admin:${harbor_admin_password}" -X POST "https://${harbor_ip}/api/v2.0/projects" \
                  -H "Content-Type: application/json" \
                  -d "$(jq -n --arg name "${harbor_registry_project}" '{project_name: $name, public: true}')" >/dev/null
              fi
              echo "${harbor_images_json}" | jq -c -r .[] | while read -r image_file
              do
                image_path="/home/ubuntu/${image_file}"
                if [ ! -f "${image_path}" ]; then
                  log_notify "ERROR: harbor image ${image_file} not found at ${image_path} - was it added to vms.gw.iso's Iso CR?"
                  continue
                fi
                image_name="$(basename "${image_file}" .tar.gz)"
                image_name="$(basename "${image_name}" .tar)"
                if skopeo copy --dest-tls-verify=false --dest-creds "admin:${harbor_admin_password}" \
                    "oci-archive:${image_path}" "docker://${harbor_ip}/${harbor_registry_project}/${image_name}:latest"; then
                  log_notify "Pushed ${image_file} to Harbor as ${harbor_registry_project}/${image_name}:latest (pull via ${harbor_hostname}/${harbor_registry_project}/${image_name}:latest)"
                else
                  log_notify "ERROR: failed to push ${image_file} to Harbor"
                fi
              done
            fi
          fi
        fi
      fi

      continue
    fi

    # carvel-yaml (default) - existing behavior, unchanged.
    name="$(echo ${item} | jq -c -r '.name // empty')"
    if [ -z "${name}" ]; then
      log_notify "ERROR: supervisor_services entry has no name, skipping: ${item}"
      continue
    fi
    service_file="/home/ubuntu/${name}"
    if [ ! -f "${service_file}" ]; then
      log_notify "ERROR: supervisor service file ${name} not found at ${service_file} - was it added to vms.gw.vcf_cli_iso's Iso CR?"
      continue
    fi
    /home/ubuntu/supervisor/enable_supervisor_service.sh "${service_file}"
  done < <(echo "${supervisor_services}" | jq -c -r .[])
fi

log_notify "Supervisor cluster ready, auth helper scripts written to /home/ubuntu/supervisor/"
