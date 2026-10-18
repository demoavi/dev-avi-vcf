#!/bin/bash
#
# LAST phase: the Supervisor side of the blueprint dropdown feature (see gw-blueprint-api.sh, which runs much earlier and
# provides the receiver, its HMAC secret and its certificate). Switch and names: spec.sddc.blueprint_apps in the CR ->
# blueprint_apps_*; the rest (watcher namespace, image, timings) is variables.json's "blueprint_apps" block.
#
# It runs last because it needs everything before it: the Supervisor, the org namespaces and their labels
# (vcfa_tenant_bootstrap.sh), and the blueprints, which are uploaded by then - so the watcher's very first post already
# finds them and the dropdown is filled at once. The blueprint rewrite itself is not a step of this script: it is what
# gw-blueprint-api does, at runtime, on every post.
#
# What it builds, in this order:
#   1. A provider-only vSphere namespace (blueprint_apps_watcher_namespace, "vm-watcher"), created through the vCenter API
#      - not through VCF-A, so no org owns it, nobody has access to it and it carries no org labels (the watcher ignores
#      unlabelled namespaces).
#   2. In it: a ServiceAccount, a Secret with the receiver's HMAC secret, a ConfigMap with the receiver's certificate (the
#      watcher verifies it) and a ConfigMap with the watcher's code (supervisor-blueprint-watcher.py, stdlib only, so
#      the image is a plain python one).
#   3. The targets: every namespace carrying the VCF-A labels vmware-system-vcf/organization-id and .../project-id (the
#      org namespaces, however they were created) gets a Role + RoleBinding letting the ServiceAccount list and watch
#      VirtualMachines there, and is listed with its org and project in the ConfigMap blueprint-watcher-targets. Only
#      NAMESPACED RBAC is used: the Supervisor login of this deployment cannot create ClusterRoles. (A Supervisor Service
#      could carry a cluster-wide role; not done here.) The labels are a hint: gw-blueprint-api re-validates every
#      project with VCF-A before it touches a blueprint.
#   4. The Deployment (the pod restarts by itself when the code, the secret or the certificate change; the targets are
#      re-read by the pod every 10 s, so a new org only needs this script to be run again).
#   5. A check that the watcher posted a state (HTTP 2xx), and a warning - asked of VCF-A directly, so it also works on a
#      rerun - for every target namespace whose project has no blueprint named blueprint_apps_blueprint_name (a wrong
#      name in the CR otherwise fails quietly).
#
# Idempotent. NON-FATAL like the other optional phases: every problem is a log_notify ERROR and exit 0.
# The image comes from Docker Hub unless variables.json's blueprint_apps.image points to a registry the Supervisor can
# pull from (e.g. a Harbor path, after preloading the image there).
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

if [ "${blueprint_apps_enabled}" != "true" ]; then
  log_only "sddc.blueprint_apps.enabled is not true, skipping supervisor-blueprint-watcher"
  exit 0
fi
vcd_login
log_notify "supervisor-blueprint-watcher.sh started"

bw_fail() {
  log_notify "ERROR: supervisor-blueprint-watcher: $1 - the blueprint dropdown will not follow the VM labels, continuing"
  exit 0
}

for tool in kubectl jq curl sha256sum; do
  command -v "${tool}" > /dev/null 2>&1 || bw_fail "${tool} is not installed on gw"
done

api_conf="/etc/gw-blueprint-api"
sudo test -s "${api_conf}/config.json" && sudo test -s "${api_conf}/secret" && sudo test -s "${api_conf}/cert.pem" \
  || bw_fail "gw-blueprint-api is not installed (no ${api_conf}/config.json, secret or cert.pem): its phase must run first"
receiver_bind=$(sudo jq -r '.bind' "${api_conf}/config.json")
receiver_port=$(sudo jq -r '.port' "${api_conf}/config.json")
receiver_url="https://${receiver_bind}:${receiver_port}/apps/state"
ns="${blueprint_apps_watcher_namespace}"
name="blueprint-watcher"

work=$(mktemp -d)
chmod 700 "${work}"
trap 'rm -rf "${work}"' EXIT

