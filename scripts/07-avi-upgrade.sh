#!/bin/bash
# Avi Controller upgrade (merged from the reference project's avi/upgrade_avi.sh). Standalone here (unlike when this ran later in the same process as 06-avi-configure.sh) - re-derives ip_sddcm/avi_version/ip_avi and logs in fresh, matching how the reference project's own upgrade_avi.sh runs standalone too.
# Part of the split-up vcf_bootstrap.sh (see 00-lib.sh for why) - run
# standalone as:
#   bash 07-avi-upgrade.sh /home/ubuntu/json/deployment.json
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-lib.sh"
log_notify "07-avi-upgrade.sh started"
# Avi Controller upgrade (merged from the reference project's
# avi/upgrade_avi.sh) - entirely skipped if spec.sddc.avi.pkg_iso isn't
# set, since most deployments don't need one. Reuses ip_avi/avi_version/
# avi_login/avi_api from the configuration section just above instead of
# re-deriving them - the reference script runs standalone in the original
# project (a fresh sddcm login/avi_version lookup each time), but here it's
# simply later in the same run.
#

# Re-derived standalone (06-avi-configure.sh set these in-memory when this
# ran later in the same bash process as it originally did) - matches the
# reference project's own upgrade_avi.sh, which re-derives these fresh too.
ip_sddcm="${basename_sddc}-sddcm.${domain}"
create_api_session "administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)" "${generic_password}" "${ip_sddcm}" /tmp/token_sddcm.json
sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/bundles $(jq -c -r .accessToken /tmp/token_sddcm.json)
avi_version=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .version' | cut -d"-" -f1)
ip_avi=$(echo ${ips_avi} | jq -r '.[0]')
avi_login

if [ -z "${avi_pkg_filename}" ]; then
  log_only "VCF-I: sddc.avi.pkg_iso not set, skipping Avi upgrade check"
else
  # gw has no route to download this itself - gw-setup.sh.tpl already
  # copied it here at boot from the Iso CR referenced by
  # sddc.avi.pkg_iso, mounted as gw's CD-ROM (see
  # vapp_operator._ensure_gw_tools_media). If it's still missing, that
  # Iso's media didn't contain a file matching pkg_iso.file, or wasn't
  # attached at all - not something retrying here would fix.
  avi_pkg_file="/home/ubuntu/avi/${avi_pkg_filename}"
  if [ ! -f "${avi_pkg_file}" ]; then
    log_notify "ERROR: ${avi_pkg_file} not found - gw tools ISO was not attached or didn't contain this file"
    exit 100
  fi
  avi_login
  avi_api 2 2 GET "" api/version/controller "*"
  current_version=$(echo ${response_body} | jq -c -r '.[0].version' | cut -d")" -f1 | tr '(' '-')
  target_version=$(basename "${avi_pkg_filename}" .pkg | cut -d"-" -f2-3)
  if [[ ${current_version} == ${target_version} ]]; then
    log_notify "VCF-I: Avi upgrade not required (already ${current_version})"
  else
    log_notify "VCF-I: Avi upgrade required, from ${current_version} to ${target_version}"
    avi_api 2 2 POST "" api/image admin "${avi_pkg_file}"
    image_uuid=$(echo ${response_body} | jq -c -r '.uuid')
    sleep 10
    upgrade_json=$(jq -n --arg id "${image_uuid}" '{image_uuid: $id, system: true, skip_warnings: true, dryrun: false, prechecks_only: false, se_group_options: {action_on_error: "CONTINUE_UPGRADE_OPS_ON_ERROR"}}')
    avi_api 2 2 POST "${upgrade_json}" api/upgrade
    log_only "VCF-I: waiting 1200 seconds for Avi upgrade to apply"
    sleep 1200
    retry_avi_up=10 ; pause_avi_up=60 ; attempt_avi_up=1
    while true ; do
      http_code=$(curl -k -o /dev/null -s --write-out '%{http_code}' "https://${ip_avi}/api/initial-data")
      if [[ ${http_code} -eq 200 ]]; then
        log_only "VCF-I: Avi ctrl reachable again after upgrade"
        break
      fi
      ((attempt_avi_up++))
      if [ ${attempt_avi_up} -eq ${retry_avi_up} ]; then
        log_notify "ERROR: Avi ctrl not reachable after ${retry_avi_up} attempts of ${pause_avi_up} seconds post-upgrade"
        exit 100
      fi
      sleep ${pause_avi_up}
    done
    avi_login
    avi_api 2 2 GET "" api/upgradestatusinfo "*"
    failed_items=$(echo ${response_body} | jq -c --arg tv "${target_version}" '[.results[] | select(.version != null and (.version | startswith($tv)) and .state.state != "UPGRADE_FSM_COMPLETED")]')
    if [ "$(echo ${failed_items} | jq -c -r 'length')" -gt 0 ]; then
      log_notify "ERROR: Avi has not been upgraded to ${target_version}: ${failed_items}"
      exit 100
    else
      log_notify "VCF-I: Avi has been upgraded to ${target_version}"
    fi
  fi
fi


log_notify "07-avi-upgrade.sh complete"
