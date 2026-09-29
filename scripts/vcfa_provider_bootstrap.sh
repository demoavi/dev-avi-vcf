#!/bin/bash
#
# VCFA org-provisioning phase of the VCD/vApp use case - "system/provider
# portal" half (regions, ipSpaces, providerGateways, orgs, VDCs, regional
# networking settings, org VM/content-library/blueprint-source setup, demo
# yaml rendering into each org's own home dir) ported from the reference
# project's vcf-automation/configure_vcfa.sh. Split from that single file
# into this script (provider-portal actions, everything a provider Bearer
# token can do) and its sibling vcfa_tenant_bootstrap.sh (org-portal
# actions - namespace/VKS/vault/blueprints/per-org-accounts, everything
# that needs an org-scoped OAuth token instead) on 2026-09-28, matching
# the natural boundary this file's own comments already drew between the
# two ("system/provider portal" vs "org-portal phase") - see that script's
# own header for what moved there and why. Runs first of the two (as
# "vcfa_provider_bootstrap" in vcf_bootstrap.sh's phase loop); every org
# resource it creates is server-side VCFA state the tenant script's own
# org-scoped API calls depend on already existing.
#
# Entirely optional - every step below is already a no-op if
# spec.sddc.vcf_a is unset (vcf_a_regions/vcf_a_provider_gws/
# vcf_a_organizations/vcf_a_content_libraries all default to "[]").
#
# Self-contained: independently sources variables.sh/functions.sh and
# re-derives every value below exactly like vcf_bootstrap.sh's own
# top-of-file block does, rather than relying on anything from that
# process's own environment - this runs as its own separate
# "bash vcfa_provider_bootstrap.sh" invocation, not sourced into
# vcf_bootstrap.sh's shell, and log_file is the one exception deliberately
# kept identical across every phase script (all append to the same
# /home/ubuntu/vcf_bootstrap.log so the whole pipeline reads as one
# continuous timeline).
#
# This project's variables.sh is a flat Python-rendered export list, not
# the reference project's live jq-parsing script, so vcf_a_regions/
# vcf_a_ip_spaces/vcf_a_provider_gws/vcf_a_organizations/
# vcf_a_content_libraries already come pre-computed from userdata.py's
# derive_vcf_a_organizations()/derive_vcf_a_ip_space_template() instead of
# being derived here from $jsonFile. default_storage_class is the only
# simple derived value needed here specifically, not a CR field.
# slack_webhook is left empty - this project only supports google_webhook
# notifications so far, and log_message below silently no-ops on an empty
# slack_url exactly like it does for google_url.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

log_file="/home/ubuntu/vcf_bootstrap.log"
touch "${log_file}"
slack_webhook=""
#
# Fixed constant, not a per-deployment value - never exported by
# bash/variables.sh (confirmed live 2026-09-24: ${yaml_folder} below
# was referencing a variable that flat-out doesn't exist anywhere in
# userdata.py, resolving empty). gw-setup.sh.tpl's own comment
# documents this same directory name ("/home/ubuntu/yaml-files/") for
# the demo-yaml rendering this project ported from.
#
yaml_folder="yaml-files"
#
# The per-cluster vSAN storage policy vSphere auto-generates is named
# after the vCenter CLUSTER ("${basename_sddc}-cluster"), not the
# Supervisor object's own name (supervisor_cluster_name, "sup-admin-01"
# on this deployment) - the two happened to be identical in the
# reference project's own environment (both "sddc01-cluster"), masking
# this exact bug there. Confirmed live: VCFA's region-creation POST
# 400'd with "sup-admin-01 vSAN Storage Policy" not accessible to any
# host, while the reference project's own captured api.log shows the
# real policy name as "sddc01-cluster vSAN Storage Policy" - same
# "${basename_sddc}-cluster" pattern already used for VC_CLUSTER in
# vcenter-bootstrap.sh and the cluster_id lookups in
# supervisor-bootstrap.sh/nsx-bootstrap.sh.
#
default_storage_class="${basename_sddc}-cluster vSAN Storage Policy"

log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vcfa_provider_bootstrap.sh started" "${log_file}" "${slack_webhook}" "${google_webhook}"

# fqdn_vcfa is also computed independently by vcf_bootstrap.sh itself
# (shared with the Supervisor auth helper scripts it renders) - duplicated
# here rather than passed through, since this runs as its own process.
fqdn_vcfa="${basename_sddc}-auto-vip.${domain}"

# bash/download_file.sh, inlined (not sourced - this project doesn't
# distribute that file to gw separately).
download_file_from_url_to_location () {
  local url=$1
  local download_location=$2
  local description=$3
  echo ""
  echo "==> Checking ${description} file"
  if [ -s "${download_location}" ]; then
    echo "   +++ ${description} file ${download_location} is not empty"
  else
    echo "   +++ Downloading ${description} file"
    response=$(curl -k -s --write-out "\n%{http_code}" -o ${download_location} ${url})
    response_code=$(tail -n1 <<< "$response")
    if [[ $response_code != 200 ]] ; then
      echo "   +++ HTTP URI does not look valid: ${url}"
      rm -f "${download_location}"
      exit 255
    else
      if [ -s "${download_location}" ]; then
        echo "   ++++++ ${description} file ${download_location} is not empty"
      else
        echo "   ++++++ ${description} file ${download_location} is empty"
        exit 255
      fi
    fi
  fi
}

VCFA_HOST="https://${fqdn_vcfa}"
VCFA_VERSION="9.1.0"
ACCEPT="Accept: application/json;version=${VCFA_VERSION}"
CONTENT_TYPE="Content-Type: application/json;version=${VCFA_VERSION}"

vcfa_login

