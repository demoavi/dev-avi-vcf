#!/bin/bash
#
# Optional vanilla Kubernetes cluster (kubeadm + Antrea + AKO with Gateway API) on an NSX segment of the nested
# vCenter: 1 control-plane node + k8s_worker_count workers, built from the Ubuntu cloud-image OVA that the gw-tools
# Iso CR put on gw (/home/ubuntu/<k8s_ova_filename>). A shared platform for services that are not available as
# Supervisor Services: Helm releases on this cluster, exposed through AKO (Gateway + HTTPRoute -> an Avi virtual
# service, the hostname is registered in Avi's DNS virtual service automatically).
#
# Kubernetes version: pick one AKO supports - AKO exits at start ("Unsupported kubernetes apiserver version
# detected") outside the min/max range compiled into its release (AKO 2.2.1: 1.29-1.34), however new the cluster.
#
# Switch: spec.sddc.k8s.enabled in the CR (-> k8s_enabled). Everything else is in variables.json's "k8s" block
# (-> k8s_* in variables.sh): cluster name, worker count, Kubernetes/Antrea/Gateway API/AKO versions, pod and
# service CIDR, node size, segment, first static IP (k8s_static_ip_offset), content library, OVA filename.
#
# Nodes get STATIC addresses on the segment: <segment /24>.<offset>, .<offset+1>, ... (outside the segment's DHCP
# range and Avi SE pool), the segment's gateway and gw (ip_gw) as DNS server, written by cloud-init (netplan).
#
# How: the OVA is imported once into a dedicated content library (k8s_content_library_name), each node is deployed
# from it with govc (cloud-init: hostname, ssh key, static netplan), resized and powered on. gw then drives the nodes
# over SSH (key generated here if missing): prerequisites + containerd + kubeadm/kubelet/kubectl at the pinned version
# on every node, kubeadm init on the control plane, a fresh join command for each worker not yet in the cluster.
# Then, from gw with the cluster's kubeconfig (/home/ubuntu/k8s/<cluster name>.kubeconfig):
#   - Antrea (CNI) with NodePortLocal enabled - AKO then reaches the pods directly (serviceType NodePortLocal,
#     no static routes to sync);
#   - the upstream Gateway API CRDs (gateway.networking.k8s.io, k8s_gateway_api_version). AKO's chart does NOT ship
#     them, yet with GatewayAPI on it renders a GatewayClass of that group, so they must exist first;
#   - AKO (helm, k8s_ako_version) in its own namespace (k8s_ako_namespace, created by helm after the cluster is up),
#     values built from this deployment's Avi controller/cloud/segments (the same values the nested-vsphere
#     project's deploy_k8s.sh templated). The chart creates the GatewayClass avi-lb.
#
# Idempotent: an existing VM, an initialised control plane, a joined node, an installed CNI/CRDs/AKO is left alone;
# a cluster whose nodes are all Ready and whose AKO pod is Ready is not touched at all.
# NON-FATAL: vcf_bootstrap.sh aborts the whole pipeline when a phase exits non-zero, and nothing later depends on
# this cluster, so every failure here is logged (log_notify ERROR) and the script exits 0.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

if [ "${k8s_enabled}" != "true" ]; then
  log_only "sddc.k8s.enabled is not true, skipping the Kubernetes cluster"
  exit 0
fi
vcd_login
log_notify "k8s-bootstrap.sh started"

k8s_fail() {
  log_notify "ERROR: k8s-bootstrap: $1 - the Kubernetes cluster ${k8s_cluster_name} is not (fully) built, continuing with the rest of the deployment"
  exit 0
}