#
# Supervisor access: the same helper vcfa_tenant_bootstrap.sh uses (switches the kubectl context sup-admin-01 to the
# Supervisor itself, so a stale context left by other kubectl usage cannot send this to the wrong cluster).
#
[ -f /home/ubuntu/supervisor/auth_supervisor_custer.sh ] || bw_fail "/home/ubuntu/supervisor/auth_supervisor_custer.sh does not exist (supervisor-bootstrap.sh did not complete)"
bash /home/ubuntu/supervisor/auth_supervisor_custer.sh > /dev/null 2>&1
kc() { kubectl --context sup-admin-01 "$@"; }
kc get namespace kube-system > /dev/null 2>&1 || bw_fail "cannot reach the Supervisor with the kubectl context sup-admin-01"

#
# 1. The provider-only vSphere namespace.
#
vc_host="https://${basename_sddc}-vc01.${domain}"
vc_user="administrator@$(jq -c -r .sddc.vcenter.ssoDomain "${jsonFile}")"
vc_session=$(curl -sk -m 20 -X POST "${vc_host}/api/session" -u "${vc_user}:${generic_password}" | tr -d '"')
[ -n "${vc_session}" ] || bw_fail "vCenter login failed (${vc_host})"
vc() { curl -sk -m 30 -H "vmware-api-session-id: ${vc_session}" -H 'Content-Type: application/json' "$@"; }

if [ "$(vc -o /dev/null -w '%{http_code}' "${vc_host}/api/vcenter/namespaces/instances/v2/${ns}")" != "200" ]; then
  supervisor_id=$(vc "${vc_host}/api/vcenter/namespace-management/supervisors/summaries" | jq -r '.items[0].supervisor // empty')
  [ -n "${supervisor_id}" ] || bw_fail "no Supervisor found in vCenter"
  policy_id=$(vc "${vc_host}/api/vcenter/storage/policies" | jq -r --arg p "${supervisor_cluster_storage_policy_ref}" '.[] | select(.name == $p) | .policy' | head -1)
  [ -n "${policy_id}" ] || bw_fail "storage policy '${supervisor_cluster_storage_policy_ref}' not found in vCenter"
  ns_json=$(jq -n --arg ns "${ns}" --arg sup "${supervisor_id}" --arg pol "${policy_id}" \
    '{namespace: $ns, supervisor: $sup, description: "provider-only: watches the VM labels for the blueprint dropdown (not an org namespace)",
      storage_specs: [{policy: $pol, limit: 10240}], resource_spec: {cpu_limit: 4000, memory_limit: 4096}}')
  create_code=$(vc -o "${work}/ns.out" -w '%{http_code}' -X POST -d "${ns_json}" "${vc_host}/api/vcenter/namespaces/instances/v2")
  [[ "${create_code}" == 2* ]] || bw_fail "creating the vSphere namespace ${ns} failed (HTTP ${create_code}: $(head -c 300 "${work}/ns.out"))"
  log_notify "supervisor-blueprint-watcher: vSphere namespace ${ns} created (provider-only)"
fi
ns_phase=""
for attempt in $(seq 1 30); do
  ns_phase=$(kc get namespace "${ns}" -o jsonpath='{.status.phase}' 2> /dev/null)
  [ "${ns_phase}" == "Active" ] && break
  sleep 5
done
[ "${ns_phase}" == "Active" ] || bw_fail "namespace ${ns} is not Active on the Supervisor"

#
# 2. ServiceAccount, Secret, ConfigMaps.
#
kc -n "${ns}" create serviceaccount "${name}" --dry-run=client -o yaml | kc apply -f - > /dev/null || bw_fail "creating the ServiceAccount failed"
sudo cat "${api_conf}/secret" > "${work}/secret"
sudo cat "${api_conf}/cert.pem" > "${work}/ca.crt"
kc -n "${ns}" create secret generic "${name}-hmac" --from-file=secret="${work}/secret" --dry-run=client -o yaml | kc apply -f - > /dev/null \
  || bw_fail "creating the HMAC Secret failed"
kc -n "${ns}" create configmap "${name}-ca" --from-file=ca.crt="${work}/ca.crt" --dry-run=client -o yaml | kc apply -f - > /dev/null \
  || bw_fail "creating the CA ConfigMap failed"
