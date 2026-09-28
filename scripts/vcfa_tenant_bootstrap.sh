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

        retry_ns=12 ; pause_ns=15 ; attempt_ns=1
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
        org_yaml_folder="/home/${org_name}/${yaml_folder}"

        # org_yaml_folder is owned by ${org_name} now (handed off at the
        # end of the rendering loop in vcfa_provider_bootstrap.sh), not
        # ubuntu - these reads need sudo. The /tmp/*.yaml copies below are
        # ubuntu-owned as usual, so the yq -i edits on those don't need it.
        secret_kind="$(sudo yq '.kind' ${org_yaml_folder}/secret_vault.yaml)"
        secret_name="$(sudo yq '.metadata.name' ${org_yaml_folder}/secret_vault.yaml)"
        issuer_kind="$(sudo yq '.kind' ${org_yaml_folder}/vault_issuer.yaml)"
        if [ "${secret_kind}" != "Secret" ] || [ "${secret_name}" != "cert-manager-vault-token" ] || [ "${issuer_kind}" != "Issuer" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: secret_vault.yaml/vault_issuer.yaml have unexpected kind/name (secret_kind=${secret_kind}, secret_name=${secret_name}, issuer_kind=${issuer_kind}), skipping vault bootstrap for ${org_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          sudo cp ${org_yaml_folder}/secret_vault.yaml "/tmp/${org_name}-secret_vault.yaml"
          sudo chown ubuntu:ubuntu "/tmp/${org_name}-secret_vault.yaml"
          yq -i ".metadata.namespace = \"${ns_name}\"" "/tmp/${org_name}-secret_vault.yaml"
          yq -i ".data.token = \"$(echo -n $(jq -c -r .root_token ${vault_secret_file_path}) | base64)\"" "/tmp/${org_name}-secret_vault.yaml"

          sudo cp ${org_yaml_folder}/vault_issuer.yaml "/tmp/${org_name}-vault_issuer.yaml"
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
      # Idempotency is by PRESENCE, not name (the API only supports
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
            vks_json=$(jq -n --arg ns "${ns_name}" --arg storagename "${storage_class_k8s_name}" --argjson osconfig "${os_configuration_json}" \
              '{apiVersion: "cluster.x-k8s.io/v1beta2", kind: "Cluster",
                metadata: {generateName: "vks-cluster-", namespace: $ns},
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
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VKS cluster ${vks_name} for ${org_name} created, will check Available status in a later pass (see below) once every org's cluster has been created" "${log_file}" "" ""
            fi
          fi
        fi
      fi
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

  #
  # VKS cluster status polling - a SEPARATE pass, run only after every
  # org's cluster has already been created above. Deliberately decoupled
  # from creation so N clusters bootstrap in parallel server-side, rather
  # than this script blocking org 1's several-minutes-long node bootstrap
  # before even starting org 2's cluster creation.
  #
  # Terminates on status.conditions[] type=="Available" status=="True" -
  # confirmed live this is CAPI's own top-level cluster-wide readiness
  # signal (control plane + all workers healthy), NOT the same as
  # phase=="Provisioned" (only means the topology/infra request was
  # accepted - observed within seconds of creation while nodes were
  # still booting, long before Available flips true).
  #
  # Re-derives org token/namespace/cluster name from scratch per org
  # rather than reusing anything from the creation loop above, since bash
  # doesn't carry per-iteration loop state across two separate while-read
  # loops - same GET-by-name approach used throughout this script.
  #
  while read item
  do
    if [ -n "$item" ] && [ "$item" != "null" ]; then
      org_name=$(echo ${item} | jq -c -r '.name')
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

      retry_vks=40 ; pause_vks=30 ; attempt_vks=1
      while true
      do
        ns_k8s_api GET "${ns_endpoint}" "apis/cluster.x-k8s.io/v1beta2/namespaces/${ns_name}/clusters/${vks_name}" "" "${org_token}"
        vks_available=$(echo ${response_body} | jq -c -r '.status.conditions[]? | select(.type=="Available") | .status')
        #
        # This loop can silently wait up to retry_vks*pause_vks (20
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
            kubectl --kubeconfig="${vks_kubeconfig}" label --overwrite ns default pod-security.kubernetes.io/enforce=privileged
            if [ $? -eq 0 ]; then
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
            # Hand this same admin kubeconfig to the org's own account
            # (see gw-accounts.sh) so its SSH login has a fully-ready
            # `kubectl` against its own VKS cluster with no extra
            # context-selection step. It's a plain client-cert kubeconfig
            # (not a Pinniped/OIDC exec plugin), so a static copy works
            # standalone. Unconditional overwrite on every run - stable
            # content across reruns for the same cluster, no idempotency
            # check needed.
            #
            org_kube_dir="/home/${org_name}/.kube"
            sudo mkdir -p "${org_kube_dir}"
            sudo cp "${vks_kubeconfig}" "${org_kube_dir}/config"
            sudo chown -R "${org_name}:${org_name}" "${org_kube_dir}"
            sudo chmod 700 "${org_kube_dir}"
            sudo chmod 600 "${org_kube_dir}/config"
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: kubeconfig for VKS cluster ${vks_name} copied to /home/${org_name}/.kube/config" "${log_file}" "" ""
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
# Per-org accounts (vCenter SSO + Avi tenant-admin) - the last thing this
# script does, since both depend on resources created earlier in the
# pipeline: each org's Supervisor Namespace (namespace-provisioning loop
# above, this script) and Avi tenant (auto-created by
# vcfa_provider_bootstrap.sh's own PROVIDER_MANAGED Avi enablement, which
# runs before this script). Folds in what used to be the standalone
# scripts/avi-accounts.sh phase (same "one account per VCF-A org" concept,
# and this is exactly where its tenant-existence dependency is already
# guaranteed without a separate poll/ordering step) and replaces
# vcenter-bootstrap.sh's old single shared "readonly" SSO account.
#
# That single shared account is gone because it doesn't scope the way its
# name implies: confirmed live 2026-09-28 against the sddc reference
# environment that a vCenter-root ReadOnly grant, even propagated, makes
# every org's namespace VMs/pods visible to that one account - there's no
# way to give it visibility into just one org's namespace. Per-org accounts
# below fix that by scoping each one to its own namespace only.
#
# Password for BOTH account types below is deliberately the SAME
# derivation as gw-accounts.sh's own Linux accounts (sha256(gw_accounts_
# secret + org_name), truncated) - one login/password per org across gw
# SSH, Avi, and vCenter SSO alike, all independent of generic_password.
#
sso_domain="$(jq -c -r .sddc.vcenter.ssoDomain "${jsonFile}")"
export GOVC_URL="${basename_sddc}-vc01.${domain}"
export GOVC_USERNAME="administrator@${sso_domain}"
export GOVC_PASSWORD="${generic_password}"
export GOVC_INSECURE=true
export GOVC_PERSIST_SESSION=false
unset GOVC_CLUSTER

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
      org_password=$(echo -n "${gw_accounts_secret}${org_name}" | sha256sum | cut -c1-24)

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
    fi
  done < <(echo "${vcf_a_organizations}" | jq -c -r .[])
fi
unset GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE GOVC_PERSIST_SESSION

log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: End of ${0%.*}.sh" "${log_file}" "${slack_webhook}" "${google_webhook}"
touch "${resultFile}"
