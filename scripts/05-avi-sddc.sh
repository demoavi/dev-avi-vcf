#!/bin/bash
# Avi Controller deployment via SDDC Manager (merged from the reference project's sddc-manager/avi-sddc.sh).
# Part of the split-up vcf_bootstrap.sh (see 00-lib.sh for why) - run
# standalone as:
#   bash 05-avi-sddc.sh /home/ubuntu/json/deployment.json
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-lib.sh"
log_notify "05-avi-sddc.sh started"
# Avi Controller deployment via SDDC Manager (merged from the reference
# project's sddc-manager/avi-sddc.sh) - the 9.0 branch (manual pvc.json/OVA
# upload over scp) is dropped, VCF 9.1-only scope as elsewhere in this
# script. SDDC Manager exposes the same v1/tokens + v1/bundles API shape as
# the VCF Installer appliance, so this reuses create_api_session/
# sddc_manager_api directly rather than needing new helpers - just pointed
# at ${basename_sddc}-sddcm.${domain} instead of ${ip_vcf_installer}, since
# once the SDDC finishes building, SDDC Manager (not VCF Installer) owns
# the API. Login is administrator@<ssoDomain>, not admin@local - the local
# VCF Installer account doesn't carry over to the persistent SDDC Manager
# appliance.
#
ip_sddcm="${basename_sddc}-sddcm.${domain}"
create_api_session "administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)" "${generic_password}" "${ip_sddcm}" /tmp/token_sddcm.json

sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/bundles $(jq -c -r .accessToken /tmp/token_sddcm.json)
avi_bundle_id=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .id')
avi_download_status=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .downloadStatus')
if [[ ${avi_download_status} != "SUCCESSFUL" ]]; then
  sddc_manager_api 3 2 PATCH '{"bundleDownloadSpec":{"downloadNow":true}}' "${ip_sddcm}" v1/bundles/${avi_bundle_id} $(jq -c -r .accessToken /tmp/token_sddcm.json)
  log_only "VCF-I: waiting 120 seconds for Avi bundle download to start"
  sleep 120
fi

retry_avi_download=30 ; pause_avi_download=10 ; attempt_avi_download=1
while true ; do
  sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/bundles $(jq -c -r .accessToken /tmp/token_sddcm.json)
  avi_download_status=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .downloadStatus')
  if [[ ${avi_download_status} == "SUCCESSFUL" ]]; then
    log_notify "VCF-I: Avi bundle downloaded"
    break
  fi
  if [ ${attempt_avi_download} -eq ${retry_avi_download} ]; then
    log_notify "ERROR: Avi bundle not downloaded after ${attempt_avi_download} attempts of ${pause_avi_download} seconds"
    exit 100
  fi
  sleep ${pause_avi_download}
  ((attempt_avi_download++))
done

sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/domains $(jq -c -r .accessToken /tmp/token_sddcm.json)
nsx_id=$(echo ${response_body} | jq -c -r '.elements[0].nsxtCluster.id')

if [[ $(echo ${ips_avi} | jq -c -r '. | length') -eq 3 ]]; then
  avi_cluster_json=$(jq -n --arg pw "${generic_password}" --arg bundle "${avi_bundle_id}" --arg fqdn "${basename_sddc}-avi.${domain}" --arg nsx "${nsx_id}" --argjson ips "${ips_avi}" \
    '{adminPassword: $pw, bundleId: $bundle, clusterFqdn: $fqdn, clusterName: "cluster-1", formFactor: "SMALL",
      nodes: [$ips[] | {ipAddress: .}], nsxIds: [$nsx], vcfopsAdminPassword: $pw}')
  sddc_manager_api 3 2 POST "${avi_cluster_json}" "${ip_sddcm}" v1/alb-clusters $(jq -c -r .accessToken /tmp/token_sddcm.json)
  log_notify "VCF-I: Avi cluster deployment started"
else
  #
  # single-node Avi controller needs a feature flag enabled on SDDC Manager
  # first (same expect-based su pattern as the earlier lcm/domainmanager
  # patch, since su also refuses to run without a real controlling
  # terminal here) - replaces the reference project's more generic
  # patch_sddcm.sh with just the two commands it actually runs.
  #
  log_notify "VCF-I: patching SDDC Manager for single-node Avi controller support"
  export SDDCM_ROOT_PASSWORD="${generic_password}"
  export SDDCM_HOST="${ip_sddcm}"
  expect <<'SDDCM_EXPECT_EOF'
set timeout 60
set password $env(SDDCM_ROOT_PASSWORD)
spawn ssh -tt -o StrictHostKeyChecking=no vcf@$env(SDDCM_HOST)
expect "*assword:" { send "$password\r" }
expect "*$ " { send "su -\r" }
expect "*assword:" { send "$password\r" }
expect "*# " { send "echo 'feature.vcf.vgl-41078.alb.single.node.cluster=true' | tee /home/vcf/feature.properties\r" }
expect "*# " { send "printf 'y' | /opt/vmware/vcf/operationsmanager/scripts/cli/sddcmanager_restart_services.sh\r" }
expect "*# " { send "exit\r" }
expect "*$ " { send "exit\r" }
expect eof
SDDCM_EXPECT_EOF
unset SDDCM_ROOT_PASSWORD SDDCM_HOST
log_only "VCF-I: waiting 180 seconds for SDDC Manager services to restart"
sleep 180

avi_cluster_json=$(jq -n --arg pw "${generic_password}" --arg bundle "${avi_bundle_id}" --arg fqdn "${basename_sddc}-avi.${domain}" --arg nsx "${nsx_id}" --arg ip "$(echo ${ips_avi} | jq -r '.[0]')" \
  '{adminPassword: $pw, bundleId: $bundle, clusterFqdn: $fqdn, clusterName: "cluster-1", formFactor: "SMALL",
    nodes: [{ipAddress: $ip}], nsxIds: [$nsx], vcfopsAdminPassword: $pw}')
sddc_manager_api 3 2 POST "${avi_cluster_json}" "${ip_sddcm}" v1/alb-clusters $(jq -c -r .accessToken /tmp/token_sddcm.json)
log_notify "VCF-I: single-node Avi controller deployment started"
log_only "VCF-I: waiting 1800 seconds for Avi controller deployment"
sleep 1800

create_api_session "administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)" "${generic_password}" "${ip_sddcm}" /tmp/token_sddcm.json
retry_avi_deploy=60 ; pause_avi_deploy=10 ; attempt_avi_deploy=1
while true ; do
  sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/alb-clusters $(jq -c -r .accessToken /tmp/token_sddcm.json)
  avi_deploy_status=$(echo ${response_body} | jq -c -r '.elements[0].deploymentStatus')
  if [[ ${avi_deploy_status} == "ACTIVE" ]]; then
    log_notify "VCF-I: Avi controller deployed"
    break
  fi
  if [ ${attempt_avi_deploy} -eq ${retry_avi_deploy} ]; then
    log_notify "ERROR: Avi controller not deployed after ${attempt_avi_deploy} attempts of ${pause_avi_deploy} seconds"
    exit 100
  fi
  sleep ${pause_avi_deploy}
  ((attempt_avi_deploy++))
done
fi


log_notify "05-avi-sddc.sh complete"