k8s_dir="${K8S_WORK_DIR:-/home/ubuntu/k8s}"
mkdir -p "${k8s_dir}"
kubeconfig="${k8s_dir}/${k8s_cluster_name}.kubeconfig"
ssh_key="${k8s_dir}/id_ed25519"
ova_file="/home/ubuntu/${k8s_ova_filename}"
library_item="$(basename "${k8s_ova_filename}" .ova)"
total_nodes=$((1 + k8s_worker_count))
node_names="${k8s_cluster_name}-cp1"
for ((i = 1; i <= k8s_worker_count; i++)); do node_names="${node_names} ${k8s_cluster_name}-w${i}"; done
ssh_opts=(-i "${ssh_key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 -o LogLevel=ERROR)
node_ssh() { local ip=$1; shift; ssh "${ssh_opts[@]}" "${k8s_ssh_user}@${ip}" "$@"; }
kc() { kubectl --kubeconfig "${kubeconfig}" "$@"; }
helm_k() { helm --kubeconfig "${kubeconfig}" "$@"; }

#
# Already built? (kubeconfig answers, every node is Ready and AKO is installed)
#
if [ -s "${kubeconfig}" ]; then
  ready_nodes=$(kc get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)
  if [ "${ready_nodes}" -ge "${total_nodes}" ] && kc -n "${k8s_ako_namespace}" wait --for=condition=Ready pod/ako-0 --timeout=5s > /dev/null 2>&1; then
    log_notify "Kubernetes cluster ${k8s_cluster_name} already has ${ready_nodes} Ready nodes and a running AKO, nothing to do (kubeconfig: ${kubeconfig})"
    exit 0
  fi
fi

[ -f "${ova_file}" ] || k8s_fail "${ova_file} not found - was ${k8s_ova_filename} added to vms.gw.iso's Iso CR (gw-tools)?"
for tool in kubectl govc helm jq python3; do
  command -v "${tool}" > /dev/null 2>&1 || k8s_fail "${tool} is not installed on gw"
done

#
# Network plan: the segment's /24, gateway and tier-1 from nsx_segments_overlay; static node IPs from the offset;
# the segment that Avi uses for VIPs (avi_ipam_vip) is AKO's VIP network.
#
segment_json=$(echo "${nsx_segments_overlay}" | jq -c --arg n "${k8s_segment}" '.[] | select(.display_name == $n)')
[ -n "${segment_json}" ] || k8s_fail "segment ${k8s_segment} is not in the NSX overlay segment list"
segment_three_octets=$(echo "${segment_json}" | jq -r '.cidr' | cut -d/ -f1 | cut -d. -f1-3)
segment_prefix=$(echo "${segment_json}" | jq -r '.cidr' | cut -d/ -f2)
segment_gateway=$(echo "${segment_json}" | jq -r '.gateway_address' | cut -d/ -f1)
segment_tier1=$(echo "${segment_json}" | jq -r '.tier1')
vip_segment=$(echo "${nsx_segments_overlay}" | jq -r '[.[] | select(.avi_ipam_vip != null) | .display_name][0] // empty')
[ -n "${segment_three_octets}" ] && [ -n "${segment_gateway}" ] && [ -n "${vip_segment}" ] || k8s_fail "unable to derive the network plan from nsx_segments_overlay (segment ${k8s_segment}, VIP segment ${vip_segment})"
declare -A node_ips
node_index=0
for vm_name in ${node_names}; do
  node_ips[${vm_name}]="${segment_three_octets}.$((k8s_static_ip_offset + node_index))"
  ((node_index++))
done

if [ ! -f "${ssh_key}" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "k8s-bootstrap@gw" -f "${ssh_key}" || k8s_fail "ssh-keygen failed"
fi
ssh_public_key="$(cat "${ssh_key}.pub")"

#
# vCenter (same connection as vcenter-bootstrap.sh)
#
export GOVC_URL="${basename_sddc}-vc01.${domain}"
export GOVC_USERNAME="administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)"
export GOVC_PASSWORD="${generic_password}"
export GOVC_DATACENTER="${basename_sddc}-dc"
export GOVC_INSECURE=true
export GOVC_PERSIST_SESSION=false
unset GOVC_CLUSTER GOVC_DATASTORE GOVC_RESOURCE_POOL
govc about > /dev/null 2>&1 || k8s_fail "unable to connect to vCenter ${GOVC_URL}"
# govc ls (like library.ls) exits 0 for an inventory path that does not exist: look the path up in its parent's listing
govc_has() { govc ls "$(dirname "$1")" 2> /dev/null | grep -qx "$1"; }
vc_cluster="${basename_sddc}-cluster"
# the vSAN datastore if there is one, else the first one
datastore_name=$(govc ls "/${GOVC_DATACENTER}/datastore" | xargs -n1 basename | grep -i vsan | head -1)
[ -n "${datastore_name}" ] || datastore_name=$(govc ls "/${GOVC_DATACENTER}/datastore" | xargs -n1 basename | head -1)
[ -n "${datastore_name}" ] || k8s_fail "no datastore found in ${GOVC_DATACENTER}"
resource_pool="/${GOVC_DATACENTER}/host/${vc_cluster}/Resources"
govc_has "${resource_pool}" || k8s_fail "resource pool ${resource_pool} not found"
govc_has "/${GOVC_DATACENTER}/network/${k8s_segment}" || k8s_fail "network ${k8s_segment} not found in vCenter"
vm_folder="/${GOVC_DATACENTER}/vm/${k8s_cluster_name}"
govc_has "${vm_folder}" || govc folder.create "${vm_folder}" > /dev/null || k8s_fail "unable to create folder ${vm_folder}"

#
# Content library + the OVA (once). govc library.ls exits 0 for a library/item that does not exist (and prints
# nothing): test its output.
#
if ! govc library.ls 2> /dev/null | grep -qx "/${k8s_content_library_name}"; then
  govc library.create -ds "${datastore_name}" "${k8s_content_library_name}" > /dev/null || k8s_fail "unable to create content library ${k8s_content_library_name}"
  log_only "content library ${k8s_content_library_name} created"
fi
if ! govc library.ls "/${k8s_content_library_name}/*" 2> /dev/null | grep -qx "/${k8s_content_library_name}/${library_item}"; then
  log_notify "Importing ${k8s_ova_filename} into content library ${k8s_content_library_name} (takes a few minutes)"
  govc library.import -n "${library_item}" "${k8s_content_library_name}" "${ova_file}" > /dev/null || k8s_fail "unable to import ${ova_file} into ${k8s_content_library_name}"
  govc library.ls "/${k8s_content_library_name}/*" 2> /dev/null | grep -qx "/${k8s_content_library_name}/${library_item}" || k8s_fail "${library_item} is not in content library ${k8s_content_library_name} after the import"
fi

#
# The VMs. Network name of the OVA's own NetworkMapping (differs between OVA builds): read from the OVA descriptor.
# cloud-init user-data per node: chpasswd.expire false (the OVA's password property otherwise expires the account at
# once and ssh then refuses the key login), the static address (netplan; cloud-init's own network config disabled so
# it does not come back), then netplan apply.
#
ova_network_name=$(govc import.spec "${ova_file}" 2> /dev/null | jq -r '.NetworkMapping[0].Name // empty')
[ -n "${ova_network_name}" ] || ova_network_name="VM Network"
for vm_name in ${node_names}; do
  vm_path="${vm_folder}/${vm_name}"
  if ! govc vm.info "${vm_path}" 2> /dev/null | grep -q "Name:"; then
    if ping -c1 -W2 "${node_ips[${vm_name}]}" > /dev/null 2>&1; then
      k8s_fail "the static address ${node_ips[${vm_name}]} planned for ${vm_name} already answers ping (k8s_static_ip_offset in variables.json)"
    fi
    user_data_b64=$(cat <<USERDATA_EOF | base64 -w0
#cloud-config
manage_etc_hosts: localhost
chpasswd:
  expire: false
write_files:
  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    content: |
      network: {config: disabled}
  - path: /etc/netplan/60-static.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          nic0:
            match:
              name: "e*"
            dhcp4: false
            addresses: [${node_ips[${vm_name}]}/${segment_prefix}]
            routes:
              - to: default
                via: ${segment_gateway}
            nameservers:
              addresses: [${ip_gw}]
runcmd:
  - rm -f /etc/netplan/50-cloud-init.yaml
  - netplan apply
USERDATA_EOF
)
    options_file="/tmp/k8s-options-${vm_name}.json"
    jq -n --arg vm "${vm_name}" --arg key "${ssh_public_key}" --arg pw "${generic_password}" --arg ud "${user_data_b64}" \
          --arg net "${k8s_segment}" --arg onet "${ova_network_name}" \
      '{DiskProvisioning: "thin", IPAllocationPolicy: "dhcpPolicy", IPProtocol: "IPv4",
        PropertyMapping: [{Key: "instance-id", Value: $vm}, {Key: "hostname", Value: $vm}, {Key: "seedfrom", Value: ""},
                          {Key: "public-keys", Value: ($key + "\n")}, {Key: "user-data", Value: $ud}, {Key: "password", Value: $pw}],
        NetworkMapping: [{Name: $onet, Network: $net}],
        MarkAsTemplate: false, PowerOn: false, InjectOvfEnv: false, WaitForIP: false, Name: $vm}' > "${options_file}"
    deploy_error=$(govc library.deploy -options "${options_file}" -folder "${vm_folder}" -pool "${resource_pool}" -ds "${datastore_name}" \
                     "/${k8s_content_library_name}/${library_item}" "${vm_name}" 2>&1) || { rm -f "${options_file}"; k8s_fail "deploying VM ${vm_name} failed: ${deploy_error}"; }
    rm -f "${options_file}"
    govc vm.change -vm "${vm_path}" -c "${k8s_node_cpu}" -m "${k8s_node_memory_mb}" || k8s_fail "resizing CPU/memory of ${vm_name} failed"
    govc vm.disk.change -vm "${vm_path}" -size "${k8s_node_disk_gb}G" || k8s_fail "resizing the disk of ${vm_name} failed"
    log_only "VM ${vm_name} created (${node_ips[${vm_name}]})"
  else
    log_only "VM ${vm_name} already exists (${node_ips[${vm_name}]})"
  fi
  if ! govc vm.info "${vm_path}" | grep -q "Power state:.*poweredOn"; then
    govc vm.power -on "${vm_path}" > /dev/null || k8s_fail "powering on ${vm_name} failed"
  fi
done

#
# Nodes: wait for SSH (on the static address: it only answers once cloud-init has applied the netplan) + cloud-init,
# then the prerequisites. The prep script takes the Kubernetes version as $1.
#
cat > "${k8s_dir}/node-prep.sh" <<'NODE_PREP_EOF'
#!/bin/bash
# Run as root on each node: kernel prerequisites, containerd (systemd cgroups), kubeadm/kubelet/kubectl $1 (e.g. v1.37.1)
set -e
export DEBIAN_FRONTEND=noninteractive
k8s_version="$1"
k8s_minor="$(echo "${k8s_version}" | cut -d. -f1-2)"
retry() { local n=1; until "$@"; do [ "${n}" -ge 8 ] && return 1; n=$((n + 1)); sleep 15; done; }
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-k8s.conf
sysctl --system > /dev/null
retry apt-get update -y
retry apt-get install -y apt-transport-https ca-certificates curl gpg containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd > /dev/null 2>&1
mkdir -p /etc/apt/keyrings
retry curl -fsSL "https://pkgs.k8s.io/core:/stable:/${k8s_minor}/deb/Release.key" -o /tmp/k8s-release.key
gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/k8s-release.key
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${k8s_minor}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
retry apt-get update -y
pkg_version="$(apt-cache madison kubeadm | awk -v v="${k8s_version#v}" '$3 ~ "^" v "-" {print $3; exit}')"
[ -n "${pkg_version}" ] || { echo "no kubeadm package for ${k8s_version} in channel ${k8s_minor}" >&2; exit 1; }
retry apt-get install -y "kubelet=${pkg_version}" "kubeadm=${pkg_version}" "kubectl=${pkg_version}"
apt-mark hold kubelet kubeadm kubectl > /dev/null
systemctl enable kubelet > /dev/null 2>&1
echo "node prepared: kubeadm $(kubeadm version -o short)"
NODE_PREP_EOF
for vm_name in ${node_names}; do
  ip="${node_ips[${vm_name}]}"
  retry_ssh=60 ; attempt_ssh=1
  until node_ssh "${ip}" "sudo cloud-init status --wait > /dev/null 2>&1; true" > /dev/null 2>&1; do
    [ ${attempt_ssh} -ge ${retry_ssh} ] && k8s_fail "${vm_name} (${ip}) not reachable over SSH (static IP/netplan or key not applied?)"
    ((attempt_ssh++))
    sleep 10
  done
  if node_ssh "${ip}" "command -v kubeadm > /dev/null && [ -f /etc/containerd/config.toml ] && grep -q 'SystemdCgroup = true' /etc/containerd/config.toml" > /dev/null 2>&1; then
    log_only "${vm_name} already prepared"
  else
    log_only "preparing ${vm_name} (${ip}): containerd + kubeadm ${k8s_version}"
    node_ssh "${ip}" "sudo bash -s -- ${k8s_version}" < "${k8s_dir}/node-prep.sh" > "${k8s_dir}/prep-${vm_name}.log" 2>&1 || k8s_fail "preparing ${vm_name} failed (log: ${k8s_dir}/prep-${vm_name}.log)"
  fi
done

#
# Control plane
#
cp_name="${k8s_cluster_name}-cp1"
cp_ip="${node_ips[${cp_name}]}"
if node_ssh "${cp_ip}" "sudo test -f /etc/kubernetes/admin.conf" > /dev/null 2>&1; then
  log_only "${cp_name} already initialised"
else
  log_notify "kubeadm init on ${cp_name} (${cp_ip}), Kubernetes ${k8s_version}, pods ${k8s_pod_cidr}, services ${k8s_service_cidr}"
  node_ssh "${cp_ip}" "sudo kubeadm init --kubernetes-version ${k8s_version} --pod-network-cidr ${k8s_pod_cidr} --service-cidr ${k8s_service_cidr} --node-name ${cp_name} --apiserver-advertise-address ${cp_ip}" \
    > "${k8s_dir}/kubeadm-init.log" 2>&1 || k8s_fail "kubeadm init failed (log: ${k8s_dir}/kubeadm-init.log)"
fi
node_ssh "${cp_ip}" "sudo cat /etc/kubernetes/admin.conf" > "${kubeconfig}.new" 2> /dev/null && [ -s "${kubeconfig}.new" ] || k8s_fail "unable to read the kubeconfig from ${cp_name}"
chmod 600 "${kubeconfig}.new"
mv "${kubeconfig}.new" "${kubeconfig}"
retry_api=30 ; attempt_api=1
until kc get nodes > /dev/null 2>&1; do
  [ ${attempt_api} -ge ${retry_api} ] && k8s_fail "the API server of ${cp_name} (${cp_ip}:6443) does not answer from gw"
  ((attempt_api++))
  sleep 10
done

#
# Antrea (before the workers: nodes only turn Ready once the CNI runs), NodePortLocal enabled
#
if ! kc get daemonset antrea-agent -n kube-system > /dev/null 2>&1; then
  log_notify "Installing Antrea ${k8s_antrea_version} (NodePortLocal on, pod CIDR ${k8s_pod_cidr})"
  curl -fsSL -o "${k8s_dir}/antrea.yml" "https://github.com/antrea-io/antrea/releases/download/${k8s_antrea_version}/antrea.yml" || k8s_fail "download of Antrea ${k8s_antrea_version} failed"
  python3 - "${k8s_dir}/antrea.yml" <<'ANTREA_EDIT_EOF' || k8s_fail "enabling NodePortLocal in Antrea's manifest failed (manifest layout changed?)"
import sys
path = sys.argv[1]
text = open(path).read()
start = text.index("    nodePortLocal:")                      # antrea-agent.conf in the antrea-config ConfigMap
off = "      enable: false"
pos = text.index(off, start)
open(path, "w").write(text[:pos] + "      enable: true" + text[pos + len(off):])
ANTREA_EDIT_EOF
  kc apply -f "${k8s_dir}/antrea.yml" > "${k8s_dir}/antrea-install.log" 2>&1 || k8s_fail "applying Antrea failed (log: ${k8s_dir}/antrea-install.log)"
fi

#
# Workers: a fresh join command (tokens expire after 24h), only for nodes not yet in the cluster
#
join_command=""
for vm_name in ${node_names}; do
  [ "${vm_name}" = "${cp_name}" ] && continue
  if kc get node "${vm_name}" > /dev/null 2>&1; then
    log_only "${vm_name} already joined"
    continue
  fi
  if [ -z "${join_command}" ]; then
    join_command=$(node_ssh "${cp_ip}" "sudo kubeadm token create --print-join-command" 2> /dev/null)
    [ -n "${join_command}" ] || k8s_fail "unable to create a join command on ${cp_name}"
  fi
  log_notify "Joining ${vm_name} (${node_ips[${vm_name}]}) to ${k8s_cluster_name}"
  node_ssh "${node_ips[${vm_name}]}" "sudo ${join_command} --node-name ${vm_name}" > "${k8s_dir}/join-${vm_name}.log" 2>&1 \
    || k8s_fail "joining ${vm_name} failed (log: ${k8s_dir}/join-${vm_name}.log)"
done
retry_ready=90 ; attempt_ready=1
while true; do
  ready_nodes=$(kc get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)
  [ "${ready_nodes}" -ge "${total_nodes}" ] && break
  [ ${attempt_ready} -ge ${retry_ready} ] && k8s_fail "only ${ready_nodes}/${total_nodes} nodes Ready after $((retry_ready * 10)) seconds (kubectl --kubeconfig ${kubeconfig} get nodes)"
  ((attempt_ready++))
  sleep 10
done

#
# Gateway API CRDs (upstream, standard channel). Required before AKO: with GatewayAPI on, its chart renders a
# GatewayClass of gateway.networking.k8s.io, and HTTPRoute is in that group too. Server-side apply: the CRDs are big.
#
if ! kc get crd gateways.gateway.networking.k8s.io > /dev/null 2>&1; then
  log_notify "Installing the Gateway API CRDs ${k8s_gateway_api_version}"
  kc apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${k8s_gateway_api_version}/standard-install.yaml" \
    > "${k8s_dir}/gateway-api-install.log" 2>&1 || k8s_fail "installing the Gateway API CRDs failed (log: ${k8s_dir}/gateway-api-install.log)"
fi

#
# AKO. Avi side from this deployment: the NSX cloud's name (looked up), controller address, API version, SE group,
# the tier-1 of the segment and the VIP network. serviceType NodePortLocal + disableStaticRouteSync go with Antrea.
# Values as a JSON file (helm reads JSON): no templating of the password. avi_login/avi_api exit the script on
# error, hence the subshell.
#
ip_avi=$(echo "${ips_avi}" | jq -r '.[0]')
cloud_name=$( (avi_login; avi_api 2 2 GET "" api/cloud; echo "${response_body}") 2> /dev/null | jq -r '[.results[]? | select(.vtype == "CLOUD_NSXT") | .name][0] // empty' 2> /dev/null)
[ -n "${cloud_name}" ] || k8s_fail "unable to find the NSX cloud on the Avi controller ${ip_avi}"
ako_values_file="${k8s_dir}/ako-values.json"
( umask 077
  jq -n --arg cluster "${k8s_cluster_name}" --arg t1 "/infra/tier-1s/${segment_tier1}" --arg vipnet "${vip_segment}" \
        --arg seg "${k8s_ako_se_group}" --arg ver "${avi_version}" --arg cloud "${cloud_name}" --arg ctrl "${ip_avi}" \
        --arg shard "${k8s_ako_shard_vs_size}" --arg pw "${generic_password}" \
    '{featureGates: {GatewayAPI: true, EnablePrometheus: false},
      replicaCount: 1,
      image: {repository: "projects.packages.broadcom.com/ako/ako", pullPolicy: "IfNotPresent"},
      GatewayAPI: {image: {repository: "projects.packages.broadcom.com/ako/ako-gateway-api", pullPolicy: "IfNotPresent"}},
      AKOSettings: {primaryInstance: true, logLevel: "WARN", clusterName: $cluster, cniPlugin: "antrea", disableStaticRouteSync: true,
                    enableEVH: true, layer7Only: false, vpcMode: false},
      NetworkSettings: {nsxtT1LR: $t1, vipNetworkList: [{networkName: $vipnet}]},
      L7Settings: {defaultIngController: "true", serviceType: "NodePortLocal", shardVSSize: $shard},
      ControllerSettings: {serviceEngineGroupName: $seg, controllerVersion: $ver, cloudName: $cloud, controllerHost: $ctrl, tenantName: "admin", vrfName: ""},
      avicredentials: {username: "admin", password: $pw},
      "ako-crd-operator": {enabled: true, controllerManager: {container: {image: {repository: "projects.packages.broadcom.com/ako/ako-crd-operator"}}}}}' > "${ako_values_file}" )
if ! helm_k status ako -n "${k8s_ako_namespace}" > /dev/null 2>&1; then
  log_notify "Installing AKO ${k8s_ako_version} in ${k8s_ako_namespace} (cloud ${cloud_name}, controller ${ip_avi}, VIP network ${vip_segment}, NodePortLocal)"
  helm_k install ako "${k8s_ako_helm_url}" --version "${k8s_ako_version}" -f "${ako_values_file}" \
    --namespace "${k8s_ako_namespace}" --create-namespace --wait --timeout 10m > "${k8s_dir}/ako-install.log" 2>&1 \
    || { rm -f "${ako_values_file}"; k8s_fail "helm install of AKO ${k8s_ako_version} failed (log: ${k8s_dir}/ako-install.log)"; }
fi
rm -f "${ako_values_file}"
# helm --wait does not notice a crash-looping AKO (the statefulset has two containers): check the pod itself
if ! kc -n "${k8s_ako_namespace}" wait --for=condition=Ready pod/ako-0 --timeout=300s > /dev/null 2>&1; then
  ako_last_error=$(kc -n "${k8s_ako_namespace}" logs ako-0 -c ako --tail=30 2>&1 | grep -i "fatal\|error" | tail -1 | cut -c1-300)
  k8s_fail "AKO ${k8s_ako_version} is installed but pod ako-0 is not Ready (${ako_last_error:-no error in its log}; kubectl --kubeconfig ${kubeconfig} -n ${k8s_ako_namespace} logs ako-0)"
fi

log_notify "Kubernetes ${k8s_version} cluster ${k8s_cluster_name} ready: ${ready_nodes} nodes ($(for vm_name in ${node_names}; do printf '%s=%s ' "${vm_name}" "${node_ips[${vm_name}]}"; done)), CNI Antrea ${k8s_antrea_version} (NodePortLocal), Gateway API ${k8s_gateway_api_version}, AKO ${k8s_ako_version} (GatewayClass avi-lb), kubeconfig ${kubeconfig}"
