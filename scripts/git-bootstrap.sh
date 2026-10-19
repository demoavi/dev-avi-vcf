#!/bin/bash
#
# Optional Git server (Gitea, helm) on the shared Kubernetes cluster built by k8s-bootstrap.sh - phase 2 of that
# platform. Switch: spec.sddc.git.enabled in the CR (-> git_enabled; needs sddc.k8s.enabled). Everything else is in
# variables.json's "git" block (-> git_* in variables.sh): chart version, namespace, FQDN prefix, volume size,
# admin user, repo name, TLS secret and Gateway names.
#
# What it builds:
#   - Gitea with the official chart: SQLite + in-memory cache/session (the chart's bundled postgresql-ha and
#     valkey-cluster are switched off, far too heavy for this), a PVC on the default StorageClass (local-path), no
#     SSH, no self-registration, sign-in required to view anything, every repo forced private, users and orgs private
#     by default and the explore pages for users/organizations hidden. The chart's default admin password is replaced
#     by this deployment's generic password.
#   - exposure through AKO: a Gateway (class avi-lb) and an HTTPRoute for git.<avi subdomain>.<domain>
#     (git.avi.vcf9.lab on the vApp, git.app.vcf9.lab on the SDDC): AKO builds the Avi virtual service and registers
#     the name in Avi's DNS virtual service by itself. With the ClusterIssuer from k8s-bootstrap.sh (cert-manager +
#     Vault PKI) the Gateway carries the annotation cert-manager.io/cluster-issuer, so cert-manager issues - and
#     renews - the certificate of the HTTPS listener; without it the Gateway has an HTTP listener only (warning).
#   - tenancy: one Gitea user per VCF-A org (same name and the same derived password as that org's other accounts),
#     private, owning ONE private repo <org>/<git_repo_name> (initialised, so the web UI can commit at once). No
#     shared organization, so nothing lists another org; a final check logs in as the first org and verifies it
#     cannot see the second one's repo or user.
#
# Offline-first: the chart (git_chart_file, a .tgz) and the Gitea image (git_image_file, <name>_<tag>.tar) come from the
# gw-tools ISO. supervisor-bootstrap.sh - which runs before this phase - pushes the image to Harbor
# (<harbor>/<git_harbor_project>/<name>:<tag>); the Gitea pods then pull it from there (chart value image.fullOverride),
# after the cluster's nodes were made to trust Harbor's self-signed CA (/home/ubuntu/harbor-ca.crt, saved by
# supervisor-bootstrap.sh). Anything missing falls back to the Internet with a warning: no chart file -> the chart
# repo (git_helm_repo_url), image not in Harbor / no CA / a node cannot be set up -> the upstream image.
# Test knobs (not used in a deployment): GIT_HARBOR_HOST (a registry host[:port] to use instead of Harbor's FQDN) and
# HARBOR_CA_CERT_PATH.
#
# Idempotent (existing release, users and repos are left alone; passwords of existing users are re-set to the derived
# value). NON-FATAL like k8s-bootstrap.sh: every failure is logged (log_notify ERROR) and the script exits 0.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

if [ "${git_enabled}" != "true" ]; then
  log_only "sddc.git.enabled is not true, skipping the Git server"
  exit 0
fi
vcd_login
log_notify "git-bootstrap.sh started"

git_fail() {
  log_notify "ERROR: git-bootstrap: $1 - the Git server is not (fully) built, continuing with the rest of the deployment"
  exit 0
}

[ "${k8s_enabled}" == "true" ] || git_fail "sddc.git.enabled needs sddc.k8s.enabled (the Git server runs on that cluster)"
for tool in kubectl helm jq curl openssl; do
  command -v "${tool}" > /dev/null 2>&1 || git_fail "${tool} is not installed on gw"
done

