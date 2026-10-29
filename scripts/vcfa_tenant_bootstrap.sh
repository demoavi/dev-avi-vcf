#!/bin/bash
#
# VCFA org-provisioning phase of the VCD/vApp use case - "org-portal" half:
# everything that needs an org-scoped OAuth token rather than the provider
# Bearer token (namespace/VKS-cluster/vault-integration/blueprint creation,
# plus per-org vCenter SSO + Avi tenant-admin accounts). Split out of the
# former single configure_vcfa.sh on 2026-09-28 alongside its sibling
# vcfa_provider_bootstrap.sh (regions/ipSpaces/providerGateways/orgs/VDCs/
# demo-yaml rendering - see that script's own header), matching the
# natural boundary this file's own comments already drew between "system/
# provider portal" and "org-portal phase" actions. Runs second of the two
# (as "vcfa_tenant_bootstrap" in vcf_bootstrap.sh's phase loop) - every
# org-scoped action below depends on vcfa_provider_bootstrap.sh's own
# provider-portal resources (region/org/VDC/content-library/demo-yaml)
# already existing.
#
# Self-contained like every other phase script: independently re-derives
# everything it needs (VCFA_HOST/headers/token, supervisor_name, the
# yaml_folder constant) rather than inheriting it from
# vcfa_provider_bootstrap.sh's own already-exited process - the two run as
# separate "bash vcfa_provider_bootstrap.sh"/"bash vcfa_tenant_bootstrap.sh"
# invocations, not sourced into each other or into vcf_bootstrap.sh's own
# shell. log_file is the one value deliberately kept identical across
# every phase script (all append to the same /home/ubuntu/vcf_bootstrap.log
# so the whole pipeline reads as one continuous timeline).
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

log_file="/home/ubuntu/vcf_bootstrap.log"
touch "${log_file}"
resultFile="/home/ubuntu/configure_vcfa.done"
slack_webhook=""
#
# Fixed constant, not a per-deployment value (see
# vcfa_provider_bootstrap.sh's own identical copy of this comment) - only
# needed here to recompute org_yaml_folder (the vault-integration step
# below reads back what that script's own demo-yaml rendering loop wrote
# into each org's home dir).
#
yaml_folder="yaml-files"

VCFA_HOST="https://${basename_sddc}-auto-vip.${domain}"
VCFA_VERSION="9.1.0"
ACCEPT="Accept: application/json;version=${VCFA_VERSION}"
CONTENT_TYPE="Content-Type: application/json;version=${VCFA_VERSION}"

vcfa_login
log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vcfa_tenant_bootstrap.sh started" "${log_file}" "${slack_webhook}" "${google_webhook}"

#
# Supervisor name only (not supervisor_id - that's only ever used
# provider-side) - needed by the per-org vCenter-account scoping block
# further below for its VM-folder path. vcfa_provider_bootstrap.sh's own
# identical lookup doesn't carry over to this separate process.
#
vcfa_api GET "cloudapi/v1/supervisors" ""
supervisor_name=$(echo ${response_body} | jq -c -r '.values[0].name')


#
# Namespace provisioning - org-portal phase, run AFTER every org above is
# fully configured from the system/provider portal. One supervisor
# namespace per eligible org (item.namespace.enabled == true), created via
# an org-scoped OAuth token rather than the provider Bearer token used
# everywhere above - VCFA has no provider-level API for this, it's
# inherently a tenant self-service action.
#
# PROVIDER_MANAGED ONLY for now: namespace creation requires a segName
# unconditionally ("SEG is required when creating namespace on region with
# NSX_REGISTERED_AVI LB type..."), confirmed live - for PROVIDER_MANAGED
# orgs that's just avi_service_engine_group_ref. TENANT_MANAGED orgs have
# no equivalent SEG yet (needs its own new SEG created via VCF-A first) -
# deliberately parked, so any org with namespace.enabled but avi_mode !=
# PROVIDER_MANAGED is skipped with a log message rather than guessed at.
#
# Auth: provider Bearer token -> org-scoped OAuth token via jwt-bearer
# exchange, matching templates/vcfa_select_ns.sh.template's documented
# flow (https://vrealize.it/2025/12/04/vcf-automation-9-programmatic-token-generation/).
# A fresh org token is requested per org (org tokens are short-lived and
# org-specific, unlike the one long-lived provider token reused above).
# KNOWN LIMITATION: unlike vcfa_api, cci_api below does not re-request the
# org token on expiry mid-poll - the poll loop (up to 12x15s=3min after
# creation) could plausibly outlast a short-lived org token on some
# systems. Not yet hit live; if the poll starts failing partway through
# with 401s, that's the fix needed.
#
# VPC and namespace name are deliberately not input fields (see the CRD's
# own comments on organization_templates.namespace) - the org's default
# VPC is deterministically named "default-${region_ref}" (confirmed live:
# org-3's is "default-region-1"), and the API requires
# metadata.generateName (never a fixed name), so idempotency here is by
# name PREFIX match ("${org_name}-ns-") rather than exact name.
#