kc -n "${ns}" create configmap "${name}-code" --from-file=watcher.py="${script_dir}/supervisor-blueprint-watcher.py" --dry-run=client -o yaml | kc apply -f - > /dev/null \
  || bw_fail "creating the code ConfigMap failed"
# changes in any of the three make the pod restart (pod template annotation)
checksum=$(cat "${work}/secret" "${work}/ca.crt" "${script_dir}/supervisor-blueprint-watcher.py" | sha256sum | cut -c1-32)

#
# 3. Targets: every namespace with the VCF-A org and project labels.
#
targets=$(kc get namespaces -l 'vmware-system-vcf/organization-id,vmware-system-vcf/project-id' -o json 2> /dev/null \
  | jq -c '[.items[] | select(.status.phase == "Active")
            | {namespace: .metadata.name, organization_id: .metadata.labels["vmware-system-vcf/organization-id"],
               project_id: .metadata.labels["vmware-system-vcf/project-id"]}]')
[ -n "${targets}" ] || bw_fail "cannot list the org namespaces"
target_count=$(echo "${targets}" | jq 'length')
if [ "${target_count}" -eq 0 ]; then
  log_notify "WARNING: supervisor-blueprint-watcher: no namespace carries the VCF-A org/project labels yet (no org namespace?): the watcher is installed but idle, run this phase again once an org namespace exists"
fi
for target_ns in $(echo "${targets}" | jq -r '.[].namespace'); do
  kc apply -f - > /dev/null << ROLE_EOF || bw_fail "creating the Role/RoleBinding in ${target_ns} failed"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: ${name}, namespace: ${target_ns}}