k8s_dir="${K8S_WORK_DIR:-/home/ubuntu/k8s}"
kubeconfig="${k8s_dir}/${k8s_cluster_name}.kubeconfig"
kc() { kubectl --kubeconfig "${kubeconfig}" "$@"; }
helm_k() { helm --kubeconfig "${kubeconfig}" "$@"; }
[ -s "${kubeconfig}" ] || git_fail "no kubeconfig ${kubeconfig} (did k8s-bootstrap.sh complete?)"
kc get nodes > /dev/null 2>&1 || git_fail "the Kubernetes cluster ${k8s_cluster_name} does not answer"
kc get storageclass local-path > /dev/null 2>&1 || git_fail "no default StorageClass on ${k8s_cluster_name} (k8s-bootstrap.sh installs local-path)"
kc get gatewayclass avi-lb > /dev/null 2>&1 || git_fail "no GatewayClass avi-lb on ${k8s_cluster_name} (AKO not installed?)"

git_fqdn="${git_fqdn_prefix}.${avi_subdomain}.${domain}"
tls_enabled="false"
kc get clusterissuer "${k8s_cluster_issuer}" > /dev/null 2>&1 && tls_enabled="true"
[ "${tls_enabled}" == "true" ] || log_notify "WARNING: git-bootstrap: no ClusterIssuer ${k8s_cluster_issuer} (Vault not available when the cluster was built): ${git_fqdn} will be HTTP only"
git_scheme="https"; [ "${tls_enabled}" == "true" ] || git_scheme="http"

#
# Where the Gitea image comes from: Harbor if it has it, else upstream. <name>_<tag>.tar -> <name>:<tag>.
#
image_base="$(basename "${git_image_file}" .tar.gz)"; image_base="$(basename "${image_base}" .tar)"
image_name="${image_base%%_*}"; image_tag="${image_base#*_}"
harbor_host="${GIT_HARBOR_HOST:-harbor.${avi_subdomain}.${domain}}"
harbor_ca_file="${HARBOR_CA_CERT_PATH:-/home/ubuntu/harbor-ca.crt}"
harbor_image=""
harbor_why=""
if [ "${image_name}" == "${image_base}" ]; then
  harbor_why="git_image_file ${git_image_file} does not follow <name>_<tag>.tar"
elif [ ! -s "${harbor_ca_file}" ]; then
  harbor_why="no Harbor CA at ${harbor_ca_file} (Harbor not deployed on this gw?)"