#
# Refresh VCFA's view of the registered VCF instance (SDDC Manager)
# before doing anything else - confirmed live (2026-09-22) this is what
# actually populates VCFA's own inventory of newly-available components
# (Avi controller, Supervisor network stack) discovered through SDDC
# Manager, not something that happens automatically on its own. This is
# very likely the real fix for the region-creation 400 ("zones of the
# specified supervisors do not have a network stack configured ...
# ensure the supervisor inventory has been refreshed" - the error
# message is telling us exactly this) rather than merely waiting it out
# via retries. Also means the Avi controller is expected to already be
# discoverable here (avi-bootstrap.sh, several phases earlier, already
# fully deployed and configured it) - see the aviController check
# further down, which now only polls for this instead of ever creating
# one manually.
#
vcfa_api GET "cloudapi/1.0.0/vcfInfraEndpoints" ""
vcf_infra_endpoint_id=$(echo ${response_body} | jq -c -r '.values[0].id')
if [ -n "${vcf_infra_endpoint_id}" ] && [ "${vcf_infra_endpoint_id}" != "null" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: refreshing VCFA's view of VCF instance ${vcf_infra_endpoint_id}" "${log_file}" "" ""
  vcfa_api POST "cloudapi/1.0.0/vcfInfraEndpoints/${vcf_infra_endpoint_id}/refresh" ""
  sleep 60
fi

#
# Retrieve NSX Manager id and name
#
vcfa_api GET "cloudapi/v1/nsxManagers" ""
nsx_manager_id=$(echo ${response_body} | jq -c -r '.values[0].id')
nsx_manager_name=$(echo ${response_body} | jq -c -r '.values[0].name')

#
# Retrieve Supervisor id and name
#
vcfa_api GET "cloudapi/v1/supervisors" ""
supervisor_id=$(echo ${response_body} | jq -c -r '.values[0].supervisorId')
supervisor_name=$(echo ${response_body} | jq -c -r '.values[0].name')

#
# configure regions - idempotent. region/ipSpace/providerGateway are
# shared, provider-wide resources (all three already existed for org-1 on
# the vcf9 lab, so this exact block was validated separately end-to-end
# against a second VCD/VCFA environment instead - see the header notes
# above).
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    region_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/regions" ""
    existing_region_id=$(echo ${response_body} | jq -c -r --arg arg "${region_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${existing_region_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: region ${region_name} already exists, skipping" "${log_file}" "" ""
      continue
    fi
    region_json=$(jq -n --arg n "${region_name}" --arg nsxid "${nsx_manager_id}" --arg nsxname "${nsx_manager_name}" \
      --arg supid "${supervisor_id}" --arg supname "${supervisor_name}" --arg sc "${default_storage_class}" \
      '{name: $n, description: "", nsxManager: {name: $nsxname, id: $nsxid}, supervisors: [{name: $supname, id: $supid}], storagePolicies: [$sc]}')
    #
    # Confirmed live on 2026-09-21: right after supervisor-bootstrap.sh
    # reports the Supervisor ready, this POST can 400 with "the following
    # zones of the specified supervisors do not have a network stack
    # configured ... ensure ... the supervisor inventory has been
    # refreshed" - NSX hasn't finished syncing the Supervisor's own
    # network-stack inventory yet. vcfa_api's default retry budget (2
    # attempts, 5s apart) was never exercised against this race before
    # (this create path had only ever run against an already-existing
    # region until now) and is far too short for it. Every failure past
    # this point in the script cascades from region_id resolving empty,
    # so fail fast here with a clear message instead of continuing into
    # ten unrelated-looking downstream errors.
    if ! vcfa_api POST "cloudapi/v1/regions" "${region_json}" 20 30; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: region ${region_name} creation FAILED after extended retry, aborting" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit 100
    fi
  fi
done < <(echo "${vcf_a_regions}" | jq -c -r .[])

#
# Create external IP spaces - idempotent
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    ip_space_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/ipSpaces" ""
    existing_ip_space_id=$(echo ${response_body} | jq -c -r --arg arg "${ip_space_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${existing_ip_space_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ip space ${ip_space_name} already exists, skipping" "${log_file}" "" ""
      continue
    fi
    vcfa_api GET "cloudapi/v1/regions" ""
    region_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${item} | jq -c -r '.region_ref')" '.values[] | select(.name == $arg) | .id')
    ip_space_json=$(jq -n --arg n "${ip_space_name}" --arg cidr "$(echo ${item} | jq -c -r '.cidr')" --arg regionid "${region_id}" \
      '{name: $n, description: "", internalScopeCidrBlocks: [{cidr: $cidr}], ipAddressRanges: [], reservedIpAddressRanges: [],
        providerVisibilityOnly: false, defaultQuota: {maxSubnetSize: 1, maxCidrCount: -1, maxIpCount: -1}, regionRef: {id: $regionid}}')
    vcfa_api POST "cloudapi/v1/ipSpaces" "${ip_space_json}"
  fi
done < <(echo "${vcf_a_ip_spaces}" | jq -c -r .[])

#
# Create provider gateways - idempotent
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    pgw_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/providerGateways" ""
    existing_pgw_id=$(echo ${response_body} | jq -c -r --arg arg "${pgw_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${existing_pgw_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: provider gateway ${pgw_name} already exists, skipping" "${log_file}" "" ""
      continue
    fi
    vcfa_api GET "cloudapi/v1/regions" ""
    region_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${item} | jq -c -r '.region_ref')" '.values[] | select(.name == $arg) | .id')
    #
    # allowAdvertisingPrivateIpBlocks must be explicit (omitting it 500s
    # with a server NPE). `true` (an earlier fix, ported from a
    # single-org environment) is WRONG here - confirmed live 2026-09-22
    # it makes VCFA dedicate this provider gateway to a single org
    # (creates it with a real orgRef, e.g. org-1), so every other org
    # sharing the same provider_gateway_ref then 403s with "already
    # assigned to another organization". This CR has all 20 orgs sharing
    # one provider gateway (ext-connection1), so `false` is required -
    # but `false` alone then 400s: "requires either at least one
    # associated IP Space or private IP Blocks advertisement to be
    # enabled" (also confirmed live 2026-09-22). ip_spaces are already
    # created above, before provider gateways, so pass every existing
    # one's ref here to satisfy that requirement. This directly
    # contradicts an older comment here claiming ipSpaceRefs "reads back
    # null regardless of what's sent and does not actually associate
    # anything" - that observation was made back when
    # allowAdvertisingPrivateIpBlocks was true/omitted, which never
    # required ipSpaceRefs to be set at all; whether it persists or not,
    # the real, working association still happens via the separate POST
    # cloudapi/v1/ipSpaceAssociations step further below regardless.
    #
    vcfa_api GET "cloudapi/v1/ipSpaces" ""
    ip_space_refs_json=$(echo ${response_body} | jq -c '[.values[] | {id, name}]')
    pgw_json=$(jq -n --arg n "${pgw_name}" --arg t0 "$(echo ${item} | jq -c -r '.tier0_ref')" --arg regionid "${region_id}" --argjson ipsrefs "${ip_space_refs_json}" \
      '{name: $n, description: "", backingRef: {id: $t0, name: $t0}, backingType: "NSX_TIER0", regionRef: {id: $regionid}, allowAdvertisingPrivateIpBlocks: false, ipSpaceRefs: $ipsrefs}')
    if ! vcfa_api POST "cloudapi/v1/providerGateways" "${pgw_json}"; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: provider gateway ${pgw_name} creation FAILED, aborting" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit 100
    fi
    #
    # This exact POST (no natConfig, no explicit gatewayConnectionBackingId)
    # was confirmed live on a separate VCD/VCFA environment: 202 ->
    # REALIZED with no errors, VCFA auto-populates gatewayConnectionBackingId
    # from the gateway's own name. The original script's own captured error
    # ("Provider Gateway test-ui must be backed by a shared Gateway
    # Connection") did not reproduce here.
    #
    # Poll to REALIZED before moving on - confirmed live (2026-09-25)
    # the ipSpaceAssociations step further below can 403 "Provider
    # Gateway ... not found" even though this same POST already
    # returned success and the gateway shows up in a plain GET list -
    # the deeper single-object lookup used internally to validate an
    # association apparently isn't guaranteed ready the instant the
    # list reflects it. Every other resource in this script (regions,
    # content libraries, VKS clusters) already polls to a real terminal
    # status instead of trusting the initial POST response - this was
    # the one exception.
    #
    for attempt_pgw in $(seq 1 12); do
      vcfa_api GET "cloudapi/v1/providerGateways" ""
      pgw_status=$(echo ${response_body} | jq -c -r --arg arg "${pgw_name}" '.values[] | select(.name == $arg) | .status')
      if [ "${pgw_status}" == "REALIZED" ]; then
        break
      fi
      sleep 10
    done
    if [ "${pgw_status}" != "REALIZED" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: provider gateway ${pgw_name} not REALIZED after waiting (status=${pgw_status:-unknown}), aborting" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit 100
    fi
  fi
done < <(echo "${vcf_a_provider_gws}" | jq -c -r .[])

#
# Associate every ip_space with every provider gateway - idempotent.
# This, not the ipSpaceRefs field on providerGateways, is the real
# mechanism (confirmed live: ipSpaceRefs reads back null regardless of
# what's sent, and a gateway configured that way shows no association
# in the UI either). Deliberately full cross-product (every ip_space to
# every gateway) - only a valid simplification while there is a single
# provider gateway; a real ip_space-to-gateway mapping would be needed
# if a second gateway is ever introduced. Confirmed live (51-org x
# 20-VIP batch test) that once associated this way, VIP allocation
# pools cleanly across every associated ip_space in sequence as each
# one fills, with zero errors.
#
vcfa_api GET "cloudapi/v1/ipSpaces" ""
all_ip_spaces=$(echo ${response_body} | jq -c '[.values[] | {id, name}]')
vcfa_api GET "cloudapi/v1/providerGateways" ""
all_provider_gws=$(echo ${response_body} | jq -c '[.values[] | {id, name}]')

#
# Sentinel file, not `exit` inside the loops below - both while loops
# are the right-hand side of a pipe, so bash runs them in subshells; an
# `exit` inside one only terminates that subshell/iteration silently,
# it does NOT abort this script the way every other hard-failure check
# here does. Check the sentinel and exit for real once both loops (and
# their subshells) have actually finished.
#
rm -f /tmp/ipspace_association_failed
echo "${all_provider_gws}" | jq -c -r '.[]' | while read pgw
do
  pgw_id=$(echo ${pgw} | jq -c -r '.id')
  pgw_name=$(echo ${pgw} | jq -c -r '.name')
  echo "${all_ip_spaces}" | jq -c -r '.[]' | while read ipspace
  do
    ipspace_id=$(echo ${ipspace} | jq -c -r '.id')
    ipspace_name=$(echo ${ipspace} | jq -c -r '.name')
    #
    # This endpoint requires a filter param (confirmed live: an
    # unfiltered GET 400s "must contain the filter 'ipSpaceRef.id or
    # distributedVxlanConnectionRef.id or providerGatewayRef.id'").
    # Filter server-side by providerGatewayRef.id alone (a single-field
    # filter, avoiding the compound ";"-AND form used here previously,
    # which did not reliably match - confirmed live it returned empty
    # for an association that demonstrably already existed, causing a
    # redundant POST that then 400'd "already exists"), then narrow to
    # the specific ip_space client-side via jq.
    #
    vcfa_api GET "cloudapi/v1/ipSpaceAssociations?filter=providerGatewayRef.id==${pgw_id}" ""
    existing_assoc=$(echo ${response_body} | jq -c -r --arg ipsid "${ipspace_id}" --arg pgwid "${pgw_id}" \
      '.values[] | select(.ipSpaceRef.id == $ipsid and .providerGatewayRef.id == $pgwid) | .id' | head -1)
    if [ -n "${existing_assoc}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${ipspace_name} already associated with ${pgw_name}, skipping" "${log_file}" "" ""
      continue
    fi
    assoc_json=$(jq -n --arg pgwid "${pgw_id}" --arg pgwname "${pgw_name}" --arg ipsid "${ipspace_id}" --arg ipsname "${ipspace_name}" \
      '{providerGatewayRef: {id: $pgwid, name: $pgwname}, ipSpaceRef: {id: $ipsid, name: $ipsname}}')
    #
    # Belt-and-suspenders: if the pre-check above still missed an
    # already-existing association for any reason, treat the server's
    # own "already exists" response as success rather than a hard
    # failure - the desired end state (associated) is already true.
    #
    if ! vcfa_api POST "cloudapi/v1/ipSpaceAssociations" "${assoc_json}"; then
      if echo "${response_body}" | grep -qi "already exists"; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${ipspace_name} association with ${pgw_name} already existed (server-reported), continuing" "${log_file}" "" ""
      else
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to associate ${ipspace_name} with ${pgw_name}, aborting" "${log_file}" "${slack_webhook}" "${google_webhook}"
        touch /tmp/ipspace_association_failed
      fi
    fi
  done
done
if [ -f /tmp/ipspace_association_failed ]; then
  rm -f /tmp/ipspace_association_failed
  exit 100
fi

#
# Create content libraries - idempotent. Shared, provider-wide resource
# like region/ipSpace/providerGateway above (NOT nested per-org) -
# confirmed live that a content library created here (system/provider
# portal, libraryType: PROVIDER) is visible from every org's own portal
# by default (isShared: true, isProjectScoped: false out of the box, no
# per-org share/attach step needed) - one library serves every org.
#
# storage class is looked up via cloudapi/v1/storageClasses, NOT
# cloudapi/v1/regionStoragePolicies (used elsewhere in this script for
# vDC storage policy assignment) - confirmed live both endpoints return
# the same underlying policy (identical UUID) but under different URN
# type prefixes (storageClass vs regionStoragePolicy), and contentLibraries
# creation specifically rejects the regionStoragePolicy-typed id ("The
# VCF Automation Tenant Manager entity urn:vcloud:storageClass:X does not
# exist" - note it silently re-typed the id in its own error message).
#
# status starts NOT_READY and reaches READY after ~30s with no explicit
# sync/action needed (unlike edgeClusters/aviControllers above) - this is
# just eventual consistency, confirmed live by polling.
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    cl_name=$(echo ${item} | jq -c -r '.name')
    vcfa_api GET "cloudapi/v1/contentLibraries" ""
    cl_id=$(echo ${response_body} | jq -c -r --arg arg "${cl_name}" '.values[] | select(.name == $arg) | .id')
    if [ -n "${cl_id}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library ${cl_name} already exists, skipping creation" "${log_file}" "" ""
    else
      vcfa_api GET "cloudapi/v1/storageClasses" ""
      storage_class_id=$(echo ${response_body} | jq -c -r --arg arg "${default_storage_class}" '.values[] | select(.name == $arg) | .id')
      cl_json=$(jq -n --arg n "${cl_name}" --arg scid "${storage_class_id}" \
        '{name: $n, storageClasses: [{id: $scid}]}')
      vcfa_api POST "cloudapi/v1/contentLibraries" "${cl_json}"

      retry_cl=6 ; pause_cl=10 ; attempt_cl=1
      while true
      do
        sleep ${pause_cl}
        vcfa_api GET "cloudapi/v1/contentLibraries" ""
        cl_status=$(echo ${response_body} | jq -c -r --arg arg "${cl_name}" '.values[] | select(.name == $arg) | .status')
        if [[ "${cl_status}" == "READY" ]]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library ${cl_name} READY after ${attempt_cl} attempts of ${pause_cl} seconds" "${log_file}" "" ""
          break
        fi
        ((attempt_cl++))
        if [ ${attempt_cl} -eq ${retry_cl} ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library ${cl_name} not READY after ${attempt_cl} attempts of ${pause_cl} seconds (status=${cl_status})" "${log_file}" "${slack_webhook}" "${google_webhook}"
          break
        fi
      done
      vcfa_api GET "cloudapi/v1/contentLibraries" ""
      cl_id=$(echo ${response_body} | jq -c -r --arg arg "${cl_name}" '.values[] | select(.name == $arg) | .id')
    fi

    #
    # Content library items (OVAs) - idempotent per item, independent of
    # whether the library itself was just created or already existed
    # (previously this whole item step was unreachable on re-runs because
    # the library-exists branch used `continue` - fixed here).
    #
    # Exactly one of ova_url (sddc/vCenter use case)/name (vApp/VCD use
    # case) per item - see crd-vapp.yaml's own description. Either way,
    # once ova_file exists locally it's extracted (a .ova is a plain tar
    # archive) and its .ovf descriptor's bytes PUT to the transferUrl VCFA
    # hands back. Confirmed live end-to-end with a real multi-file OVA
    # (lab-web-test-base-2.8.ova: .ovf + .vmdk + .nvram, 40MB): PUT the
    # descriptor -> re-GET files -> server lists the .vmdk AND .nvram (by
    # their real original filenames, matched against the extracted
    # directory here) with their own transferUrls -> PUT each -> item
    # reaches status READY with a real imageIdentifier assigned. The .mf
    # manifest is never listed for separate upload. A deliberately-invalid
    # descriptor was also confirmed to correctly surface as status FAILED
    # rather than silently succeed.
    #
    while read cl_item
    do
      if [ -n "${cl_item}" ] && [ "${cl_item}" != "null" ]; then
        ova_url=$(echo ${cl_item} | jq -c -r '.ova_url // empty')
        ova_name=$(echo ${cl_item} | jq -c -r '.name // empty')
        if [ -n "${ova_name}" ]; then
          item_name="${ova_name%.ova}"
        else
          # No separate name field for the url case - derived from the
          # URL's own filename (basename, .ova extension stripped).
          item_name="${ova_url##*/}"
          item_name="${item_name%.ova}"
        fi

        vcfa_api GET "cloudapi/v1/contentLibraryItems" ""
        item_id=$(echo ${response_body} | jq -c -r --arg arg "${item_name}" '.values[] | select(.name == $arg) | .id')
        if [ -n "${item_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} already exists, skipping" "${log_file}" "" ""
          continue
        fi

        ova_dir="/home/ubuntu/vcf-automation"
        ova_file="${ova_dir}/${item_name}.ova"
        extract_dir="${ova_dir}/${item_name}"
        mkdir -p "${ova_dir}" "${extract_dir}"

        if [ -n "${ova_name}" ]; then
          # vApp/VCD use case - already delivered via spec.vms.gw.iso's
          # generic ISO-passthrough loop, no download needed.
          if [ ! -f "/home/ubuntu/${ova_name}" ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item file ${ova_name} not found at /home/ubuntu/${ova_name} - was it added to vms.gw.iso's Iso CR?, skipping item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
            continue
          fi
          cp "/home/ubuntu/${ova_name}" "${ova_file}"
        else
          download_file_from_url_to_location "${ova_url}" "${ova_file}" "content library item ${item_name}"
        fi

        if [ -z "$(ls -A "${extract_dir}" 2>/dev/null)" ]; then
          tar -xf "${ova_file}" -C "${extract_dir}"
        fi
        ovf_file=$(find "${extract_dir}" -maxdepth 1 -name '*.ovf' | head -1)
        if [ -z "${ovf_file}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no .ovf found after extracting ${ova_file}, skipping item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi

        item_json=$(jq -n --arg n "${item_name}" --arg clid "${cl_id}" \
          '{name: $n, contentLibrary: {id: $clid}, itemType: "TEMPLATE"}')
        vcfa_api POST "cloudapi/v1/contentLibraryItems" "${item_json}"
        vcfa_api GET "cloudapi/v1/contentLibraryItems" ""
        item_id=$(echo ${response_body} | jq -c -r --arg arg "${item_name}" '.values[] | select(.name == $arg) | .id')
        if [ -z "${item_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: failed to create content library item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          continue
        fi

        # descriptor upload - the server does NOT preserve the original
        # uploaded filename for this entry, it always renames it to the
        # literal "descriptor.ovf" regardless of what the local .ovf is
        # actually called (confirmed live: a lab-web-test-base-2.8.ovf
        # upload comes back re-listed as descriptor.ovf, not under its
        # own name) - so excluding disk files by comparing against the
        # LOCAL .ovf basename below is wrong and lets this renamed
        # descriptor entry slip through the filter as if it were a
        # missing disk file. Capture the server's own name for this
        # entry here instead, before uploading it, and exclude by THAT.
        vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}/files" ""
        descriptor_name=$(echo ${response_body} | jq -c -r '.values[0].name')
        descriptor_transfer_url=$(echo ${response_body} | jq -c -r '.values[0].transferUrl')
        vcfa_put_file "${item_id}" "${descriptor_name}" "${descriptor_transfer_url}" "${ovf_file}" "descriptor for item ${item_name}"

        # disk file(s) - discovered from the server AFTER the descriptor
        # upload (see the caveat above); uploaded by matching each
        # server-reported file name against the extracted directory.
        # Retries the discovery GET itself, not just each file's later
        # upload - confirmed live that under real load (concurrent org
        # provisioning elsewhere in this same run) the /files listing can
        # still only report the descriptor entry well past a fixed 5s
        # sleep, silently leaving disk_files empty and skipping the
        # upload loop entirely with no error at all (looked, at the
        # symptom level, identical to the upload itself being stuck).
        disk_files=""
        for attempt_discover in $(seq 1 12); do
          sleep 5
          vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}/files" ""
          disk_files=$(echo ${response_body} | jq -c -r --arg descname "${descriptor_name}" '.values[] | select(.name != $descname) | @base64')
          if [ -n "${disk_files}" ]; then
            break
          fi
        done
        if [ -z "${disk_files}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no disk files discovered for item ${item_name} after waiting, giving up on this item" "${log_file}" "${slack_webhook}" "${google_webhook}"
        fi
        for encoded_file in ${disk_files}; do
          disk_name=$(echo "${encoded_file}" | base64 -d | jq -c -r '.name')
          disk_transfer_url=$(echo "${encoded_file}" | base64 -d | jq -c -r '.transferUrl')
          local_disk_path="${extract_dir}/${disk_name}"
          if [ -f "${local_disk_path}" ]; then
            vcfa_put_file "${item_id}" "${disk_name}" "${disk_transfer_url}" "${local_disk_path}" "disk file ${disk_name} for item ${item_name}"
          else
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: server-requested disk file ${disk_name} not found locally under ${extract_dir} for item ${item_name}" "${log_file}" "${slack_webhook}" "${google_webhook}"
          fi
        done

        retry_item=12 ; pause_item=15 ; attempt_item=1
        while true
        do
          sleep ${pause_item}
          vcfa_api GET "cloudapi/v1/contentLibraryItems/${item_id}" ""
          item_status=$(echo ${response_body} | jq -c -r '.status')
          if [[ "${item_status}" == "READY" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} READY after ${attempt_item} attempts of ${pause_item} seconds" "${log_file}" "" ""
            break
          fi
          if [[ "${item_status}" == "FAILED" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} status FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"
            break
          fi
          ((attempt_item++))
          if [ ${attempt_item} -eq ${retry_item} ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: content library item ${item_name} not READY after ${attempt_item} attempts of ${pause_item} seconds (status=${item_status})" "${log_file}" "${slack_webhook}" "${google_webhook}"
            break
          fi
        done
      fi
    done < <(echo "${item}" | jq -c -r '.items // [] | .[]')
  fi
done < <(echo "${vcf_a_content_libraries}" | jq -c -r .[])

#
# configure orgs - the part actually exercised end-to-end live (org-1
# already existed; org-2 and org-3 were created and fully verified this
# way, including org-3 deliberately skipping the aviSetting step).
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    org_name=$(echo ${item} | jq -c -r '.name')
    region_ref_name=$(echo ${item} | jq -c -r '.region_ref')
    enable_avi=$(echo ${item} | jq -c -r '.enable_avi // true')

    #
    # Demo Gateway API/Ingress/workload demo-yaml rendering, per org -
    # moved here (from a separate, run-once vks-yaml-rendering.sh) because
    # the domain used for Gateway/Ingress/HTTPRoute/HostRule/
    # RouteBackendExtension hostnames has to be unique PER ORG
    # ("${org_name}-vks.${domain}", not the shared
    # "${avi_subdomain}.${domain}") - confirmed live reasoning: Avi is one
    # shared, provider-managed controller across every org, so a single
    # run-once rendering would put every org's virtual services on the
    # exact same FQDN, which Avi can't disambiguate between. Looping per
    # org therefore belongs here rather than in a standalone pre-pass.
    # harbor_registry_fqdn stays shared/global
    # ("harbor.${avi_subdomain}.${domain}") since Harbor is a single
    # shared Supervisor Service instance, not per-org - only the routing
    # domain needs to be unique. Output goes to org's own account's home
    # dir (/home/${org_name}/${yaml_folder}/) rather than a shared
    # ubuntu-owned folder, so each org's differently-rendered files don't
    # overwrite each other AND the org's own SSH login (see
    # gw-accounts.sh, which always runs before this script and guarantees
    # /home/${org_name} already exists - gw_accounts_secret is required)
    # can reach them directly. ubuntu has no traverse/write access into
    # another user's home dir by default, so create+own it as ubuntu
    # first (sudo bypasses the permission check to get there at all),
    # render exactly as before, then hand real ownership to the org at
    # the end below.
    #
    if [ -d /home/ubuntu/dev-avi-vcf/yamls ]; then
      org_yaml_folder="/home/${org_name}/${yaml_folder}"
      sudo mkdir -p "${org_yaml_folder}"
      sudo chown ubuntu:ubuntu "${org_yaml_folder}"
      org_full_domain="${org_name}-vks.${domain}"
      harbor_registry_fqdn="harbor.${avi_subdomain}.${domain}"
      for yaml_src in /home/ubuntu/dev-avi-vcf/yamls/*.yaml; do
        yaml_dst="${org_yaml_folder}/$(basename "$yaml_src")"
        cp "$yaml_src" "$yaml_dst"
        # Per-document dispatch - see vcf_bootstrap.sh's own copy of this
        # same logic (before this merge) for the full rationale: looping
        # per document index and dispatching each one on ITS OWN kind
        # handles any Kind/ordering combination in a multi-doc file.
        last_di=$(yq 'document_index' "$yaml_dst" | tail -1)
        doc_count=$((last_di + 1))
        for ((di = 0; di < doc_count; di++)); do
          this_kind="$(yq "select(di == $di) | .kind" "$yaml_dst")"
          case "$this_kind" in
            Ingress)
              rule_count=$(yq "select(di == $di) | .spec.rules | length" "$yaml_dst")
              for ((i = 0; i < rule_count; i++)); do
                yq -i "(select(di == $di) | .spec.rules[$i].host) = \"v$((i + 1)).${org_full_domain}\"" "$yaml_dst"
              done
              ;;
            HTTPRoute)
              httproute_name="$(yq "select(di == $di) | .metadata.name" "$yaml_dst")"
              yq -i "(select(di == $di)) |= (del(.spec.hostnames) | .spec.hostnames[0] = \"${httproute_name}.${org_full_domain}\")" "$yaml_dst"
              ;;
            Gateway)
              yq -i "(select(di == $di) | .spec.listeners[].hostname) = \"*.${org_full_domain}\"" "$yaml_dst"
              ;;
            HostRule)
              hostrule_name="$(yq "select(di == $di) | .metadata.name" "$yaml_dst")"
              yq -i "(select(di == $di) | .spec.virtualhost.fqdn) = \"${hostrule_name}.${org_full_domain}\"" "$yaml_dst"
              ;;
            RouteBackendExtension)
              rbe_name="$(yq "select(di == $di) | .metadata.name" "$yaml_dst")"
              yq -i "(select(di == $di) | .spec.backendTLS.domainName[0]) = \"${rbe_name}.${org_full_domain}\"" "$yaml_dst"
              ;;
            *)
              # HealthMonitor, L7Rule, Service, Deployment - no per-Kind
              # hostname/URL rewrite for this document. The Harbor image
              # rewrite below runs unconditionally instead of as a case
              # here - see that comment for why.
              ;;
          esac
        done
        # Runs on the whole file at once (not per-document like the loop
        # above), unconditionally - the select(has("containers")) filter
        # already makes it a safe no-op on every document that isn't a
        # Deployment (or anything else without a
        # .containers/.initContainers path), regardless of position in
        # the file or of any document's own kind.
        yq -i '(.. | select(has("containers")) | .containers[], .. | select(has("initContainers")) | .initContainers[] | select(.image != null)).image |= sub("^.*/", "'"${harbor_registry_fqdn}"'/registry/")' "$yaml_dst"
      done
      sudo chown -R "${org_name}:${org_name}" "${org_yaml_folder}"
    fi

    #
    # org - idempotent. Uses filter=name==X (server-side exact match)
    # rather than an unpaginated GET + client-side jq select - confirmed
    # live at 50+ org scale that cloudapi/1.0.0/orgs silently caps its
    # response at 32 values NO MATTER what pageSize is requested (even
    # pageSize=200 made no difference), so beyond ~32 total orgs a plain
    # GET-and-jq-select lookup would falsely report a brand-new org as
    # "not found" even though it was created successfully, and the
    # script would then attempt to create it a second time. filter=
    # queries the server directly for the exact name and always returns
    # the right single record regardless of total org count.
    #
    vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
    org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
    if [ -z "${org_id}" ]; then
      org_json=$(jq -n --arg n "${org_name}" '{name: $n, displayName: $n, description: "", isClassicTenant: false, isEnabled: true}')
      vcfa_api POST "cloudapi/1.0.0/orgs" "${org_json}"
      sleep 3
      vcfa_api GET "cloudapi/1.0.0/orgs?filter=name==${org_name}" ""
      org_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.name == $arg) | .id')
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: org ${org_name} already exists, skipping creation" "${log_file}" "" ""
    fi

    vcfa_api GET "cloudapi/v1/regions" ""
    region_id=$(echo ${response_body} | jq -c -r --arg arg "${region_ref_name}" '.values[] | select(.name == $arg) | .id')

    #
    # virtual datacenter - idempotent. Fixes two real bugs in the
    # original: a missing '}' after the supervisor id (invalid JSON,
    # would never actually have POSTed), and zoneResourceAllocation
    # referencing ${zone_id}/${zone_name} that were never actually set
    # anywhere in that script - now taken from each org's own input.
    #
    vdc_name="${org_name}_region-1"
    vcfa_api GET "cloudapi/v1/virtualDatacenters?filter=name==${vdc_name}" ""
    vdc_id=$(echo ${response_body} | jq -c -r --arg arg "${vdc_name}" '.values[] | select(.name == $arg) | .id')
    if [ -z "${vdc_id}" ]; then
      vcfa_api GET "cloudapi/v1/virtualMachineClasses" ""
      vm_classes=$(echo ${response_body} | jq -c -r '[.values[] | {id, name}]')
      # zone_ref/zone_id are NOT input fields - derived here the same way
      # as storage_class_ref (see the storage policy step below): each
      # region has exactly one zone (confirmed live), so filter
      # cloudapi/v1/zones by this org's region_id and take that one
      # match, instead of requiring a literal URN to be known up front -
      # a URN that, for a brand-new SDDC being built by this same
      # project, cannot exist yet at CR-authoring time.
      vcfa_api GET "cloudapi/v1/zones" ""
      zone_id=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .id' | head -1)
      zone_name=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.region.id == $arg) | .name' | head -1)
      cpu_limit_mhz=$(echo ${item} | jq -c -r '.cpu_limit_mhz')
      memory_limit_mib=$(echo ${item} | jq -c -r '.memory_limit_mib')

      vdc_json=$(jq -n --arg n "${vdc_name}" --arg orgid "${org_id}" --arg regionid "${region_id}" \
        --arg supname "${supervisor_name}" --arg supid "${supervisor_id}" \
        --arg zoneid "${zone_id}" --arg zonename "${zone_name}" \
        --argjson cpulimit "${cpu_limit_mhz}" --argjson memlimit "${memory_limit_mib}" \
        '{name: $n, description: null, org: {id: $orgid}, region: {id: $regionid},
          supervisors: [{name: $supname, id: $supid}],
          zoneResourceAllocation: [{zone: {id: $zoneid, name: $zonename},
            resourceAllocation: {cpuLimitMHz: $cpulimit, cpuReservationMHz: 0, memoryLimitMiB: $memlimit, memoryReservationMiB: 0}}],
          isFullAllocation: false}')
      vcfa_api POST "cloudapi/v1/virtualDatacenters" "${vdc_json}"
      sleep 3
      vcfa_api GET "cloudapi/v1/virtualDatacenters?filter=name==${vdc_name}" ""
      vdc_id=$(echo ${response_body} | jq -c -r --arg arg "${vdc_name}" '.values[] | select(.name == $arg) | .id')

      #
      # VM classes - assign every available class, matching org-1
      #
      vcfa_api PUT "cloudapi/v1/virtualDatacenters/${vdc_id}/virtualMachineClasses" "{\"values\":${vm_classes}}"

      #
      # Storage policy - fixes the original's bug where json_data was
      # built correctly here then immediately overwritten by the
      # previous step's vm_classes payload copy-pasted in by mistake.
      #
      # storage_policy_ref is not part of the org input - it's built from
      # ${default_storage_class} (bash/variables.sh), the same variable
      # already used to attach this policy to the region in the
      # "configure regions" step above, rather than requiring its name to
      # be duplicated in every org/template.
      storage_policy_ref="${default_storage_class}"
      vcfa_api GET "cloudapi/v1/regionStoragePolicies" ""
      storage_policy_id=$(echo ${response_body} | jq -c -r --arg arg "${storage_policy_ref}" '.values[] | select(.name == $arg) | .id')
      storage_limit_mib=$(echo ${item} | jq -c -r '.storage_limit // 102400')
      storage_json=$(jq -n --arg spid "${storage_policy_id}" --argjson limit "${storage_limit_mib}" --arg vdcid "${vdc_id}" \
        '{values: [{regionStoragePolicy: {id: $spid}, storageLimitMiB: $limit, virtualDatacenter: {id: $vdcid}}]}')
      vcfa_api PUT "cloudapi/v1/virtualDatacenters/${vdc_id}/virtualDatacenterStoragePolicies" "${storage_json}"
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vDC ${vdc_name} already exists, skipping creation" "${log_file}" "" ""
    fi

    #
    # Regional networking settings - idempotent. filter=orgRef.name==X
    # for the same reason as the org/vDC lookups above - confirmed live
    # this endpoint has the identical 32-item pageSize cap.
    #
    org_uuid="${org_id##*:}"
    vcfa_api GET "cloudapi/v1/regionalNetworkingSettings?filter=orgRef.name==${org_name}" ""
    rns_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .id')
    if [ -z "${rns_id}" ]; then
      pgw_name=$(echo ${item} | jq -c -r '.provider_gateway_ref')
      edge_cluster_name=$(echo ${item} | jq -c -r '.edge_cluster_ref')
      vcfa_api GET "cloudapi/v1/providerGateways" ""
      pgw_id=$(echo ${response_body} | jq -c -r --arg arg "${pgw_name}" '.values[] | select(.name == $arg) | .id')
      vcfa_api GET "cloudapi/v1/edgeClusters" ""
      edge_id=$(echo ${response_body} | jq -c -r --arg arg "${edge_cluster_name}" '.values[] | select(.name == $arg) | .id')
      if [ -z "${edge_id}" ]; then
        #
        # A brand-new region's edge cluster is not discovered automatically -
        # confirmed live (both the vcf9 lab and a second, independent
        # VCD/VCFA environment) that cloudapi/v1/edgeClusters/sync (no
        # region/id in the path, triggers NSX transport-node discovery) is
        # required first. Try it once, wait, and re-check before giving up.
        #
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: edge cluster ${edge_cluster_name} not found for ${org_name}, triggering cloudapi/v1/edgeClusters/sync" "${log_file}" "" ""
        vcfa_api POST "cloudapi/v1/edgeClusters/sync" ""
        sleep 60
        vcfa_api GET "cloudapi/v1/edgeClusters" ""
        edge_id=$(echo ${response_body} | jq -c -r --arg arg "${edge_cluster_name}" '.values[] | select(.name == $arg) | .id')
        if [ -z "${edge_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: edge cluster ${edge_cluster_name} still not found for ${org_name} after edgeClusters/sync" "${log_file}" "${slack_webhook}" "${google_webhook}"
          exit 100
        fi
      fi

      net_json=$(jq -n --arg n "${org_name}" --arg orgid "${org_id}" --arg rn "${region_ref_name}" --arg regionid "${region_id}" \
        --arg pgwn "${pgw_name}" --arg pgwid "${pgw_id}" --arg edgen "${edge_cluster_name}" --arg edgeid "${edge_id}" \
        '{orgRef: {name: $n, id: $orgid}, regionRef: {name: $rn, id: $regionid},
          providerGatewayRef: {name: $pgwn, id: $pgwid}, serviceEdgeClusterRef: {name: $edgen, id: $edgeid}}')

      #
      # Create + poll to REALIZED, then verify the underlying NSX Project
      # actually exists before trusting it - confirmed live at 50-org
      # scale that VCFA's regionalNetworkingSettings can report status
      # REALIZED while the NSX Project backing that org's VPC was never
      # actually created at all (root cause never fully pinned down;
      # observed as a clean alternating every-other-org failure when 51
      # orgs' regionalNetworkingSettings were POSTed back-to-back with no
      # pacing between them - real NSX Manager/Avi were both healthy).
      # This is a genuine backend gap: nothing in VCFA's own API surface
      # (status, aviSetting errors) reveals it - the only reliable check
      # is GETting the org's NSX Project directly. One delete+recreate
      # retry (confirmed live to fully resolve it every time across 25
      # affected orgs) before giving up for good.
      #
      for rns_attempt in 1 2; do
        vcfa_api POST "cloudapi/v1/regionalNetworkingSettings" "${net_json}"

        retry_rns=12 ; pause_rns=10 ; attempt_rns=1 ; rns_realized=false
        while true
        do
          sleep ${pause_rns}
          vcfa_api GET "cloudapi/v1/regionalNetworkingSettings?filter=orgRef.name==${org_name}" ""
          rns_status=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .status')
          rns_id=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[] | select(.orgRef.name == $arg) | .id')
          if [[ "${rns_status}" == "REALIZED" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} REALIZED after ${attempt_rns} attempts of ${pause_rns} seconds" "${log_file}" "" ""
            rns_realized=true
            break
          fi
          ((attempt_rns++))
          if [ ${attempt_rns} -eq ${retry_rns} ]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} not REALIZED after ${attempt_rns} attempts of ${pause_rns} seconds (status=${rns_status})" "${log_file}" "${slack_webhook}" "${google_webhook}"
            exit 100
          fi
        done

        nsx_project_id=$(curl -sk -u "admin:${generic_password}" "https://${ip_nsx_vip}/policy/api/v1/orgs/default/projects/${org_uuid}" | jq -r '.id // empty')
        if [ "${nsx_project_id}" == "${org_uuid}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: NSX Project confirmed present for ${org_name}" "${log_file}" "" ""
          break
        fi

        if [ ${rns_attempt} -eq 2 ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: NSX Project still missing for ${org_name} after delete+recreate retry - regionalNetworkingSettings reports REALIZED but is not actually backed by NSX, giving up" "${log_file}" "${slack_webhook}" "${google_webhook}"
          exit 100
        fi
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: NSX Project missing for ${org_name} despite REALIZED status - deleting and recreating regionalNetworkingSettings once" "${log_file}" "" ""
        vcfa_api DELETE "cloudapi/v1/regionalNetworkingSettings/${rns_id}" ""
        sleep 10
      done
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: regionalNetworkingSettings for ${org_name} already exists, skipping creation" "${log_file}" "" ""
    fi

    #
    # Avi / Load Balancing regional setting - not present anywhere in the
    # original script; found only via the VCFA UI's own network calls.
    # Optional per-org via enable_avi (defaults to true) - set to false to
    # leave an org's Load Balancing section deliberately empty.
    #
    # Two modes, each with a DIFFERENT quota field name (confirmed live,
    # not documented anywhere):
    #   - TENANT_MANAGED: org self-provisions its own service engines.
    #     Quota -> serviceEngineQuota. No SEG reference needed.
    #   - PROVIDER_MANAGED: org is pinned to one specific, already-existing
    #     provider Avi service engine group. Quota -> applicationLimit
    #     instead, and serviceEngineGroupRefs (resolved by name via
    #     cloudapi/v1/loadBalancer/aviServiceEngineGroups, filtered by
    #     this org's region) is required.
    #
    if [ "${enable_avi}" == "true" ]; then
      avi_mode=$(echo ${item} | jq -c -r '.avi_mode // "TENANT_MANAGED"')
      avi_quota=$(echo ${item} | jq -c -r '.avi_quota // 10')
      if [ "${avi_mode}" == "PROVIDER_MANAGED" ]; then
        #
        # Confirmed live: VCFA can reject a PROVIDER_MANAGED aviSetting
        # ("service engine group has not been assigned") even though the
        # PUT itself returns 202 and the SEG is already GET-able, unless
        # the avi controller has been synced first. Sync once per script
        # run (avi_synced flag), not once per org - it's a controller-wide
        # action, not org- or SEG-scoped.
        #
        if [ -z "${avi_synced:-}" ]; then
          vcfa_api GET "cloudapi/v1/loadBalancer/aviControllers?filter=regionRef.id==${region_id}" ""
          avi_controller_id=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.regionRef.id == $arg) | .id' | head -1)
          if [ -z "${avi_controller_id}" ]; then
            #
            # Do NOT manually POST a new aviController here - confirmed
            # live (2026-09-22) that VCFA auto-discovers and registers
            # Avi itself (via the vcfInfraEndpoints refresh at the top of
            # this script) under its OWN internally-generated service
            # account (username like "svc-vcfa_<uuid>"), not "admin"/
            # generic_password. POSTing a second, manually-created entry
            # with the wrong credentials would create a conflicting
            # duplicate rather than fix anything. If it's still not here
            # after the refresh already done above, wait a bit longer
            # and fail loudly rather than creating a wrong one.
            #
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: no avi controller registered in VCFA for region ${region_ref_name} yet, waiting for VCFA's own auto-discovery" "${log_file}" "" ""
            #
            # A single vcfInfraEndpoints refresh (already done once at the
            # very top of this script) isn't reliably enough on its own -
            # confirmed live 2026-09-29: a real run sat with an empty Avi
            # Controller connection in VCFA even after that refresh plus
            # 12x10s of passive re-polling, and only started showing up
            # once a user manually re-triggered "Sync Instance" on the VCF
            # Instance connection in the VCFA UI (the same refresh action)
            # a second time. So each retry round here re-issues that same
            # refresh instead of just re-polling the same stale state.
            #
            for attempt_avi_reg in 1 2 3; do
              if [ -n "${vcf_infra_endpoint_id}" ] && [ "${vcf_infra_endpoint_id}" != "null" ]; then
                vcfa_api POST "cloudapi/1.0.0/vcfInfraEndpoints/${vcf_infra_endpoint_id}/refresh" ""
              fi
              sleep 60
              vcfa_api GET "cloudapi/v1/loadBalancer/aviControllers?filter=regionRef.id==${region_id}" ""
              avi_controller_id=$(echo ${response_body} | jq -c -r --arg arg "${region_id}" '.values[] | select(.regionRef.id == $arg) | .id' | head -1)
              if [ -n "${avi_controller_id}" ]; then
                break
              fi
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: avi controller for region ${region_ref_name} still not registered after refresh attempt ${attempt_avi_reg}/3" "${log_file}" "" ""
            done
            if [ -z "${avi_controller_id}" ]; then
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: avi controller for region ${region_ref_name} never appeared in VCFA after 3 refresh attempts, aborting" "${log_file}" "${slack_webhook}" "${google_webhook}"
              exit 100
            fi
          fi
          if [ -n "${avi_controller_id}" ]; then
            vcfa_api POST "cloudapi/v1/loadBalancer/aviControllers/${avi_controller_id}/sync" ""
            sleep 30
          fi
          avi_synced=true
        fi
        seg_name=$(echo ${item} | jq -c -r '.avi_service_engine_group_ref')
        vcfa_api GET "cloudapi/v1/loadBalancer/aviServiceEngineGroups?filter=regionRef.id==${region_id}" ""
        seg_id=$(echo ${response_body} | jq -c -r --arg arg "${seg_name}" '.values[] | select(.name == $arg) | .id')
        if [ -z "${seg_id}" ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: avi service engine group ${seg_name} not found for ${org_name}, skipping aviSetting" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          avi_json=$(jq -n --argjson limit "${avi_quota}" --arg segid "${seg_id}" \
            '{active: true, serviceEngineGroupMode: "PROVIDER_MANAGED", applicationLimit: $limit, serviceEngineGroupRefs: [{id: $segid}]}')
          vcfa_api PUT "cloudapi/v1/regionalNetworkingSettings/${rns_id}/aviSetting" "${avi_json}"
        fi
      else
        avi_json=$(jq -n --argjson quota "${avi_quota}" \
          '{active: true, serviceEngineGroupMode: "TENANT_MANAGED", serviceEngineQuota: $quota}')
        vcfa_api PUT "cloudapi/v1/regionalNetworkingSettings/${rns_id}/aviSetting" "${avi_json}"
      fi
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: enable_avi=false for ${org_name}, leaving aviSetting inactive" "${log_file}" "" ""
    fi

    #
    # Assign a user to the VCF-A org - one local "Organization
    # Administrator" per org, username=org_name, same VMware1!-bookended
    # password as every other per-org account (gw SSH, vCenter SSO, Avi,
    # NSX - see gw-accounts.sh's own comment for why this exact shape is
    # required). VCFA allows at most 1 local user per org ("A maximum of
    # 1 local users are allowed per organization", confirmed live
    # 2026-09-28), so existence is checked first via a tenant-scoped GET
    # (unfiltered - a max-1-user org makes filtering unnecessary) rather
    # than attempting creation unconditionally and treating that error as
    # a real failure.
    #
    # "Organization Administrator" is a TENANT-scoped role, not a
    # provider one - confirmed live it's completely invisible on a plain
    # (provider-context) GET cloudapi/1.0.0/roles call, only appearing
    # once the same request carries the tenant-context header below. Its
    # role_id is looked up fresh per org rather than hardcoded, since
    # VCFA mints a distinct role URN per org for this same role name -
    # confirmed live two different orgs got two different IDs for the
    # identically-named role.
    #
    tenant_ctx_header="x-vmware-vcloud-tenant-context: ${org_uuid}"
    vcfa_api GET "cloudapi/1.0.0/users" "" 2 5 "${tenant_ctx_header}"
    existing_org_user=$(echo ${response_body} | jq -c -r --arg arg "${org_name}" '.values[]? | select(.username == $arg) | .username')
    if [ -n "${existing_org_user}" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A org user ${org_name} already exists, skipping creation" "${log_file}" "" ""
    else
      vcfa_api GET "cloudapi/1.0.0/roles" "" 2 5 "${tenant_ctx_header}"
      org_admin_role_id=$(echo ${response_body} | jq -c -r '.values[] | select(.name == "Organization Administrator") | .id')
      if [ -z "${org_admin_role_id}" ] || [ "${org_admin_role_id}" == "null" ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Organization Administrator role not found for ${org_name}, skipping VCF-A org user creation" "${log_file}" "${slack_webhook}" "${google_webhook}"
      else
        org_password="VMware1!$(echo -n "${gw_accounts_secret}${org_name}" | sha256sum | cut -c1-4)VMware1!"
        user_json=$(jq -n --arg u "${org_name}" --arg p "${org_password}" --arg roleid "${org_admin_role_id}" \
          '{username: $u, password: $p, roleEntityRefs: [{id: $roleid, name: "Organization Administrator"}], providerType: "LOCAL"}')
        vcfa_api POST "cloudapi/1.0.0/users" "${user_json}" 2 5 "${tenant_ctx_header}"
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A org user ${org_name} created (Organization Administrator)" "${log_file}" "" ""
      fi
    fi
  fi
done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: End of ${0%.*}.sh" "${log_file}" "${slack_webhook}" "${google_webhook}"