vcfa_api GET "cloudapi/1.0.0/openIdProvider/relyingParties" ""
client_id=$(echo ${response_body} | jq -c -r '[.values[] | select(.clientName == "automation-relying-party")][0].clientId // [.values[] | select(.isPublic == true)][0].clientId')
if [ -z "${client_id}" ] || [ "${client_id}" == "null" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: could not determine the automation relying party clientId, skipping all namespace provisioning" "${log_file}" "${slack_webhook}" "${google_webhook}"
else
  #
  # Calm gate (vks_calm_gate, default true): do not start another VKS cluster while the platform is struggling. The provider
  # API of VCF Automation and the Supervisor's own API for this namespace must both answer a cheap call within
  # vks_calm_limit_sec seconds (default 3), three times in a row, for up to vks_calm_max_wait_sec seconds (default 600);
  # after that it goes on anyway (a log line says so). Any HTTP answer counts as responsive (a 401 is still an answer).
  #
  vks_calm_gate_wait() { # ns_endpoint ns_name org_token
    [ "${vks_calm_gate:-true}" == "true" ] || return 0
    local limit="${vks_calm_limit_sec:-3}" max_wait="${vks_calm_max_wait_sec:-600}" waited=0 good=0 a b
    while [ "${waited}" -lt "${max_wait}" ]; do
      a=$(curl -sk -m 15 -o /dev/null -w '%{http_code} %{time_total}' -H "Authorization: Bearer ${vcfa_token}" -H "${ACCEPT}" "${VCFA_HOST}/cloudapi/1.0.0/orgs?pageSize=1" 2>/dev/null)
      b=$(curl -sk -m 15 -o /dev/null -w '%{http_code} %{time_total}' -H "Authorization: Bearer ${3}" "${1}/apis/cluster.x-k8s.io/v1beta2/namespaces/${2}/clusters" 2>/dev/null)
      if awk -v a="${a:-000 99}" -v b="${b:-000 99}" -v l="${limit}" 'BEGIN{split(a,x," "); split(b,y," "); exit !(x[1]!="000" && y[1]!="000" && x[2]+0<l && y[2]+0<l)}'; then
        good=$((good + 1))
        [ "${good}" -ge 3 ] && return 0
      else
        good=0
      fi
      sleep 10; waited=$((waited + 10))
    done
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: calm gate: the platform did not get calm within ${max_wait}s (last: provider API ${a:-none}, Supervisor API ${b:-none}), creating the next VKS cluster anyway" "${log_file}" "${slack_webhook}" "${google_webhook}"
  }

  #
  # The finishing steps of one org's VKS cluster (wait for Available, kubeconfig, pod security, cert01, ArgoCD, kubeconfig
  # copy to the org's home). Loop 1 below calls it right after each cluster is created, so the clusters come up ONE AT A
  # TIME instead of all at once (16 clusters bootstrapping together overloaded the single-node VCF Automation and the
  # Supervisor - the API servers stopped answering and everything restarted). It is also called once after loop 1 as a
  # catch-up pass for the orgs whose cluster was not Available yet (vks_done_orgs lists the ones that were).
  # Set vks_sequential=false to get the old behaviour (create all, then wait for all).
  #
  # Terminates on status.conditions[] type=="Available" status=="True" - confirmed live this is CAPI's own top-level
  # cluster-wide readiness signal (control plane + all workers healthy), NOT the same as phase=="Provisioned" (only means
  # the topology/infra request was accepted - observed within seconds of creation while nodes were still booting).
  #
  # Re-derives org token/namespace/cluster name from scratch per org rather than reusing anything from loop 1, since bash
  # doesn't carry per-iteration loop state across two separate while-read loops - same GET-by-name approach used
  # throughout this script.
  #
  vks_done_orgs=""
  vks_finish_pass() {
  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
      # one-org mode (vks_filter_org set by loop 1) and catch-up mode (orgs already Available are skipped)
      if [ -n "${vks_filter_org:-}" ] && [ "${org_name}" != "${vks_filter_org}" ]; then continue; fi
      case " ${vks_done_orgs:-} " in *" ${org_name} "*) continue ;; esac
      vks_enabled=$(echo ${item} | jq -c -r '.vks_cluster.enabled // false')
      if [ "${vks_enabled}" != "true" ]; then
        continue
      fi

      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
      org_uuid="${org_id##*:}"
      org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
        -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${vcfa_token}" \
        --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
      if [ -z "${org_token}" ] || [ "${org_token}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to obtain an org-scoped token for ${org_name}, skipping its VKS status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      project="default-project"
      cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces" "" "${org_token}"
      ns_name=$(echo ${response_body} | jq -c -r --arg arg "${org_name}-ns-" '.items[] | select(.metadata.name | startswith($arg)) | .metadata.name' | head -1)
      if [ -z "${ns_name}" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no namespace found for ${org_name}, skipping VKS status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi
      cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces/${ns_name}" "" "${org_token}"
      ns_endpoint=$(echo ${response_body} | jq -c -r '.status.namespaceEndpointURL')
      if [ -z "${ns_endpoint}" ] || [ "${ns_endpoint}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no namespaceEndpointURL for ${ns_name} (${org_name}), skipping VKS status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      ns_k8s_api GET "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters" "" "${org_token}"
      vks_name=$(echo ${response_body} | jq -c -r '.items[0].metadata.name')
      if [ -z "${vks_name}" ] || [ "${vks_name}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no VKS cluster found for ${org_name} in namespace ${ns_name}, skipping status check" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      retry_vks=60 ; pause_vks=30 ; attempt_vks=1
      while true
      do
        ns_k8s_api GET "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters/${vks_name}" "" "${org_token}"
        vks_available=$(echo ${response_body} | jq -c -r '.status.conditions[]? | select(.type=="Available") | .status')
        #
        # This loop can silently wait up to retry_vks*pause_vks (30
        # minutes) per org with zero log output otherwise - confirmed
        # live this reads as "the script looks stuck" from the log
        # alone, even when it's working correctly. One progress line
        # every 5 attempts (~2.5 min) so a long wait stays visible.
        #
        if [ $((attempt_vks % 5)) -eq 0 ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: still waiting for VKS cluster ${vks_name} for ${org_name} to become Available (attempt ${attempt_vks}/${retry_vks}, last status=${vks_available:-unknown})" "${log_file}" "" ""
        fi
        if [[ "${vks_available}" == "True" ]]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} is Available after ${attempt_vks} attempts of ${pause_vks} seconds" "${log_file}" "" ""
          vks_done_orgs="${vks_done_orgs:-} ${org_name} "
          #
          # status.conditions[type=Available] only reflects CAPI's own
          # control-plane/machine-level readiness (confirmed live earlier
          # this session via the clusterNetwork.pods.cidrBlocks bug:
          # Available flipped True well before antrea actually had a
          # working pod network) - it says nothing about whether the
          # cluster's own core add-on pods have actually finished
          # starting. The org-scoped token used everywhere else in this
          # script has no RBAC inside the workload cluster itself
          # (confirmed live: "forbidden" on pods/secrets/namespaces even
          # via its own namespaceEndpointURL proxy) - CAPI's own
          # <cluster-name>-kubeconfig Secret (created automatically by
          # the Supervisor, alongside the Cluster object, in the SAME
          # namespace) is the one credential with genuine cluster-admin
          # access, reachable only via the Supervisor's own kubectl
          # context (sup-admin-01), same auth_supervisor_custer.sh helper
          # the vault-integration step above already uses.
          #
          bash /home/ubuntu/supervisor/auth_supervisor_custer.sh >/dev/null 2>&1
          vks_kubeconfig="/tmp/${org_name}-vks-admin-kubeconfig.yaml"
          kubectl --context sup-admin-01 get secret "${vks_name}-kubeconfig" -n "${ns_name}" -o jsonpath='{.data.value}' 2>/dev/null | base64 -d > "${vks_kubeconfig}"
          if [ ! -s "${vks_kubeconfig}" ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: could not retrieve admin kubeconfig for VKS cluster ${vks_name} (${org_name}), skipping pod-security/cert01 setup" "${log_file}" "${slack_webhook}" "${google_webhook}"
          else
            #
            # Wait for every pod in the cluster to be Running/Succeeded
            # before doing anything below that assumes a genuinely
            # working cluster (matches this session's own hard-won lesson
            # that "Available" alone isn't sufficient).
            #
            retry_pods=20 ; pause_pods=15 ; attempt_pods=1
            while true; do
              not_ready_count=$(kubectl --kubeconfig="${vks_kubeconfig}" get pods -A -o json 2>/dev/null | jq -c -r '[.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded")] | length')
              if [ "${not_ready_count}" == "0" ]; then
                log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: all pods Running/Succeeded in VKS cluster ${vks_name} for ${org_name} after ${attempt_pods} attempts of ${pause_pods} seconds" "${log_file}" "" ""
                break
              fi
              if [ ${attempt_pods} -eq ${retry_pods} ]; then
                log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} still has ${not_ready_count:-unknown} non-Running pods after ${attempt_pods} attempts of ${pause_pods} seconds, proceeding anyway" "${log_file}" "${slack_webhook}" "${google_webhook}"
                break
              fi
              sleep ${pause_pods}
              ((attempt_pods++))
            done

            #
            # Pod Security Admission defaults to "restricted" on this
            # ClusterClass, which blocks workloads with no securityContext
            # (e.g. the plain busybox demo containers) from starting in
            # the default namespace - relax it to "privileged" there.
            #
            # A few tries: right after the cluster comes up its API server can fail a single call (seen once on org-12, which the
            # catch-up pass would not redo because the org counts as done as soon as the cluster is Available).
            label_rc=1
            for label_attempt in 1 2 3 4 5; do
              kubectl --kubeconfig="${vks_kubeconfig}" label --overwrite ns default pod-security.kubernetes.io/enforce=privileged && { label_rc=0; break; }
              sleep 10
            done
            if [ ${label_rc} -eq 0 ]; then
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: default namespace pod-security.kubernetes.io/enforce=privileged applied for ${org_name}'s VKS cluster ${vks_name}" "${log_file}" "" ""
            else
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to label default namespace pod-security.kubernetes.io/enforce=privileged for ${org_name}'s VKS cluster ${vks_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
            fi

            #
            # cert01 - a wildcard self-signed TLS cert for
            # *.<avi_subdomain>.<domain>, matching the same wildcard
            # hostname convention the demo Gateway yaml rendering already
            # uses (Gateway listener hostname = "*.<full_domain>") - so
            # this cert actually covers whatever hostname a demo
            # Ingress/Gateway/HTTPRoute ends up using. Idempotent by
            # presence (skip if cert01 already exists), not re-issued
            # every run.
            #
            if kubectl --kubeconfig="${vks_kubeconfig}" get secret cert01 -n default >/dev/null 2>&1; then
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: TLS secret cert01 already exists in default namespace for ${org_name}'s VKS cluster ${vks_name}, skipping" "${log_file}" "" ""
            else
              ssl_key="/tmp/${org_name}-ssl.key"
              ssl_crt="/tmp/${org_name}-ssl.crt"
              openssl req -newkey rsa:4096 -x509 -sha256 -days 3650 -nodes \
                -out "${ssl_crt}" -keyout "${ssl_key}" \
                -subj "/C=US/ST=CA/L=Palo Alto/O=VMWARE/OU=IT/CN=*.${avi_subdomain}.${domain}" 2>/dev/null
              kubectl --kubeconfig="${vks_kubeconfig}" create secret tls cert01 -n default --key="${ssl_key}" --cert="${ssl_crt}"
              if [ $? -eq 0 ]; then
                log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: TLS secret cert01 (CN=*.${avi_subdomain}.${domain}) created in default namespace for ${org_name}'s VKS cluster ${vks_name}" "${log_file}" "" ""
              else
                log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to create TLS secret cert01 for ${org_name}'s VKS cluster ${vks_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
              fi
              rm -f "${ssl_key}" "${ssl_crt}"
            fi

            #
            # Standalone ArgoCD in this org's VKS cluster (vks_cluster.argocd.enabled of the org in spec.sddc.vcf_a, formerly
            # the global spec.sddc.argocd.enabled; needs spec.sddc.k8s.git.enabled, the Git
            # server built earlier by git-bootstrap.sh). Installs the Helm chart plus the org's Gitea repo as a repository
            # credential, onboards that repo with one sample Application and checks its ConfigMap reaches the cluster
            # (further Applications are left to the org), and exposes the UI at argocd.<org>-vks.<domain> (the DNS
            # zone Avi is authoritative for, for this org's VKS cluster) through an AKO Gateway/HTTPRoute with a
            # self-signed certificate, like cert01 above. Offline-first like git-bootstrap.sh: the chart (.tgz) and the
            # argocd/redis images (pushed to Harbor by supervisor-bootstrap.sh) come from the gw-tools ISO, the Internet is
            # only a fallback. Idempotent (helm upgrade --install, apply) and non-fatal: every failure is logged and the
            # rest of this org's setup carries on. The Supervisor-side ArgoCD Supervisor Service is deliberately not used:
            # it can only deploy into a registered Supervisor namespace or cluster with a role the namespace owner has
            # to grant, while a standalone instance targets its own cluster (kubernetes.default.svc) with no registration.
            #
            argocd_org_enabled=$(echo ${item} | jq -c -r '.vks_cluster.argocd.enabled // false')
            if [ "${argocd_org_enabled}" == "true" ]; then
              argocd_fqdn="${argocd_fqdn_prefix}.${org_name}-vks.${domain}"
              argocd_fail() {
                log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: ArgoCD for ${org_name}'s VKS cluster ${vks_name}: $1 - continuing without it" "${log_file}" "${slack_webhook}" "${google_webhook}"
              }
              argocd_work=$(mktemp -d)
              chmod 700 "${argocd_work}"
              argocd_kc() { kubectl --kubeconfig="${vks_kubeconfig}" "$@"; }
              for argocd_once in once; do
                if [ "${git_enabled}" != "true" ]; then
                  argocd_fail "vks_cluster.argocd.enabled needs sddc.k8s.git.enabled (the org's repo is its credential)"; break
                fi
                for argocd_tool in helm openssl jq curl; do
                  command -v "${argocd_tool}" > /dev/null 2>&1 || { argocd_fail "${argocd_tool} is not installed on gw"; break 2; }
                done
                # Same derivation as git-bootstrap.sh's org user (gw_accounts_secret + org name)
                argocd_git_fqdn="${git_fqdn_prefix}.${avi_subdomain}.${domain}"
                argocd_org_password="VMware1!$(echo -n "${gw_accounts_secret}${org_name}" | sha256sum | cut -c1-4)VMware1!"
                argocd_repo_url="https://${argocd_git_fqdn}/${org_name}/${git_repo_name}.git"
                ( umask 077; printf 'user = "%s:%s"\n' "${org_name}" "${argocd_org_password}" > "${argocd_work}/curl.conf" )
                argocd_repo_code=$(curl -sk -m 20 -K "${argocd_work}/curl.conf" -o /dev/null -w '%{http_code}' "https://${argocd_git_fqdn}/api/v1/repos/${org_name}/${git_repo_name}")
                if [ "${argocd_repo_code}" != "200" ]; then
                  argocd_fail "the Gitea repo ${org_name}/${git_repo_name} is not reachable as ${org_name} (HTTP ${argocd_repo_code:-none}, https://${argocd_git_fqdn}) - was git-bootstrap.sh completed?"; break
                fi

                # Gitea's certificate chain (Vault PKI): every certificate after the first (the leaf) is the CA ArgoCD's repo
                # server has to trust. Without it the repo credential falls back to skipping the verification (warning).
                echo | openssl s_client -connect "${argocd_git_fqdn}:443" -servername "${argocd_git_fqdn}" -showcerts 2> /dev/null \
                  | awk '/BEGIN CERTIFICATE/{n++} n>=2{print} /END CERTIFICATE/{if(n>=2) print ""}' | sed '/^$/d' > "${argocd_work}/git-ca.pem"
                argocd_git_insecure="false"
                if ! grep -q 'BEGIN CERTIFICATE' "${argocd_work}/git-ca.pem"; then
                  argocd_git_insecure="true"
                  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: WARNING: ArgoCD for ${org_name}: no CA certificate in the chain served by ${argocd_git_fqdn}, the repository credential will not verify its TLS certificate" "${log_file}" "${slack_webhook}" "${google_webhook}"
                fi

                # Chart: the ISO's file if present, else the chart repository
                if [ -s "/home/ubuntu/${argocd_chart_file}" ]; then
                  argocd_chart="/home/ubuntu/${argocd_chart_file}"
                else
                  helm pull argo-cd --repo "${argocd_helm_repo_url}" --version "${argocd_chart_version}" -d "${argocd_work}" > /dev/null 2>&1 \
                    || { argocd_fail "no chart file /home/ubuntu/${argocd_chart_file} and the chart repository ${argocd_helm_repo_url} does not answer"; break; }
                  argocd_chart="${argocd_work}/argo-cd-${argocd_chart_version}.tgz"
                  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: WARNING: ArgoCD for ${org_name}: chart from ${argocd_helm_repo_url} (no ${argocd_chart_file} on the gw-tools ISO)" "${log_file}" "" ""
                fi

                # Images: Harbor if it has both (<name>_<tag>.tar -> <name>:<tag>), else the chart's upstream defaults.
                argocd_img_base="$(basename "${argocd_image_file}" .tar.gz)"; argocd_img_base="$(basename "${argocd_img_base}" .tar)"
                argocd_img_name="${argocd_img_base%%_*}"; argocd_img_tag="${argocd_img_base#*_}"
                argocd_redis_base="$(basename "${argocd_redis_image_file}" .tar.gz)"; argocd_redis_base="$(basename "${argocd_redis_base}" .tar)"
                argocd_redis_name="${argocd_redis_base%%_*}"; argocd_redis_tag="${argocd_redis_base#*_}"
                argocd_harbor_host="harbor.${avi_subdomain}.${domain}"
                argocd_harbor_ca="/home/ubuntu/harbor-ca.crt"
                argocd_from_harbor="true"
                if [ ! -s "${argocd_harbor_ca}" ]; then
                  argocd_from_harbor="false"
                else
                  for argocd_img in "${argocd_img_name}:${argocd_img_tag}" "${argocd_redis_name}:${argocd_redis_tag}"; do
                    # anonymous token first (Harbor answers a plain manifest request with 401), as git-bootstrap.sh does
                    argocd_img_token=$(curl -s -m 15 --cacert "${argocd_harbor_ca}" "https://${argocd_harbor_host}/service/token?service=harbor-registry&scope=repository:${argocd_harbor_project}/${argocd_img%%:*}:pull" 2> /dev/null | jq -r '.token // empty' 2> /dev/null)
                    argocd_img_code=$(curl -s -m 15 --cacert "${argocd_harbor_ca}" -o /dev/null -w '%{http_code}' ${argocd_img_token:+-H "Authorization: Bearer ${argocd_img_token}"} \
                      -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json' \
                      "https://${argocd_harbor_host}/v2/${argocd_harbor_project}/${argocd_img%%:*}/manifests/${argocd_img#*:}")
                    [ "${argocd_img_code}" == "200" ] || argocd_from_harbor="false"
                  done
                fi

                # Values: no Dex, no notifications, the UI behind AKO (TLS ends at the Avi virtual service: insecure = plain
                # HTTP from there to argocd-server), the Gitea CA, and - when bcrypt is available - the admin password set to
                # the org's usual password (otherwise ArgoCD's random initial password stays in argocd-initial-admin-secret).
                jq -n --arg fqdn "${argocd_fqdn}" --arg gitfqdn "${argocd_git_fqdn}" --rawfile ca "${argocd_work}/git-ca.pem" \
                  '{dex: {enabled: false}, notifications: {enabled: false},
                    configs: {params: {"server.insecure": true}, cm: {url: ("https://" + $fqdn)}}}
                   | if ($ca | length) > 0 then .configs.tls = {certificates: {($gitfqdn): $ca}} else . end' > "${argocd_work}/values.json"
                if [ "${argocd_from_harbor}" == "true" ]; then
                  jq --arg ai "${argocd_harbor_host}/${argocd_harbor_project}/${argocd_img_name}" --arg at "${argocd_img_tag}" \
                     --arg ri "${argocd_harbor_host}/${argocd_harbor_project}/${argocd_redis_name}" --arg rt "${argocd_redis_tag}" \
                     '.global.image = {repository: $ai, tag: $at} | .redis.image = {repository: $ri, tag: $rt}' "${argocd_work}/values.json" > "${argocd_work}/values.tmp" \
                    && mv "${argocd_work}/values.tmp" "${argocd_work}/values.json"
                  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ArgoCD for ${org_name}: images from Harbor (${argocd_harbor_host}/${argocd_harbor_project})" "${log_file}" "" ""
                else
                  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: WARNING: ArgoCD for ${org_name}: images NOT from Harbor (${argocd_harbor_host}/${argocd_harbor_project}/${argocd_img_name}:${argocd_img_tag} or ${argocd_redis_name}:${argocd_redis_tag} missing, or no Harbor CA), the VKS nodes will pull the chart's upstream images from the Internet" "${log_file}" "${slack_webhook}" "${google_webhook}"
                fi
                # The admin hash has to be in the values on EVERY run: a chart rendered without it drops admin.password from
                # argocd-secret and ArgoCD falls back to its random initial password. So when the stored hash still matches
                # the org's password it is passed again as it is (with its timestamp: no needless rewrite), else a new one.
                argocd_admin_hash=""; argocd_admin_mtime=""
                if python3 -c 'import bcrypt' > /dev/null 2>&1; then
                  argocd_current_hash=$(argocd_kc -n "${argocd_namespace}" get secret argocd-secret -o jsonpath='{.data.admin\.password}' 2> /dev/null | base64 -d 2> /dev/null)
                  argocd_current_mtime=$(argocd_kc -n "${argocd_namespace}" get secret argocd-secret -o jsonpath='{.data.admin\.passwordMtime}' 2> /dev/null | base64 -d 2> /dev/null)
                  if [ -n "${argocd_current_hash}" ] && [ -n "${argocd_current_mtime}" ] \
                     && ARGOCD_PW="${argocd_org_password}" ARGOCD_H="${argocd_current_hash}" python3 -c 'import bcrypt,os,sys;sys.exit(0 if bcrypt.checkpw(os.environ["ARGOCD_PW"].encode(),os.environ["ARGOCD_H"].encode()) else 1)' 2> /dev/null; then
                    argocd_admin_hash="${argocd_current_hash}"; argocd_admin_mtime="${argocd_current_mtime}"
                  else
                    argocd_admin_hash=$(ARGOCD_PW="${argocd_org_password}" python3 -c 'import bcrypt,os;print(bcrypt.hashpw(os.environ["ARGOCD_PW"].encode(),bcrypt.gensalt(10)).decode())' 2> /dev/null)
                    argocd_admin_mtime="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                  fi
                fi
                if [ -n "${argocd_admin_hash}" ]; then
                  ( umask 077; jq --arg h "${argocd_admin_hash}" --arg t "${argocd_admin_mtime}" \
                      '.configs.secret = {argocdServerAdminPassword: $h, argocdServerAdminPasswordMtime: $t}' "${argocd_work}/values.json" > "${argocd_work}/values.tmp" )
                  mv "${argocd_work}/values.tmp" "${argocd_work}/values.json"
                fi

                # Certificate of the UI (self-signed, SAN = the FQDN), before the Gateway so AKO finds the Secret at once
                argocd_kc create namespace "${argocd_namespace}" --dry-run=client -o yaml | argocd_kc apply -f - > /dev/null 2>&1 \
                  || { argocd_fail "cannot create the namespace ${argocd_namespace}"; break; }
                if ! argocd_kc -n "${argocd_namespace}" get secret "${argocd_tls_secret}" > /dev/null 2>&1; then
                  openssl req -newkey rsa:2048 -x509 -sha256 -days 3650 -nodes -out "${argocd_work}/tls.crt" -keyout "${argocd_work}/tls.key" \
                    -subj "/CN=${argocd_fqdn}" -addext "subjectAltName=DNS:${argocd_fqdn}" > /dev/null 2>&1 \
                    && argocd_kc -n "${argocd_namespace}" create secret tls "${argocd_tls_secret}" --key="${argocd_work}/tls.key" --cert="${argocd_work}/tls.crt" > /dev/null 2>&1 \
                    || { argocd_fail "cannot create the TLS secret ${argocd_tls_secret}"; break; }
                fi

                helm --kubeconfig "${vks_kubeconfig}" upgrade --install argocd "${argocd_chart}" -n "${argocd_namespace}" -f "${argocd_work}/values.json" \
                  --wait --timeout 300s > "${argocd_work}/helm.log" 2>&1 \
                  || { argocd_fail "helm upgrade --install failed: $(tail -3 "${argocd_work}/helm.log" | tr '\n' ' ')"; break; }

                # An upgrade that re-renders argocd-secret (the admin password above) drops the server's session signing key
                # (server.secretkey), which argocd-server only re-creates when it starts: every login then fails with HTTP
                # 500 "server.secretkey is missing". Restart the server when the key is gone.
                if [ -z "$(argocd_kc -n "${argocd_namespace}" get secret argocd-secret -o jsonpath='{.data.server\.secretkey}' 2> /dev/null)" ]; then
                  argocd_kc -n "${argocd_namespace}" rollout restart deployment/argocd-server > /dev/null 2>&1 \
                    && argocd_kc -n "${argocd_namespace}" rollout status deployment/argocd-server --timeout=120s > /dev/null 2>&1 \
                    || { argocd_fail "argocd-server did not restart after the upgrade (server.secretkey was missing from argocd-secret)"; break; }
                fi

                # Repository credential: declarative (labelled Secret, picked up by ArgoCD at once). Files, not
                # --from-literal, so the password never shows on a command line other gw accounts can list.
                printf '%s' "git" > "${argocd_work}/f.type"; printf '%s' "${argocd_repo_url}" > "${argocd_work}/f.url"
                ( umask 077; printf '%s' "${org_name}" > "${argocd_work}/f.username"; printf '%s' "${argocd_org_password}" > "${argocd_work}/f.password" )
                argocd_secret_args=(--from-file=type="${argocd_work}/f.type" --from-file=url="${argocd_work}/f.url" --from-file=username="${argocd_work}/f.username" --from-file=password="${argocd_work}/f.password")
                if [ "${argocd_git_insecure}" == "true" ]; then
                  printf '%s' "true" > "${argocd_work}/f.insecure"
                  argocd_secret_args+=(--from-file=insecure="${argocd_work}/f.insecure")
                fi
                argocd_kc -n "${argocd_namespace}" create secret generic "${argocd_repo_secret}" "${argocd_secret_args[@]}" --dry-run=client -o yaml \
                  | argocd_kc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
                  | argocd_kc apply -f - > /dev/null 2>&1 \
                  || { argocd_fail "cannot create the repository secret ${argocd_repo_secret}"; break; }

                # Onboarding of the org's repo: one Application (automated sync, prune, self-heal) tracking the sample path
                # git-bootstrap.sh committed to it (a ConfigMap) into this cluster's default namespace. Then the end-to-end
                # proof Git -> ArgoCD -> cluster: wait until the ConfigMap really exists in the cluster, with this org's name
                # in it. Further Applications are the org's own business.
                argocd_kc apply -f - > "${argocd_work}/app.log" 2>&1 <<ARGOCD_APP_EOF || { argocd_fail "creating the Application ${argocd_app_name} failed: $(tail -2 "${argocd_work}/app.log" | tr '\n' ' ')"; break; }
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${argocd_app_name}
  namespace: ${argocd_namespace}
spec:
  project: default
  source:
    repoURL: ${argocd_repo_url}
    targetRevision: HEAD
    path: ${git_sample_path}
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
ARGOCD_APP_EOF
                argocd_synced="false"
                for argocd_attempt in $(seq 1 36); do
                  argocd_state=$(argocd_kc -n "${argocd_namespace}" get application "${argocd_app_name}" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2> /dev/null)
                  if [ "${argocd_state}" == "Synced/Healthy" ] && [ "$(argocd_kc -n default get configmap "${git_sample_configmap}" -o jsonpath='{.data.org}' 2> /dev/null)" == "${org_name}" ]; then
                    argocd_synced="true"; break
                  fi
                  sleep 5
                done
                if [ "${argocd_synced}" != "true" ]; then
                  argocd_why=$(argocd_kc -n "${argocd_namespace}" get application "${argocd_app_name}" -o json 2> /dev/null | jq -r '[.status.conditions[]?.message] | join("; ")' 2> /dev/null)
                  argocd_fail "the sample ConfigMap ${git_sample_configmap} from ${argocd_repo_url} (path ${git_sample_path}) is not in the cluster after 3 minutes (Application ${argocd_state:-unknown}${argocd_why:+: ${argocd_why}}) - was the sample committed by git-bootstrap.sh?"; break
                fi
                log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ArgoCD for ${org_name}: Application ${argocd_app_name} Synced/Healthy, ConfigMap ${git_sample_configmap} from ${argocd_repo_url} is in the cluster (default namespace)" "${log_file}" "" ""

                # UI: Gateway + HTTPRoute through AKO (same shape as the Git server's, the certificate is already there)
                argocd_kc apply -f - > "${argocd_work}/gateway.log" 2>&1 <<ARGOCD_GATEWAY_EOF || { argocd_fail "creating the Gateway/HTTPRoute failed: $(tail -2 "${argocd_work}/gateway.log" | tr '\n' ' ')"; break; }
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: ${argocd_gateway_name}
  namespace: ${argocd_namespace}
spec:
  gatewayClassName: avi-lb
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: ${argocd_fqdn}
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            name: ${argocd_tls_secret}
    - name: http
      protocol: HTTP
      port: 80
      hostname: ${argocd_fqdn}
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: argocd
  namespace: ${argocd_namespace}
spec:
  parentRefs:
    - name: ${argocd_gateway_name}
  hostnames:
    - ${argocd_fqdn}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
ARGOCD_GATEWAY_EOF
                argocd_vip=""
                for argocd_attempt in $(seq 1 30); do
                  argocd_vip=$(argocd_kc -n "${argocd_namespace}" get gateway "${argocd_gateway_name}" -o jsonpath='{.status.addresses[0].value}' 2> /dev/null)
                  [ -n "${argocd_vip}" ] && break
                  sleep 10
                done
                if [ -z "${argocd_vip}" ]; then
                  argocd_why=$(argocd_kc -n "${argocd_namespace}" get gateway "${argocd_gateway_name}" -o json 2> /dev/null | jq -r '[.status.listeners[]?.conditions[]? | select(.status == "False") | .message] | unique | join("; ")' 2> /dev/null)
                  argocd_fail "the Gateway ${argocd_gateway_name} got no address from AKO/Avi (${argocd_why:-no reason reported}; a 'sub-domains' message means Avi's DNS profile has no ${org_name}-vks.${domain} domain, or AKO has to be restarted to learn it) - kubectl -n ${argocd_namespace} describe gateway ${argocd_gateway_name}"; break
                fi
                # AKO may have put this Gateway's virtual services on another Avi SE than the cluster's control-plane VIP: move them
                # to that SE, so the org needs a vNIC on one SE only (functions.sh; avi_colocate_vs=false turns it off)
                avi_colocate_org_vs "${org_name}" "${vks_name}"
                # Through the VIP (not DNS: the name is only resolvable once Avi's DNS knows it)
                argocd_ui_code=""
                for argocd_attempt in $(seq 1 18); do
                  argocd_ui_code=$(curl -sk -m 10 --resolve "${argocd_fqdn}:443:${argocd_vip}" -o /dev/null -w '%{http_code}' "https://${argocd_fqdn}/healthz")
                  [ "${argocd_ui_code}" == "200" ] && break
                  sleep 10
                done
                if [ "${argocd_ui_code}" != "200" ]; then
                  argocd_fail "the UI https://${argocd_fqdn} (VIP ${argocd_vip}) does not answer on /healthz (HTTP ${argocd_ui_code:-none})"; break
                fi
                if [ -n "${argocd_admin_hash}" ]; then
                  argocd_login_hint="user admin, the org's usual password"
                else
                  argocd_login_hint="user admin, password in the secret argocd-initial-admin-secret of namespace ${argocd_namespace}"
                fi
                log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ArgoCD for ${org_name}'s VKS cluster ${vks_name} is ready: https://${argocd_fqdn} (VIP ${argocd_vip}; ${argocd_login_hint}), repository ${argocd_repo_url} registered as ${argocd_repo_secret}" "${log_file}" "${slack_webhook}" "${google_webhook}"
              done
              rm -rf "${argocd_work}"
              unset -f argocd_fail argocd_kc
            fi

            #
            # Hand this same admin kubeconfig to the org's own account
            # (see gw-accounts.sh) so its SSH login has a fully-ready
            # `kubectl` against its own VKS cluster with no extra
            # context-selection step. It's a plain client-cert kubeconfig
            # (not a Pinniped/OIDC exec plugin), so a static copy works
            # standalone. Unconditional overwrite on every run - stable
            # content across reruns for the same cluster, no idempotency
            # check needed.
            #
            org_kube_dir="$(org_home_dir "${org_name}")/.kube"
            sudo mkdir -p "${org_kube_dir}"
            sudo cp "${vks_kubeconfig}" "${org_kube_dir}/config"
            chown_org_or_ubuntu "${org_name}" "${org_kube_dir}"
            sudo chmod 700 "${org_kube_dir}"
            sudo chmod 600 "${org_kube_dir}/config"
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: kubeconfig for VKS cluster ${vks_name} copied to ${org_kube_dir}/config" "${log_file}" "" ""
          fi
          rm -f "${vks_kubeconfig}"
          break
        fi
        ((attempt_vks++))
        if [ ${attempt_vks} -eq ${retry_vks} ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} NOT Available after ${attempt_vks} attempts of ${pause_vks} seconds (last Available status=${vks_available:-unknown})" "${log_file}" "${slack_webhook}" "${google_webhook}"
          break
        fi
        sleep ${pause_vks}
      done
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])
  }

  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
      region_ref_name=$(echo ${item} | jq -c -r '.region_ref')
      namespace_enabled=$(echo ${item} | jq -c -r '.namespace.enabled // false')
      if [ "${namespace_enabled}" != "true" ]; then
        continue
      fi
      avi_mode=$(echo ${item} | jq -c -r '.avi_mode // "TENANT_MANAGED"')
      seg_name=$(echo ${item} | jq -c -r '.avi_service_engine_group_ref')
      if [ "${avi_mode}" != "PROVIDER_MANAGED" ] || [ -z "${seg_name}" ] || [ "${seg_name}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${org_name} has namespace.enabled but avi_mode is not PROVIDER_MANAGED (or has no SEG) - TENANT_MANAGED namespace provisioning is not yet supported, skipping" "${log_file}" "" ""
        continue
      fi

      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
      org_uuid="${org_id##*:}"

      vcfa_api GET "cloudapi/v1/regions" ""
      region_id=$(echo ${response_body} | jq -c -r --arg arg "${region_ref_name}" '.values[] | select(.name == $arg) | .id')

      vcfa_api GET "cloudapi/v1/regionStoragePolicies" ""
      storage_class_k8s_name=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .kubernetesCompliantName' | head -1)

      org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
        -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${vcfa_token}" \
        --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
      if [ -z "${org_token}" ] || [ "${org_token}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to obtain an org-scoped token for ${org_name}, skipping its namespace" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      project="default-project"
      cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces" "" "${org_token}"
      ns_name=$(echo ${response_body} | jq -c -r --arg arg "${org_name}-ns-" '.items[] | select(.metadata.name | startswith($arg)) | .metadata.name' | head -1)
      if [ -n "${ns_name}" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace for ${org_name} already exists (${ns_name}), skipping creation" "${log_file}" "" ""
      else
        # zone_ref is NOT an input field here either - same derivation
        # as the vDC creation step above (one zone per region).
        vcfa_api GET "cloudapi/v1/zones" ""
        zone_name=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .name' | head -1)
        namespace_class=$(echo ${item} | jq -c -r '.namespace.class // "small"')
        namespace_cpu_limit_mhz=$(echo ${item} | jq -c -r '.namespace.cpu_limit_mhz')
        namespace_memory_limit_mib=$(echo ${item} | jq -c -r '.namespace.memory_limit_mib')
        namespace_storage_limit_mib=$(echo ${item} | jq -c -r '.namespace.storage_limit_mib')

        ns_json=$(jq -n --arg prefix "${org_name}-ns-" --arg project "${project}" \
          --arg region "${region_ref_name}" --arg class "${namespace_class}" \
          --arg vpc "default-${region_ref_name}" --arg seg "${seg_name}" \
          --arg zonename "${zone_name}" --arg cpulimit "${namespace_cpu_limit_mhz}M" --arg memlimit "${namespace_memory_limit_mib}Mi" \
          --arg storagename "${storage_class_k8s_name}" --arg storagelimit "${namespace_storage_limit_mib}Mi" \
          '{apiVersion: "infrastructure.cci.vmware.com/v1alpha3", kind: "SupervisorNamespace",
            metadata: {generateName: $prefix, namespace: $project},
            spec: {regionName: $region, className: $class, vpcName: $vpc, segName: $seg,
              classConfigOverrides: {
                zones: [{name: $zonename, cpuLimit: $cpulimit, cpuReservation: "0", memoryLimit: $memlimit, memoryReservation: "0"}],
                storageClasses: [{name: $storagename, limit: $storagelimit}]
              }}}')
        cci_api POST "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces" "${ns_json}" "${org_token}"
        if [ $? -ne 0 ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace creation for ${org_name} FAILED, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi
        ns_name=$(echo ${response_body} | jq -c -r '.metadata.name')

        # Raised from 12 (3 min): under load a namespace needed about 10 minutes to reach Created
        retry_ns=60 ; pause_ns=15 ; attempt_ns=1
        while true
        do
          sleep ${pause_ns}
          cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces/${ns_name}" "" "${org_token}"
          ns_phase=$(echo ${response_body} | jq -c -r '.status.phase')
          if [[ "${ns_phase}" == "Created" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace ${ns_name} for ${org_name} reached phase Created after ${attempt_ns} attempts of ${pause_ns} seconds" "${log_file}" "" ""
            break
          fi
          ((attempt_ns++))
          if [ ${attempt_ns} -eq ${retry_ns} ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: namespace ${ns_name} for ${org_name} not Created after ${attempt_ns} attempts of ${pause_ns} seconds (phase=${ns_phase})" "${log_file}" "${slack_webhook}" "${google_webhook}"
            break
          fi
        done
      fi

      #
      # VM Service content library binding - a separate, lower layer than
      # VCFA's own "content library visible from every org's portal"
      # sharing above (cloudapi/v1/contentLibraries, done once for all
      # orgs) - confirmed live (blueprint admission webhook error:
      # VirtualMachineImage "vmi-..." not found, traced down to vCenter's
      # own API) that VM Service only projects a content library's items
      # into a namespace as VirtualMachineImage objects if that library's
      # vCenter-NATIVE uuid is explicitly listed in the namespace's own
      # vm_service_spec.content_libraries (vCenter's
      # api/vcenter/namespaces/instances/{ns} API) - a completely
      # different id space than VCFA's own urn:vcloud:contentLibrary:...
      # id, so the two can't just be string-matched. VCFA-level "shared"
      # visibility alone does NOT populate this. Every
      # vcf_a_content_libraries entry is provider-wide/shared by design
      # (see the "one library serves every org" comment above), so all of
      # them are bound to every eligible org's namespace here
      # automatically - no new CRD field needed. Existing entries (e.g. a
      # tenant's own org-created library, confirmed live to exist
      # side-by-side) are preserved by merging rather than overwriting.
      # Runs regardless of whether ns_name was just created above or
      # already existed, same as the Vault step below, since an
      # already-existing namespace from before this step existed would
      # otherwise never get the binding retrofitted.
      #
      if [ -n "${ns_name}" ]; then
        create_vcenter_api_session
        vcenter_api 3 3 GET "api/content/library" ""
        all_lib_ids=$(echo "${response_body}" | jq -r '.[]')
        vc_lib_uuids=""
        while read -r shared_cl_name
        do
          [ -z "${shared_cl_name}" ] && continue
          for lib_id in ${all_lib_ids}; do
            vcenter_api 3 3 GET "api/content/library/${lib_id}" ""
            lib_name=$(echo "${response_body}" | jq -r '.name')
            if [ "${lib_name}" == "${shared_cl_name}" ]; then
              vc_lib_uuids="${vc_lib_uuids} ${lib_id}"
              break
            fi
          done
        done < <(echo "${vcf_a_content_libraries}" | jq -c -r '.[].name')

        if [ -n "$(echo ${vc_lib_uuids})" ]; then
          vcenter_api 3 3 GET "api/vcenter/namespaces/instances/${ns_name}" ""
          existing_libs=$(echo "${response_body}" | jq -c '.vm_service_spec.content_libraries // []')
          merged_libs=$(jq -n --argjson existing "${existing_libs}" --arg new "${vc_lib_uuids}" \
            '$existing + ($new | split(" ") | map(select(length > 0))) | unique')
          patch_json=$(jq -n --argjson libs "${merged_libs}" '{vm_service_spec: {content_libraries: $libs}}')
          vcenter_api 3 3 PATCH "api/vcenter/namespaces/instances/${ns_name}" "${patch_json}"
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: bound shared content libraries to namespace ${ns_name}'s vm_service_spec.content_libraries (${merged_libs})" "${log_file}" "" ""
        fi
      fi

      #
      # Vault cert-manager bootstrap - runs kubectl directly against the
      # Supervisor cluster (NOT VCFA's own API - these are plain K8s
      # objects VCFA doesn't manage), once this org's namespace is
      # confirmed present, regardless of whether it was just created
      # above or already existed (kubectl apply is idempotent, safe to
      # re-run every time this script runs).
      #
      # secret_vault.yaml/vault_issuer.yaml are raw placeholder templates
      # from demoavi/dev-avi-vcf, copied per-org into ${org_yaml_folder}
      # by vcfa_provider_bootstrap.sh's own demo-yaml rendering loop
      # (recomputed fresh below, not inherited - see that assignment's own
      # comment) untouched, since neither Kind is in the demo-yaml
      # by-Kind dispatch there - confirmed live this script previously
      # read them from a stale top-level /home/ubuntu/${yaml_folder}/
      # path that's never actually populated (that copy step was moved
      # into this script's own per-org loop, into a per-org subdirectory,
      # a while back - this comment and the paths below just never got
      # updated to match), so the kind/name sanity check below always
      # found an empty/nonexistent file and silently skipped vault
      # bootstrap for every org. ALL their real values are filled in
      # here instead, per org/namespace, using yq (mikefarah/yq, installed at
      # /usr/local/bin/yq by gw's own userdata). This has to happen here
      # rather than in cloud-init because the actual namespace name isn't
      # known until VCF-A creates it under this org (well after gw's own
      # first boot) - cloud-init is simply too early for that value, even
      # though the OTHER fields (vault token/server/path/caBundle) are
      # already knowable at cloud-init time. Keeping every substitution in
      # one place (here) rather than splitting them across cloud-init and
      # this script is deliberate, since this script is the one meant to
      # be ported to the local epc-vapp project later - having the whole
      # mechanism self-contained here keeps that port simple.
      #
      # A source-file kind/name sanity check guards against silently
      # patching the wrong file if the templates in dev-avi-vcf/yamls/
      # ever get renamed/restructured.
      #
      # auth_supervisor_custer.sh switches the local kubectl/vcf CLI
      # context to the Supervisor cluster itself (sup-admin-01) -
      # confirmed live this must run first, since a stale context left
      # over from other kubectl usage (e.g. a VKS workload cluster's own
      # context) otherwise causes TLS/cert errors reaching the
      # Supervisor's namespaces. Re-run per org rather than once for the
      # whole script, since a long batch run across many orgs could
      # plausibly outlast the CLI's own token (not yet observed live,
      # but a real risk given how long the aviSetting/
      # regionalNetworkingSettings polling elsewhere in this script can
      # already run).
      #
      vault_integration_enabled=$(echo ${item} | jq -c -r '.namespace.vault_integration.enabled // false')
      if [ -n "${ns_name}" ] && [ "${vault_integration_enabled}" == "true" ]; then
        bash /home/ubuntu/supervisor/auth_supervisor_custer.sh >/dev/null 2>&1

        # Recomputed here rather than inherited from
        # vcfa_provider_bootstrap.sh's own identical derivation (that
        # script's demo-yaml rendering loop is what actually creates this
        # directory) - now a genuinely separate process, and even within
        # the old single-file version this was already a latent bug
        # (this loop's own org_name can differ from whichever org the
        # OTHER, provider-portal loop last set org_yaml_folder to; it
        # only ever worked by coincidence, since secret_vault.yaml/
        # vault_issuer.yaml are byte-identical raw templates for every
        # org regardless of whose copy gets read).
        org_yaml_folder="$(org_home_dir "${org_name}")/${yaml_folder}"

        # org_yaml_folder is owned by ${org_name} now (handed off at the
        # end of the rendering loop in vcfa_provider_bootstrap.sh), not
        # ubuntu - these reads need sudo. The /tmp/*.yaml copies below are
        # ubuntu-owned as usual, so the yq -i edits on those don't need it.
        # The two manifests are found by CONTENT, not by file name (so they can be renamed or moved around in
        # dev-avi-vcf/yamls/): a single-document file of Kind Secret named cert-manager-vault-token, and one of
        # Kind Issuer named vault-issuer (find_org_manifest, functions.sh). Those two names are therefore a
        # contract - the manifests carry a "do not change" comment.
        vault_secret_file="$(find_org_manifest "${org_yaml_folder}" Secret cert-manager-vault-token)"
        vault_issuer_file="$(find_org_manifest "${org_yaml_folder}" Issuer vault-issuer)"
        if [ -z "${vault_secret_file}" ] || [ -z "${vault_issuer_file}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no manifest of Kind Secret named cert-manager-vault-token and/or Kind Issuer named vault-issuer found in ${org_yaml_folder} (secret file: '${vault_secret_file}', issuer file: '${vault_issuer_file}'), skipping vault bootstrap for ${org_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          sudo cp "${vault_secret_file}" "/tmp/${org_name}-secret_vault.yaml"
          sudo chown ubuntu:ubuntu "/tmp/${org_name}-secret_vault.yaml"
          yq -i ".metadata.namespace = \"${ns_name}\"" "/tmp/${org_name}-secret_vault.yaml"
          yq -i ".data.token = \"$(echo -n $(jq -c -r .root_token ${vault_secret_file_path}) | base64)\"" "/tmp/${org_name}-secret_vault.yaml"

          sudo cp "${vault_issuer_file}" "/tmp/${org_name}-vault_issuer.yaml"
          sudo chown ubuntu:ubuntu "/tmp/${org_name}-vault_issuer.yaml"
          yq -i ".metadata.namespace = \"${ns_name}\"" "/tmp/${org_name}-vault_issuer.yaml"
          yq -i ".spec.vault.server = \"https://${ip_gw}:8200\"" "/tmp/${org_name}-vault_issuer.yaml"
          yq -i ".spec.vault.path = \"${vault_pki_intermediate_name}/sign/${vault_pki_intermediate_role_name}\"" "/tmp/${org_name}-vault_issuer.yaml"
          # /opt/vault/tls/tls.crt is vault:vault 0600 - unreadable by this
          # script's own ubuntu user (unlike cloud-init, which built this
          # same value while still running as root) - confirmed live this
          # user has passwordless sudo, so read it that way instead.
          yq -i ".spec.vault.caBundle = \"$(sudo cat /opt/vault/tls/tls.crt | base64 -w0)\"" "/tmp/${org_name}-vault_issuer.yaml"

          kubectl_out=$( { kubectl apply -f "/tmp/${org_name}-secret_vault.yaml" && kubectl apply -f "/tmp/${org_name}-vault_issuer.yaml"; } 2>&1 )
          if [ $? -eq 0 ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vault secret + issuer applied for ${org_name} in namespace ${ns_name}" "${log_file}" "" ""
            # Only these two placeholder templates leave the org's yaml folder once applied (they are meaningless to
            # the org user); only on success, so a failed apply can still be retried. vcfa_provider_bootstrap.sh
            # copies them again on its next run.
            sudo rm -f "${vault_secret_file}" "${vault_issuer_file}"
          else
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vault secret/issuer apply FAILED for ${org_name} in namespace ${ns_name}, output: ${kubectl_out}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          fi
          rm -f "/tmp/${org_name}-secret_vault.yaml" "/tmp/${org_name}-vault_issuer.yaml"
        fi
      fi

      #
      # VKS cluster - very simple data model (vks_cluster.enabled only,
      # everything else stays at the UI's own "create with defaults"
      # values) - confirmed live against org-3's own namespace using the
      # exact topology observed on org-1's manually-created cluster
      # (kubernetes-cluster-q4md): ClusterClass builtin-generic-v3.6.0,
      # k8s v1.35.5+vmware.1, 1 control-plane + 1 worker replica,
      # vmClass best-effort-medium. Confirmed live it's
      # cluster.x-k8s.io/v1beta2 that the UI actually uses (v1beta1 is
      # accepted but deprecated AND rejects the request unless
      # clusterNetwork.services is also set - v1beta2 doesn't need that
      # worked around). clusterNetwork.pods.cidrBlocks, however, IS
      # required in both versions and has NO server-side default -
      # confirmed live: omitting it (as an earlier version of this script
      # did) leaves every node's Spec.PodCIDR permanently empty, crashing
      # antrea-agent cluster-wide (CrashLoopBackOff on "Spec.PodCIDR is
      # empty for Node") and cascading into virtually every other pod
      # staying stuck ContainerCreating. This range is NOT related to the
      # namespace's own NSX VPC private-IP block (privateIPs on that
      # VPC's NetworkInfo, e.g. 172.26.0.0/16 / 172.30.0.0/16 in this
      # environment) - it's a purely internal Antrea overlay CIDR, safe
      # to reuse identically across every org's cluster since each one is
      # isolated within its own VPC/namespace and never routes to
      # another's pod network directly. Value matches the one seen live
      # on a UI-created reference cluster (kubernetes-cluster-z8lk).
      # storageClass reuses ${storage_class_k8s_name}
      # already derived above for the namespace step, rather than
      # re-deriving it. The cluster starts with spec.paused: true
      # (set automatically by an admission webhook) and clears itself
      # within seconds with no action needed - confirmed live the
      # cluster then proceeds through normal machine provisioning
      # (phase: Provisioned, InfrastructureReady: True) with no
      # equivalent of org-1's "run.tanzu.vmware.com/resolve-os-image"
      # annotation required (the ClusterClass resolves a default OS
      # image on its own when that annotation is omitted).
      #
      # Confirmed live end-to-end (not just Provisioned): a second test
      # cluster created in org-1's own namespace with this exact payload
      # reached status.conditions[type=Available].status == "True"
      # (fully Ready) after ~8-10 minutes - CNI (Antrea) and the
      # vsphere-csi addon both take a few minutes to finish reconciling
      # after the nodes first come up, which is normal and not itself a
      # failure signal even though AddonsReconciled briefly reports
      # ReconcileFailed/timed-out during that window. A separate cluster
      # created in org-3's namespace stayed stuck well past that window
      # in this same test session - suspected to be an environment-
      # specific resource constraint (e.g. underlying vSAN capacity) on
      # that particular namespace/org, not a payload or script issue.
      #
      # The cluster is named <org>-vks-<id> (generateName "<org>-vks-"), so its VMs start with the org's name (DRS VM groups, vCenter
      # filters). Idempotency is by PRESENCE, not name (the API only supports
      # generateName, never a fixed name) - "one default cluster per
      # org" is the intent per vks_cluster's simple enable/disable model,
      # so if ANY cluster already exists in the namespace, none is
      # created.
      #
      vks_enabled=$(echo ${item} | jq -c -r '.vks_cluster.enabled // false')
      vks_count=$(echo ${item} | jq -c -r '.vks_cluster.count // 1')
      if [ "${vks_count}" != "1" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${org_name} has vks_cluster.count=${vks_count}, but only 1 is supported today - creating exactly 1" "${log_file}" "" ""
      fi
      if [ "${vks_enabled}" == "true" ] && [ -n "${ns_name}" ]; then
        cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces/${ns_name}" "" "${org_token}"
        ns_endpoint=$(echo ${response_body} | jq -c -r '.status.namespaceEndpointURL')
        if [ -z "${ns_endpoint}" ] || [ "${ns_endpoint}" == "null" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no namespaceEndpointURL for ${ns_name} (${org_name}), skipping VKS cluster" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          ns_k8s_api GET "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters" "" "${org_token}"
          existing_vks=$(echo ${response_body} | jq -c -r '.items[0].metadata.name')
          if [ -n "${existing_vks}" ] && [ "${existing_vks}" != "null" ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster for ${org_name} already exists (${existing_vks}), skipping creation" "${log_file}" "" ""
          else
            #
            # Harbor's self-signed CA is NOT trusted by guest VKS clusters
            # automatically. A bare top-level "trust" variable is rejected
            # by the capi.mutating.tanzukubernetescluster.run.tanzu.vmware.com
            # admission webhook ("variable is not defined") - confirmed live
            # 2026-09-25 "trust" is not actually a top-level ClusterClass
            # variable at all, just a field NESTED inside the "osConfiguration"
            # variable (alongside systemProxy/tuned) - it only ever appeared
            # in the raw schema dump because that dump includes every nested
            # property, not just top-level variable names (which live in
            # `.status.variables` - osConfiguration is there, a bare "trust"
            # never was). Confirmed working via `--dry-run=server` with
            # {name: "osConfiguration", value: {trust: {...}}}. builtin-
            # generic-v3.6.0 itself has no trust-capable patches wired in and
            # gets silently upgraded to v3.7.0 by the webhook when this is
            # used, hence classRef below targets v3.7.0 directly.
            #
            harbor_ca_cert_path="/home/ubuntu/harbor-ca.crt"
            os_configuration_json="null"
            if [ -s "${harbor_ca_cert_path}" ]; then
              os_configuration_json=$(jq -n --rawfile ca "${harbor_ca_cert_path}" \
                '{name: "osConfiguration", value: {trust: {additionalTrustedCAs: [{caCert: {content: $ca}}]}}}')
            fi
            vks_json=$(jq -n --arg ns "${ns_name}" --arg prefix "${org_name}-vks-" --arg storagename "${storage_class_k8s_name}" --argjson osconfig "${os_configuration_json}" \
              '{apiVersion: "cluster.x-k8s.io/v1beta2", kind: "Cluster",
                metadata: {generateName: $prefix, namespace: $ns},
                spec: {
                  clusterNetwork: {serviceDomain: "cluster.local", pods: {cidrBlocks: ["192.168.156.0/20"]}, services: {cidrBlocks: ["10.96.0.0/12"]}},
                  topology: {
                    classRef: {name: "builtin-generic-v3.7.0", namespace: "vmware-system-vks-public"},
                    version: "v1.35.5+vmware.1",
                    controlPlane: {replicas: 1},
                    workers: {machineDeployments: [{class: "node-pool", name: "node-pool-1", replicas: 1}]},
                    variables: ([
                      {name: "vmClass", value: "best-effort-medium"},
                      {name: "storageClass", value: $storagename}
                    ] + (if $osconfig == null then [] else [$osconfig] end))
                  }
                }}')
            #
            # Retry a few times - confirmed live (org-20 of 20, all
            # created back-to-back) this can fail with the Supervisor's
            # own CAPI validating webhook refusing the connection
            # ("dial tcp ...:443: connect: connection refused"), most
            # likely the webhook pod briefly restarting/overloaded under
            # the load of creating many clusters in quick succession.
            # Safe to retry - a connection-refused at the admission-
            # webhook stage means the request never reached the point of
            # actually creating the object, so no duplicate-creation risk.
            #
            vks_create_ok=1
            # Calm gate: the platform must answer quickly before one more cluster is started
            vks_calm_gate_wait "${ns_endpoint}" "${ns_name}" "${org_token}"
            for vks_create_attempt in $(seq 1 5); do
              if ns_k8s_api POST "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters" "${vks_json}" "${org_token}"; then
                vks_create_ok=0
                break
              fi
              sleep 20
            done
            if [ ${vks_create_ok} -ne 0 ]; then
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster creation for ${org_name} FAILED after retries, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
            else
              vks_name=$(echo ${response_body} | jq -c -r '.metadata.name')
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} created, waiting for it to become Available before the next org is touched" "${log_file}" "" ""
            fi
          fi
        fi
      fi
    fi

    # One org at a time: wait for THIS org's cluster to be Available and finish its steps before the next org is touched.
    if [ -n "$item" ] && [ "$item" != "null" ] && [ "${vks_enabled:-false}" == "true" ] && [ "${vks_sequential:-true}" == "true" ]; then
      vks_filter_org="${org_name}"
      vks_finish_pass
      vks_filter_org=""
      sleep "${vks_pause_between_orgs_sec:-20}"
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

  #
  # Catch-up pass: finishes the orgs whose VKS cluster was not Available when loop 1 handled them (or all of them with
  # vks_sequential=false). Orgs already finished (vks_done_orgs) are skipped.
  #
  vks_filter_org=""
  vks_finish_pass
fi

#
# Blueprints (org-portal phase) - idempotent, one independent copy
# uploaded+released per org with blueprints.enabled, from every
# *.yaml.template file in the bootstrap repo's own blueprints/ dir (a
# dedicated folder there, deliberately separate from yamls/ - that one's
# entries are k8s-shaped manifests dispatched by .kind in
# gw-setup.sh.tpl; these are Aria Automation Cloud Template YAML, a
# different schema with no .kind field at all). Unrelated to
# namespace/vks_cluster gating - blueprints are a plain Aria Automation
# Cloud Template concept, no Avi/segName dependency.
#
# NOT cross-org shared (confirmed live: organizationSharings requires a
# rights-bundle right that, even granted, still didn't clear the "does
# not have required privileges to share catalog items" error - root
# cause not found yet). Each enabled org gets its own separate upload.
#
# ${avi_subdomain} in each template is deliberately substituted with
# THIS ORG'S OWN NAME, not the deployment's actual avi_subdomain value -
# substituting the real (single, deployment-wide) avi_subdomain would
# give every org's copy of a blueprint the exact same FQDN (e.g.
# app.alb.vcf9.lab for org-1 AND org-2 alike), a real routing conflict
# once more than one org has the same blueprint deployed. Using the org
# name instead keeps every org's instance unique (app.org-1.vcf9.lab,
# app.org-2.vcf9.lab, ...) with no extra CR field needed. domain is
# still the real, shared domain value - no per-org conflict there.
# Substitution happens HERE, not in gw-setup.sh.tpl, because that file
# is itself rendered through userdata.py's own ${name} Python templating
# before it ever reaches gw - any ${avi_subdomain}/${domain}/org_name
# placeholder text put there gets consumed by THAT pass instead of
# surviving to run as a real sed command. vcf_bootstrap.sh has no such
# pass (delivered verbatim via git clone), so ${domain} below is a
# genuine, already-set bash variable (same one used elsewhere in this
# script, e.g. the Avi DNS profile step above) - safe to substitute
# with here, and ${org_name} is this loop's own per-iteration variable.
#
blueprints_src_dir="/home/ubuntu/dev-avi-vcf/blueprints"
if [ ! -d "${blueprints_src_dir}" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${blueprints_src_dir} does not exist, skipping all blueprint provisioning" "${log_file}" "" ""
else
  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
      blueprints_enabled=$(echo ${item} | jq -c -r '.blueprints.enabled // false')
      if [ "${blueprints_enabled}" != "true" ]; then
        continue
      fi

      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
      org_uuid="${org_id##*:}"
      org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
        -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${vcfa_token}" \
        --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
      if [ -z "${org_token}" ] || [ "${org_token}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to obtain an org-scoped token for ${org_name}, skipping its blueprints" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      blueprint_api GET "project-service/api/projects" "" "${org_token}"
      project_id=$(echo ${response_body} | jq -c -r '.content[0].id')
      if [ -z "${project_id}" ] || [ "${project_id}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no VCF-A project found for ${org_name}, skipping its blueprints" "${log_file}" "${slack_webhook}" "${google_webhook}"
        continue
      fi

      for bp_file in "${blueprints_src_dir}"/*.yaml.template; do
        [ -e "${bp_file}" ] || continue
        bp_name=$(basename "${bp_file}" .yaml.template)

        blueprint_api GET "blueprint/api/blueprints" "" "${org_token}"
        bp_id=$(echo ${response_body} | jq -c -r --arg arg "${bp_name}" '.content[] | select(.name == $arg) | .id')
        if [ -n "${bp_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: blueprint ${bp_name} already exists for ${org_name}, skipping creation" "${log_file}" "" ""
          continue
        fi

        bp_content=$(sed -e "s@\${avi_subdomain}@${org_name}@g" -e "s/\${domain}/${domain}/g" "${bp_file}")
        bp_json=$(jq -n --arg n "${bp_name}" --arg pid "${project_id}" --arg content "${bp_content}" \
          '{name: $n, description: null, valid: true, content: $content, projectId: $pid, requestScopeOrg: true, iconId: null}')
        blueprint_api POST "blueprint/api/blueprints?apiVersion=2020-08-25" "${bp_json}" "${org_token}"
        bp_id=$(echo ${response_body} | jq -c -r '.id')
        if [ -z "${bp_id}" ] || [ "${bp_id}" == "null" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to create blueprint ${bp_name} for ${org_name}, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi

        # Confirmed live: the release step can transiently 500 on an
        # unrelated internal VCFA microservice call
        # (provisioning-service -> tenant-manager over the internal
        # service mesh, "failure when writing TLS control frames") that
        # has nothing to do with this payload - a plain retry a few
        # seconds later succeeds cleanly every time observed. The
        # blueprint draft itself (bp_id above) is unaffected either way.
        rel_json='{"version":"1","description":"initial release","changeLog":"initial release","release":true}'
        released=false
        for rel_attempt in 1 2 3; do
          if blueprint_api POST "blueprint/api/blueprints/${bp_id}/versions" "${rel_json}" "${org_token}"; then
            released=true
            break
          fi
          sleep 10
        done
        if [ "${released}" == "true" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: blueprint ${bp_name} created and released for ${org_name}" "${log_file}" "" ""
        else
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: blueprint ${bp_name} created but release FAILED for ${org_name} after retries, response was: ${response_body}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        fi
      done
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])
fi

#
# Per-org accounts (vCenter SSO + Avi tenant-admin, plus Harbor) - the last thing this script does, since they depend on
# resources created earlier in the pipeline: each org's Supervisor
# Namespace (namespace-provisioning loop above, this script) and Avi
# tenant (auto-created by vcfa_provider_bootstrap.sh's own
# PROVIDER_MANAGED Avi enablement, which runs before this script). Folds
# in what used to be the standalone scripts/avi-accounts.sh phase (same
# "one account per VCF-A org" concept, and this is exactly where its
# tenant-existence dependency is already guaranteed without a separate
# poll/ordering step), and replaces vcenter-bootstrap.sh's old single shared
# "readonly" SSO account. NSX is NOT per org: NSX Manager caps its local node users (error 36159 at the 11th), so
# nsx-bootstrap.sh creates ONE shared read-only user and gw-org-api.sh hands it out.
#
# Both old shared accounts are gone because neither scoped the way their
# name implied: confirmed live 2026-09-28 against the sddc reference
# environment that a vCenter-root ReadOnly grant, even propagated, makes
# every org's namespace VMs/pods visible to that one account - there's no
# way to give it visibility into just one org's namespace. Per-org
# accounts below fix that by scoping each vCenter one to its own
# namespace only. (NSX is not per org at all, see above.)
#
# Password for ALL the account types below is deliberately the SAME
# derivation as gw-accounts.sh's own Linux accounts ("VMware1!" + 4 hex
# chars from sha256(gw_accounts_secret + org_name) + "VMware1!", 20 chars
# total - see that script's own comment for why this exact shape) - one
# login/password per org across gw SSH, Avi, vCenter SSO, and NSX alike,
# all independent of generic_password.
#
sso_domain="$(jq -c -r .sddc.vcenter.ssoDomain "${jsonFile}")"
export GOVC_URL="${basename_sddc}-vc01.${domain}"
export GOVC_USERNAME="administrator@${sso_domain}"
export GOVC_PASSWORD="${generic_password}"
export GOVC_INSECURE=true
export GOVC_PERSIST_SESSION=false
unset GOVC_CLUSTER

# ip_avi is never a persisted bash/variables.sh export (confirmed live
# 2026-09-29: it was empty here, causing avi_login to fail outright with
# "Avi csrftoken is undefined after login") - every script that needs it
# derives it locally from the plural ips_avi array instead, same as
# avi-bootstrap.sh's own identical line.
ip_avi=$(echo ${ips_avi} | jq -r '.[0]')
avi_login
avi_api 3 3 GET "" "api/role?name=Tenant-Admin"
tenant_admin_role_ref=$(echo ${response_body} | jq -c -r '.results[0].url')
if [ -z "${tenant_admin_role_ref}" ] || [ "${tenant_admin_role_ref}" == "null" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Avi role 'Tenant-Admin' not found, skipping all per-org Avi account creation" "${log_file}" "${slack_webhook}" "${google_webhook}"
fi

# Full namespace inventory, fetched once - the "siblings to NoAccess" list
# built per org below is every OTHER entry here, including the system/
# svc-* namespaces WCP itself creates (auto-attach, cci-ns, configuration,
# metrics-aggregator, velero, tkg, ...), not just other orgs' own.
create_vcenter_api_session
vcenter_api 3 3 GET "api/vcenter/namespaces/instances" ""
all_namespaces=$(echo ${response_body} | jq -c -r '.[].namespace')

vm_ns_root="/${basename_sddc}-dc/vm/Namespaces"
pool_ns_root="/${basename_sddc}-dc/host/${basename_sddc}-cluster/Resources/Namespaces"

if [ -z "${client_id}" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: automation relying party clientId not resolved earlier, skipping all per-org accounts" "${log_file}" "${slack_webhook}" "${google_webhook}"
else
  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
      # Must stay byte-for-byte identical to gw-accounts.sh's own
      # derivation of the same formula (see that script's comment for
      # why it's this exact shape - VMware1! prefix/suffix bookending a
      # 4-hex-char segment, confirmed live 2026-09-28 as the only length/
      # character-class combination that satisfies vCenter's undocumented
      # 20-char password-length MAXIMUM, VCFA's own minimum-complexity
      # policy, and NSX's, all at once).
      org_password="VMware1!$(echo -n "${gw_accounts_secret}${org_name}" | sha256sum | cut -c1-4)VMware1!"

      #
      # vCenter SSO account - re-synced (not just created-once) every run,
      # same rationale as gw-accounts.sh: a rotated gw_accounts_secret (or
      # a manual re-run) should always converge the password, not only at
      # first creation.
      #
      if govc sso.user.ls 2>/dev/null | awk '{print $1}' | grep -qx "${org_name}"; then
        user_error=$(govc sso.user.update -p "${org_password}" "${org_name}" 2>&1)
        user_rc=$?
        account_action="password re-synced"
      else
        user_error=$(govc sso.user.create -p "${org_password}" "${org_name}" 2>&1)
        user_rc=$?
        account_action="created"
      fi
      # A re-run sets the same derived password again, which vCenter refuses as a reuse: the account already has it.
      if [ ${user_rc} -ne 0 ] && [ "${account_action}" == "password re-synced" ] && echo "${user_error}" | grep -q "PWD_HISTORY_RESTRICTION"; then
        user_rc=0
        account_action="password already current"
      fi
      if [ ${user_rc} -ne 0 ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vCenter SSO account ${org_name}@${sso_domain} FAILED (${account_action}): ${user_error}" "${log_file}" "${slack_webhook}" "${google_webhook}"
      else
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vCenter SSO account ${org_name}@${sso_domain} ${account_action}" "${log_file}" "" ""
      fi

      #
      # Namespace access scoping - re-derive this org's own ns_name fresh
      # (same GET-by-name approach as the namespace-provisioning loop
      # above; bash doesn't carry state across separate while-read loops).
      #
      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
      org_uuid="${org_id##*:}"
      org_token=$(curl -sk -X POST "${VCFA_HOST}/oidc/oauth2/token" \
        -H "$ACCEPT" -H "x-vmware-vcloud-tenant-context: ${org_uuid}" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "scope=openid profile email phone groups vcd_idp" \
        --data-urlencode "assertion=${vcfa_token}" \
        --data-urlencode "client_id=${client_id}" | jq -r '.access_token')
      if [ -z "${org_token}" ] || [ "${org_token}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to obtain an org-scoped token for ${org_name}, skipping its vCenter namespace access grant" "${log_file}" "${slack_webhook}" "${google_webhook}"
      else
        project="default-project"
        cci_api GET "apis/infrastructure.cci.vmware.com/v1alpha3/namespaces/${project}/supervisornamespaces" "" "${org_token}"
        ns_name=$(echo ${response_body} | jq -c -r --arg arg "${org_name}-ns-" '.items[] | select(.metadata.name | startswith($arg)) | .metadata.name' | head -1)
        if [ -z "${ns_name}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no namespace found for ${org_name}, skipping its vCenter namespace access grant" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          principal="${org_name}@${sso_domain}"

          # Entry gates down to this org's own namespace - propagate=false
          # so they don't themselves cascade full visibility into every
          # sibling the way a propagating grant here would.
          govc permissions.set -principal "${principal}" -role ReadOnly -propagate=true "${vm_ns_root}"
          govc permissions.set -principal "${principal}" -role ReadOnly -propagate=false "${vm_ns_root}/${supervisor_name}"
          govc permissions.set -principal "${principal}" -role ReadOnly -propagate=true "${vm_ns_root}/${supervisor_name}/${ns_name}"
          govc permissions.set -principal "${principal}" -role ReadOnly -propagate=false "${pool_ns_root}"
          govc permissions.set -principal "${principal}" -role ReadOnly -propagate=true "${pool_ns_root}/${ns_name}"

          # Explicit deny on every OTHER namespace - the part that actually
          # enforces exclusivity. Confirmed live 2026-09-28: WCP's own
          # Namespace/ResourcePool objects reveal every sibling namespace
          # to a principal once it has ANY grant in the parent tree above
          # (unlike normal vSphere folder permissions) - a missing grant
          # alone does not hide them, only an explicit NoAccess does.
          noaccess_failures=0
          while read -r sibling_ns; do
            if [ -n "${sibling_ns}" ] && [ "${sibling_ns}" != "${ns_name}" ]; then
              govc permissions.set -principal "${principal}" -role NoAccess -propagate=true "${vm_ns_root}/${supervisor_name}/${sibling_ns}" || ((noaccess_failures++))
              govc permissions.set -principal "${principal}" -role NoAccess -propagate=true "${pool_ns_root}/${sibling_ns}" || ((noaccess_failures++))
            fi
          done <<< "${all_namespaces}"
          if [ ${noaccess_failures} -gt 0 ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${noaccess_failures} NoAccess grant(s) failed for ${principal} while scoping sibling namespaces" "${log_file}" "${slack_webhook}" "${google_webhook}"
          fi
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vCenter account ${principal} scoped to namespace ${ns_name} only (ReadOnly on its own tree, NoAccess on every sibling)" "${log_file}" "" ""
        fi
      fi

      #
      # Avi tenant-admin account - ported from the now-removed
      # scripts/avi-accounts.sh, reusing the same org_password derived
      # above. A missing tenant only skips THIS org's Avi account, never
      # aborts the rest - not every org necessarily has a PROVIDER_MANAGED
      # Avi tenant (see avi_mode in the namespace-provisioning loop above).
      #
      if [ -n "${tenant_admin_role_ref}" ] && [ "${tenant_admin_role_ref}" != "null" ]; then
        avi_api 3 3 GET "" "api/tenant?name=${org_name}"
        tenant_ref=$(echo ${response_body} | jq -c -r '.results[0].url')
        if [ -z "${tenant_ref}" ] || [ "${tenant_ref}" == "null" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Avi tenant ${org_name} not found (enable_avi/avi_mode PROVIDER_MANAGED not set for this org?), skipping its Avi account" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          avi_api 3 3 GET "" "api/user?name=${org_name}"
          existing_count=$(echo ${response_body} | jq -c -r '.count')
          if [ "${existing_count}" != "0" ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Avi user ${org_name} already exists, skipping creation" "${log_file}" "" ""
          else
            user_json=$(jq -n --arg u "${org_name}" --arg p "${org_password}" --arg t "${tenant_ref}" --arg r "${tenant_admin_role_ref}" \
              '{username: $u, password: $p, is_superuser: false, default_tenant_ref: $t, access: [{tenant_ref: $t, role_ref: $r}]}')
            avi_api 3 3 POST "${user_json}" "api/user"
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Avi user ${org_name} created (Tenant-Admin, tenant ${org_name})" "${log_file}" "" ""
          fi
        fi
      fi

      #
      # Harbor per-org read-only user (only when Harbor is deployed, see supervisor-bootstrap.sh): a local db_auth user named
      # after the org, same password as every other org account, member of the projects as "guest" (role_id 3: pull/browse,
      # no push). The role is checked by NAME before it is granted, so another Harbor release can never silently hand out a
      # writing role. Soft-fails: a problem only logs a warning, never aborts the other orgs.
      #
      if echo "${supervisor_services}" | jq -e 'any(.[]; .type == "harbor" and .enabled != false)' > /dev/null 2>&1; then
        harbor_url="https://harbor.${avi_subdomain}.${domain}"
        harbor_curl() { curl -sk -m 30 -u "admin:${generic_password}" -H 'Content-Type: application/json' "$@"; }
        harbor_mode=$(harbor_curl "${harbor_url}/api/v2.0/systeminfo" | jq -r '.auth_mode // empty')
        if [ "${harbor_mode}" != "db_auth" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: WARNING: Harbor not reachable or auth_mode '${harbor_mode}' is not db_auth, skipping Harbor user ${org_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          harbor_user_id=$(harbor_curl "${harbor_url}/api/v2.0/users/search?username=${org_name}" | jq -r --arg u "${org_name}" '[.[] | select(.username == $u)][0].user_id // empty')
          if [ -z "${harbor_user_id}" ]; then
            harbor_curl -X POST "${harbor_url}/api/v2.0/users" \
              -d "$(jq -n --arg u "${org_name}" --arg p "${org_password}" '{username: $u, email: ($u + "@students.local"), realname: $u, password: $p}')" -o /dev/null
            harbor_user_id=$(harbor_curl "${harbor_url}/api/v2.0/users/search?username=${org_name}" | jq -r --arg u "${org_name}" '[.[] | select(.username == $u)][0].user_id // empty')
          else
            # admin password reset keeps a rerun in line with the current org password
            harbor_curl -X PUT "${harbor_url}/api/v2.0/users/${harbor_user_id}/password" \
              -d "$(jq -n --arg p "${org_password}" '{new_password: $p}')" -o /dev/null
          fi
          if [ -z "${harbor_user_id}" ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: WARNING: Harbor user ${org_name} could not be created" "${log_file}" "${slack_webhook}" "${google_webhook}"
          else
            harbor_guest_ok="true"
            for harbor_project in registry library; do
              harbor_code=$(harbor_curl -X POST "${harbor_url}/api/v2.0/projects/${harbor_project}/members" -o /dev/null -w '%{http_code}' \
                -d "$(jq -n --arg u "${org_name}" '{role_id: 3, member_user: {username: $u}}')")
              case "${harbor_code}" in 201|409) ;; 404) ;; *) harbor_guest_ok="false" ;; esac
              harbor_role=$(harbor_curl "${harbor_url}/api/v2.0/projects/${harbor_project}/members?entityname=${org_name}" | jq -r --arg u "${org_name}" '[.[] | select(.entity_name == $u)][0].role_name // empty')
              if [ -n "${harbor_role}" ] && [ "${harbor_role}" != "guest" ]; then
                harbor_guest_ok="false"
                log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: WARNING: Harbor user ${org_name} has role '${harbor_role}' on ${harbor_project}, expected guest" "${log_file}" "${slack_webhook}" "${google_webhook}"
              fi
            done
            if [ "${harbor_guest_ok}" == "true" ]; then
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Harbor user ${org_name} ready (guest on registry and library, read-only)" "${log_file}" "" ""
            fi
          fi
        fi
      fi
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])
fi
unset GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE GOVC_PERSIST_SESSION

# vApp use case (up to 18 orgs on 2 Avi SEs): a cron that keeps every org's virtual services on one SE and removes idle SEs
# (enforce-vs-placement.sh, every 5 minutes; --install-cron replaces its own entry, so a rerun or vcfa_org.sh add is harmless). Not for sddc.
if [ "${deployment_kind}" == "vApp" ]; then
  bash "${script_dir}/enforce-vs-placement.sh" "${jsonFile}" --install-cron
fi

log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: End of ${0%.*}.sh" "${log_file}" "${slack_webhook}" "${google_webhook}"
touch "${resultFile}"