else
  # Harbor answers 401 to a plain manifest request even for a public project: a registry client first gets an anonymous
  # token from the token service and sends it as a Bearer. No token endpoint (a plain registry): no header, as before.
  harbor_token=$(curl -s -m 15 --cacert "${harbor_ca_file}" "https://${harbor_host}/service/token?service=harbor-registry&scope=repository:${git_harbor_project}/${image_name}:pull" 2> /dev/null | jq -r '.token // empty' 2> /dev/null)
  harbor_code=$(curl -s -m 15 --cacert "${harbor_ca_file}" -o /dev/null -w '%{http_code}' ${harbor_token:+-H "Authorization: Bearer ${harbor_token}"} \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json' \
    "https://${harbor_host}/v2/${git_harbor_project}/${image_name}/manifests/${image_tag}")
  if [ "${harbor_code}" == "200" ]; then
    harbor_image="${harbor_host}/${git_harbor_project}/${image_name}:${image_tag}"
  else
    harbor_why="${harbor_host}/${git_harbor_project}/${image_name}:${image_tag} is not there (HTTP ${harbor_code})"
  fi
fi

# The nodes' containerd verifies Harbor's certificate against the system store: add Harbor's CA to every node (a no-op
# when it is already there) and restart containerd (running pods are not affected).
ssh_key="${k8s_dir}/id_ed25519"
node_ssh() { local ip=$1; shift; ssh -i "${ssh_key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=8 -o LogLevel=ERROR "${k8s_ssh_user}@${ip}" "$@"; }
if [ -n "${harbor_image}" ]; then
  for node_ip in $(kc get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'); do
    if node_ssh "${node_ip}" "sudo cmp -s /usr/local/share/ca-certificates/harbor-ca.crt -" < "${harbor_ca_file}" > /dev/null 2>&1; then
      continue
    fi
    if ! node_ssh "${node_ip}" "sudo tee /usr/local/share/ca-certificates/harbor-ca.crt > /dev/null && sudo update-ca-certificates > /dev/null 2>&1 && sudo systemctl restart containerd" < "${harbor_ca_file}" > /dev/null 2>&1; then
      harbor_why="could not make node ${node_ip} trust Harbor's CA"
      harbor_image=""
      break
    fi
    log_only "node ${node_ip} now trusts Harbor's CA"
  done
fi
if [ -n "${harbor_image}" ]; then
  log_notify "Gitea image from Harbor: ${harbor_image}"
else
  log_notify "WARNING: git-bootstrap: Gitea image NOT from Harbor (${harbor_why}), the nodes will pull docker.gitea.com/gitea from the Internet"
fi

#
# Gitea (helm). Values as a JSON file (helm reads JSON), root-only: it holds the admin password.
#
kc get namespace "${git_namespace}" > /dev/null 2>&1 || kc create namespace "${git_namespace}" > /dev/null || git_fail "unable to create namespace ${git_namespace}"
values_file="${k8s_dir}/gitea-values.json"
( umask 077
  jq -n --arg fqdn "${git_fqdn}" --arg root "${git_scheme}://${git_fqdn}/" --arg size "${git_pvc_size}" \
        --arg admin "${git_admin_user}" --arg pw "${generic_password}" --arg email "gitea@${domain}" --arg himg "${harbor_image}" \
    '{image: ({rootless: true} + (if $himg != "" then {fullOverride: $himg} else {} end)),
      persistence: {enabled: true, size: $size},
      "postgresql-ha": {enabled: false}, postgresql: {enabled: false}, "valkey-cluster": {enabled: false}, valkey: {enabled: false},
      gitea: {
        admin: {username: $admin, password: $pw, email: $email, passwordMode: "keepUpdated"},
        config: {
          server: {DOMAIN: $fqdn, ROOT_URL: $root, SSH_DOMAIN: $fqdn, DISABLE_SSH: true, START_SSH_SERVER: false},
          database: {DB_TYPE: "sqlite3"},
          session: {PROVIDER: "memory"},
          cache: {ADAPTER: "memory"},
          queue: {TYPE: "level"},
          service: {DISABLE_REGISTRATION: true, REQUIRE_SIGNIN_VIEW: true, DEFAULT_USER_VISIBILITY: "private", DEFAULT_ORG_VISIBILITY: "private"},
          "service.explore": {REQUIRE_SIGNIN_VIEW: true, DISABLE_USERS_PAGE: true, DISABLE_ORGANIZATIONS_PAGE: true},
          repository: {DEFAULT_PRIVATE: "private", FORCE_PRIVATE: true, DEFAULT_BRANCH: "main"}}}}' > "${values_file}" )
chart_file="/home/ubuntu/${git_chart_file}"
if [ -s "${chart_file}" ]; then
  chart_args=("${chart_file}")
  chart_source="${git_chart_file} from the gw-tools ISO"
else
  chart_args=(gitea --repo "${git_helm_repo_url}" --version "${git_chart_version}")
  chart_source="${git_helm_repo_url} (no ${chart_file}: the Internet)"
  log_notify "WARNING: git-bootstrap: ${chart_file} not found (was it added to the gw-tools Iso CR?), fetching the chart from ${git_helm_repo_url}"
fi
if ! helm_k status gitea -n "${git_namespace}" > /dev/null 2>&1; then
  log_notify "Installing Gitea (chart ${chart_source}) in ${git_namespace}, ${git_pvc_size} on local-path, ${git_scheme}://${git_fqdn}"
  helm_k install gitea "${chart_args[@]}" -f "${values_file}" \
    --namespace "${git_namespace}" --wait --timeout 15m > "${k8s_dir}/gitea-install.log" 2>&1 \
    || { rm -f "${values_file}"; git_fail "helm install of Gitea failed (log: ${k8s_dir}/gitea-install.log)"; }
fi
rm -f "${values_file}"
kc -n "${git_namespace}" rollout status deployment/gitea --timeout=300s > /dev/null 2>&1 || git_fail "the Gitea deployment is not ready (kubectl --kubeconfig ${kubeconfig} -n ${git_namespace} get pods)"

#
# Exposure: Gateway + HTTPRoute through AKO. The cert-manager annotation on the Gateway makes cert-manager issue the
# Secret named in the HTTPS listener's certificateRefs; AKO uses it once it exists.
#
if [ "${tls_enabled}" == "true" ]; then
  gateway_annotations="  annotations:
    cert-manager.io/cluster-issuer: ${k8s_cluster_issuer}"
  https_listener="    - name: https
      protocol: HTTPS
      port: 443
      hostname: ${git_fqdn}
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: \"\"
            name: ${git_tls_secret}"
else
  gateway_annotations=""
  https_listener=""
fi
kc apply -f - > "${k8s_dir}/gitea-gateway.log" 2>&1 <<GATEWAY_EOF || git_fail "creating the Gateway/HTTPRoute failed (log: ${k8s_dir}/gitea-gateway.log)"
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: ${git_gateway_name}
  namespace: ${git_namespace}
${gateway_annotations}
spec:
  gatewayClassName: avi-lb
  listeners:
${https_listener}
    - name: http
      protocol: HTTP
      port: 80
      hostname: ${git_fqdn}
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: gitea
  namespace: ${git_namespace}
spec:
  parentRefs:
    - name: ${git_gateway_name}
  hostnames:
    - ${git_fqdn}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: gitea-http
          port: 3000
GATEWAY_EOF
git_vip=""
for attempt in $(seq 1 60); do
  git_vip=$(kc -n "${git_namespace}" get gateway "${git_gateway_name}" -o jsonpath='{.status.addresses[0].value}' 2> /dev/null)
  [ -n "${git_vip}" ] && break
  sleep 10
done
[ -n "${git_vip}" ] || git_fail "the Gateway ${git_gateway_name} got no address from AKO/Avi (kubectl --kubeconfig ${kubeconfig} -n ${git_namespace} describe gateway ${git_gateway_name})"
if [ "${tls_enabled}" == "true" ]; then
  kc -n "${git_namespace}" wait --for=condition=Ready "certificate/${git_tls_secret}" --timeout=300s > /dev/null 2>&1 \
    || git_fail "the certificate ${git_tls_secret} is not Ready (kubectl --kubeconfig ${kubeconfig} -n ${git_namespace} describe certificate ${git_tls_secret})"
  # AKO checks the HTTPS listener's Secret when it first sees the Gateway - a moment before cert-manager has issued it
  # ("Secret specified in CertificateRef does not exist") - and does not look again when the Secret appears: the
  # HTTPS listener then answers 404 until the Gateway changes. An annotation change is such a change (live-tested).
  kc -n "${git_namespace}" annotate gateway "${git_gateway_name}" "ako-retrigger=$(date +%s)" --overwrite > /dev/null 2>&1 \
    || git_fail "unable to re-trigger AKO on the Gateway ${git_gateway_name}"
fi

# Gitea answers through the Avi VIP (-k: the chain is checked separately below)
gitea_curl() { curl -sk -m 20 --resolve "${git_fqdn}:443:${git_vip}" --resolve "${git_fqdn}:80:${git_vip}" "$@"; }
git_ready="false"
for attempt in $(seq 1 60); do
  if [ "$(gitea_curl -o /dev/null -w '%{http_code}' "${git_scheme}://${git_fqdn}/api/healthz")" == "200" ]; then git_ready="true"; break; fi
  sleep 10
done
[ "${git_ready}" == "true" ] || git_fail "Gitea does not answer on ${git_scheme}://${git_fqdn} (VIP ${git_vip})"
log_notify "Gitea answers on ${git_scheme}://${git_fqdn} (VIP ${git_vip})"

# Does the chain verify against the Vault root, and does the server send the intermediate with the leaf?
if [ "${tls_enabled}" == "true" ]; then
  root_ca_file="$(mktemp)"
  curl -sk -m 10 "https://127.0.0.1:8200/v1/pki/ca/pem" -o "${root_ca_file}"
  if [ -s "${root_ca_file}" ] && [ "$(curl -s -m 20 --cacert "${root_ca_file}" --resolve "${git_fqdn}:443:${git_vip}" -o /dev/null -w '%{http_code}' "https://${git_fqdn}/api/healthz")" == "200" ]; then
    sent=$(echo | openssl s_client -connect "${git_vip}:443" -servername "${git_fqdn}" -showcerts 2> /dev/null | grep -c "BEGIN CERTIFICATE")
    log_notify "Gitea's certificate verifies against the Vault root CA; the server sends ${sent} certificate(s) (leaf + intermediate, plus the root when 3: importing the root CA in a browser is enough)"
  else
    log_notify "WARNING: git-bootstrap: the certificate of ${git_fqdn} does not verify against the Vault root CA (https://<gw>:8200/v1/pki/ca/pem)"
  fi
  rm -f "${root_ca_file}"
fi

#
# Tenancy: one private user per VCF-A org, owning one private repo. The admin's credentials go in a root-only curl
# config (not on the command line), data on stdin. org_password is derived exactly as everywhere else in this project.
#
curl_config="$(mktemp)"
trap 'rm -f "${curl_config}"' EXIT
( umask 077; printf 'user = "%s:%s"\n' "${git_admin_user}" "${generic_password}" > "${curl_config}" )
gitea_admin_api() { # method path [json on stdin]
  local method=$1 path=$2
  gitea_curl -K "${curl_config}" -X "${method}" -H "Content-Type: application/json" -H "Accept: application/json" \
    -o "${k8s_dir}/.gitea-answer" -w '%{http_code}' "${git_scheme}://${git_fqdn}/api/v1/${path}" -d @-
}
org_count=0
org_names=()
while read -r org_name; do
  [ -n "${org_name}" ] || continue
  org_password="VMware1!$(echo -n "${gw_accounts_secret}${org_name}" | sha256sum | cut -c1-4)VMware1!"
  org_count=$((org_count + 1)); org_names+=("${org_name}")
  code=$(echo '{}' | gitea_admin_api GET "users/${org_name}")
  if [ "${code}" == "200" ]; then
    code=$(jq -n --arg pw "${org_password}" --arg u "${org_name}" '{login_name: $u, source_id: 0, password: $pw, must_change_password: false, visibility: "private"}' | gitea_admin_api PATCH "admin/users/${org_name}")
    [ "${code}" == "200" ] || { log_notify "ERROR: git-bootstrap: updating the Gitea user ${org_name} failed (HTTP ${code})"; continue; }
    log_only "Gitea user ${org_name} already exists, password re-set"
  else
    code=$(jq -n --arg pw "${org_password}" --arg u "${org_name}" --arg e "${org_name}@${domain}" \
             '{username: $u, email: $e, password: $pw, must_change_password: false, send_notify: false, visibility: "private"}' | gitea_admin_api POST "admin/users")
    [ "${code}" == "201" ] || { log_notify "ERROR: git-bootstrap: creating the Gitea user ${org_name} failed (HTTP ${code}: $(jq -r '.message // empty' "${k8s_dir}/.gitea-answer" 2> /dev/null))"; continue; }
    log_only "Gitea user ${org_name} created"
  fi
  code=$(echo '{}' | gitea_admin_api GET "repos/${org_name}/${git_repo_name}")
  if [ "${code}" != "200" ]; then
    code=$(jq -n --arg r "${git_repo_name}" --arg d "Private repository of the VCF-A org ${org_name}" \
             '{name: $r, description: $d, private: true, auto_init: true, default_branch: "main", readme: "Default"}' | gitea_admin_api POST "admin/users/${org_name}/repos")
    [ "${code}" == "201" ] || { log_notify "ERROR: git-bootstrap: creating the repo ${org_name}/${git_repo_name} failed (HTTP ${code}: $(jq -r '.message // empty' "${k8s_dir}/.gitea-answer" 2> /dev/null))"; continue; }
    log_only "repo ${org_name}/${git_repo_name} created (private)"
  fi
  # Sample content: <git_sample_path>/<git_sample_configmap>.yaml, a ConfigMap the ArgoCD of the org's VKS cluster syncs
  # (vcfa_tenant_bootstrap.sh) - committed once, never overwritten (the org owns the repo from then on).
  sample_file="${git_sample_path}/${git_sample_configmap}.yaml"
  code=$(echo '{}' | gitea_admin_api GET "repos/${org_name}/${git_repo_name}/contents/${sample_file}?ref=main")
  if [ "${code}" == "404" ]; then
    sample_yaml=$(printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  from: gitea\n  org: %s\n' "${git_sample_configmap}" "${org_name}")
    code=$(jq -n --arg c "$(printf '%s\n' "${sample_yaml}" | base64 -w0)" --arg m "Sample ConfigMap synced by ArgoCD" \
             '{content: $c, message: $m, branch: "main"}' | gitea_admin_api POST "repos/${org_name}/${git_repo_name}/contents/${sample_file}")
    if [ "${code}" == "201" ]; then
      log_only "sample ${sample_file} committed to ${org_name}/${git_repo_name}"
    else
      log_notify "ERROR: git-bootstrap: committing ${sample_file} to ${org_name}/${git_repo_name} failed (HTTP ${code}: $(jq -r '.message // empty' "${k8s_dir}/.gitea-answer" 2> /dev/null))"
    fi
  fi
done < <(echo "${vcf_a_organizations}" | jq -r '.[].name')
rm -f "${k8s_dir}/.gitea-answer"

#
# Tenancy check: as the first org, the second org's repo and user must not be visible (404) and a search must not list
# it; anonymous access must be refused. Only a warning if it leaks.
#
if [ "${org_count}" -ge 2 ]; then
  first="${org_names[0]}"; second="${org_names[1]}"
  first_password="VMware1!$(echo -n "${gw_accounts_secret}${first}" | sha256sum | cut -c1-4)VMware1!"
  user_config="$(mktemp)"; ( umask 077; printf 'user = "%s:%s"\n' "${first}" "${first_password}" > "${user_config}" )
  as_first() { gitea_curl -K "${user_config}" -H "Accept: application/json" "$@"; }
  leaks=""
  [ "$(as_first -o /dev/null -w '%{http_code}' "${git_scheme}://${git_fqdn}/api/v1/repos/${second}/${git_repo_name}")" == "404" ] || leaks="${leaks} other-org-repo-readable"
  as_first "${git_scheme}://${git_fqdn}/api/v1/users/search?q=${second}" | jq -e --arg u "${second}" '[.data[]? | select(.login == $u)] | length == 0' > /dev/null 2>&1 || leaks="${leaks} other-org-listed-in-user-search"
  as_first "${git_scheme}://${git_fqdn}/api/v1/repos/search?limit=50" | jq -e --arg u "${second}" '[.data[]? | select(.owner.login == $u)] | length == 0' > /dev/null 2>&1 || leaks="${leaks} other-org-repo-in-repo-search"
  [ "$(gitea_curl -o /dev/null -w '%{http_code}' "${git_scheme}://${git_fqdn}/api/v1/repos/${first}/${git_repo_name}")" != "200" ] || leaks="${leaks} anonymous-access"
  rm -f "${user_config}"
  if [ -z "${leaks}" ]; then
    log_notify "Tenancy check OK: ${first} sees neither the repo nor the user of ${second}, and anonymous access is refused"
  else
    log_notify "WARNING: git-bootstrap: tenancy check failed:${leaks}"
  fi
fi

log_notify "Git server ready: ${git_scheme}://${git_fqdn} (Gitea chart ${git_chart_version}), ${org_count} org user(s), each with a private repo <org>/${git_repo_name}"