rules:
- {apiGroups: ["vmoperator.vmware.com"], resources: ["virtualmachines"], verbs: ["get", "list", "watch"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: ${name}, namespace: ${target_ns}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: ${name}}
subjects: [{kind: ServiceAccount, name: ${name}, namespace: ${ns}}]
ROLE_EOF
done
echo "${targets}" > "${work}/targets.json"
kc -n "${ns}" create configmap "${name}-targets" --from-file=targets.json="${work}/targets.json" --dry-run=client -o yaml | kc apply -f - > /dev/null \
  || bw_fail "creating the targets ConfigMap failed"

#
# 4. The Deployment.
#
kc apply -f - > /dev/null << DEPLOY_EOF || bw_fail "creating the Deployment failed"
apiVersion: apps/v1
kind: Deployment
metadata: {name: ${name}, namespace: ${ns}}
spec:
  replicas: 1
  selector: {matchLabels: {app: ${name}}}
  template:
    metadata:
      labels: {app: ${name}}
      annotations: {checksum/config: "${checksum}"}
    spec:
      serviceAccountName: ${name}
      containers:
      - name: watcher
        image: ${blueprint_apps_image}
        command: ["python3", "-u", "/app/watcher.py"]
        env:
        - {name: RECEIVER_URL, value: "${receiver_url}"}
        - {name: RECEIVER_SECRET_FILE, value: /secret/secret}
        - {name: RECEIVER_CA_FILE, value: /ca/ca.crt}
        - {name: TARGETS_FILE, value: /targets/targets.json}
        - {name: DEBOUNCE, value: "${blueprint_apps_debounce}"}
        - {name: RESYNC, value: "${blueprint_apps_resync}"}
        volumeMounts:
        - {name: code, mountPath: /app}
        - {name: secret, mountPath: /secret, readOnly: true}
        - {name: ca, mountPath: /ca, readOnly: true}
        - {name: targets, mountPath: /targets, readOnly: true}
      volumes:
      - {name: code, configMap: {name: ${name}-code}}
      - {name: secret, secret: {secretName: ${name}-hmac}}
      - {name: ca, configMap: {name: ${name}-ca}}
      - {name: targets, configMap: {name: ${name}-targets}}
DEPLOY_EOF
kc -n "${ns}" rollout status "deployment/${name}" --timeout=300s > /dev/null 2>&1 \
  || bw_fail "the ${name} Deployment in ${ns} is not ready after 300 s (kubectl --context sup-admin-01 -n ${ns} describe pod -l app=${name}; image ${blueprint_apps_image} pullable from the Supervisor?)"

#
# 5. Verification: the watcher posted (HTTP 2xx), and the receiver found the blueprint.
#
if [ "${target_count}" -eq 0 ]; then
  log_notify "supervisor-blueprint-watcher: ${name} running in ${ns}, idle (no org namespace yet), posting to ${receiver_url}"
  exit 0
fi
posted="false"
for attempt in $(seq 1 24); do
  if kc -n "${ns}" logs -l "app=${name}" --tail=200 2> /dev/null | grep -qE 'posted state .* HTTP 2[0-9][0-9]'; then
    posted="true"
    break
  fi
  sleep 5
done
[ "${posted}" == "true" ] || bw_fail "the watcher has not posted its state to ${receiver_url} after 2 minutes (kubectl --context sup-admin-01 -n ${ns} logs -l app=${name}; is ${receiver_bind}:${receiver_port} reachable from the Supervisor?)"
# The blueprint check asks VCF-A directly (not the receiver's log, which says nothing on a rerun that posts nothing new):
# for every project that has a target namespace, does a blueprint named blueprint_apps_blueprint_name exist?
vcfa_host="https://${basename_sddc}-auto-vip.${domain}"
vcfa_accept="Accept: application/json;version=9.1.0"
provider_token=$(curl -sk -m 30 -i -X POST "${vcfa_host}/cloudapi/1.0.0/sessions/provider" -H "${vcfa_accept}" \
  -H "Content-Type: application/json;version=9.1.0" \
  -H "Authorization: Basic $(printf '%s@system:%s' admin "${generic_password}" | base64 -w0)" \
  | grep -i '^x-vmware-vcloud-access-token:' | awk '{print $2}' | tr -d '\r')
client_id=""
[ -n "${provider_token}" ] && client_id=$(curl -sk -m 30 "${vcfa_host}/cloudapi/1.0.0/openIdProvider/relyingParties" -H "${vcfa_accept}" \
  -H "Authorization: Bearer ${provider_token}" | jq -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId // empty')
if [ -z "${client_id}" ]; then
  log_notify "WARNING: supervisor-blueprint-watcher: could not log in to VCF-A to check that the blueprint '${blueprint_apps_blueprint_name}' exists"
else
  missing_ns=""
  for org_id in $(echo "${targets}" | jq -r '[.[].organization_id] | unique | .[]'); do
    org_token=$(curl -sk -m 30 -X POST "${vcfa_host}/oidc/oauth2/token" -H "${vcfa_accept}" -H "x-vmware-vcloud-tenant-context: ${org_id}" \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
      --data-urlencode "scope=openid profile email phone groups vcd_idp" --data-urlencode "assertion=${provider_token}" \
      --data-urlencode "client_id=${client_id}" | jq -r '.access_token // empty')
    if [ -z "${org_token}" ]; then
      missing_ns="${missing_ns:+${missing_ns},}org ${org_id} (no token)"
      continue
    fi
    bp_projects=$(curl -sk -m 30 "${vcfa_host}/blueprint/api/blueprints" -H "Accept: application/json" -H "Authorization: Bearer ${org_token}" \
      | jq -r --arg n "${blueprint_apps_blueprint_name}" '.content[]? | select(.name == $n) | .projectId')
    for t in $(echo "${targets}" | jq -r --arg o "${org_id}" '.[] | select(.organization_id == $o) | "\(.namespace)=\(.project_id)"'); do
      echo "${bp_projects}" | grep -qx "${t#*=}" || missing_ns="${missing_ns:+${missing_ns},}${t%%=*}"
    done
  done
  if [ -n "${missing_ns}" ]; then
    log_notify "WARNING: supervisor-blueprint-watcher: no blueprint named '${blueprint_apps_blueprint_name}' for the namespace(s) ${missing_ns}: check sddc.blueprint_apps.blueprint_name in the CR (it is the file name in dev-avi-vcf/blueprints/ without .yaml.template) and that blueprints.enabled is true for that org - gw-blueprint-api drops their updates until it exists"
  fi
fi
log_notify "supervisor-blueprint-watcher: ${name} running in ${ns}, watching ${target_count} org namespace(s), posting to ${receiver_url}"
