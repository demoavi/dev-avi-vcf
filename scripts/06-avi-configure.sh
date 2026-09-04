#!/bin/bash
# Avi Controller configuration (merged from the reference project's avi/configure_avi.sh).
# Part of the split-up vcf_bootstrap.sh (see 00-lib.sh for why) - run
# standalone as:
#   bash 06-avi-configure.sh /home/ubuntu/json/deployment.json
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-lib.sh"
log_notify "06-avi-configure.sh started"
ip_sddcm="${basename_sddc}-sddcm.${domain}"  # set standalone - 05-avi-sddc.sh set this in-memory when it ran earlier in the same process
# Avi Controller configuration (merged from the reference project's
# avi/configure_avi.sh) - the 9.0/8.0U3b branch (ansible-driven config via
# an external avi_ansible_config_repo playbook) is dropped, VCF 9.1-only
# scope as elsewhere in this script. Reuses create_api_session/
# sddc_manager_api against ${ip_sddcm} (already set up in the Avi
# deployment section above) to look up the Avi bundle version, and inlines
# the reference project's avi_api() as a function - fixed to exit 100 on
# retry exhaustion instead of silently continuing, for consistency with
# every other API helper in this script.
#
# The reference project's top-of-script content library creation targets
# the OUTER/host vCenter (via load_govc_env_with_cluster, a vCenter/govc
# managing the physical hosts this whole nested lab runs on) - this project
# has no such thing, everything outer-layer is VCD-managed instead. The
# content library Avi's own vcenterserver config later attaches to is
# created on OUR nested vCenter instead, reusing the same GOVC_* pattern as
# the port-group section earlier in this script.
#
mkdir -p /home/ubuntu/avi
export GOVC_URL="${basename_sddc}-vc01.${domain}"
export GOVC_USERNAME="administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)"
export GOVC_PASSWORD="${generic_password}"
export GOVC_DATACENTER="${basename_sddc}-dc"
export GOVC_INSECURE=true
export GOVC_PERSIST_SESSION=false
unset GOVC_CLUSTER
govc_error=$(govc about 2>&1)
if [ $? -ne 0 ]; then
  log_notify "ERROR: unable to connect to vCenter for Avi content library setup: ${govc_error}"
  exit 100
fi
content_library_id=$(govc library.ls -json | jq -c -r --arg arg "${avi_content_library_name}" '.[] | select(.name == $arg) | .id')
if [ -z "${content_library_id}" ]; then
  govc library.create "${avi_content_library_name}" > /dev/null
fi

#
# Avi HTTPS check - ip_avi is the first (and, for a standalone controller,
# only) node from the Avi deployment section above.
#
ip_avi=$(echo ${ips_avi} | jq -r '.[0]')
count=1
until $(curl --output /dev/null --silent --head -k https://${ip_avi})
do
  log_only "Attempt ${count}: Waiting for Avi ctrl at https://${ip_avi} to be reachable..."
  sleep 10
  count=$((count+1))
  if [[ "${count}" -eq 60 ]]; then
    log_notify "ERROR: Unable to connect to Avi ctrl at https://${ip_avi}"
    exit 100
  fi
done
log_notify "Avi ctrl reachable at https://${ip_avi}"

# spec.sddc.avi.version pins this explicitly when set (see crd-vapp.yaml)
# - only fall back to deriving it from SDDC Manager's v1/bundles list when
# unset. That lookup is ambiguous once more than one NSX_ALB bundle shows
# up there (a later depot sync can add a newer one alongside whatever was
# already downloaded) - filtering on downloadStatus == "SUCCESSFUL" picks
# the one that's actually usable rather than just whatever jq happens to
# return first.
if [ -z "${avi_version}" ]; then
  create_api_session "administrator@$(jq -c -r .sddc.vcenter.ssoDomain $jsonFile)" "${generic_password}" "${ip_sddcm}" /tmp/token_sddcm.json
  sddc_manager_api 3 2 GET '' "${ip_sddcm}" v1/bundles $(jq -c -r .accessToken /tmp/token_sddcm.json)
  avi_version=$(echo ${response_body} | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg and .downloadStatus == "SUCCESSFUL") | .version' | head -1 | cut -d"-" -f1)
fi

avi_login

#
# backup user + backup config
#
# Idempotent (unlike the reference project's own always-POST version) -
# reuses an existing "ubuntu" cloudconnectoruser instead of erroring with
# a 409 on every re-run after the first, since this step has no natural
# reason to ever need re-creating.
avi_api 2 2 GET "" "api/cloudconnectoruser?name=ubuntu"
cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid // empty')
if [ -z "${cloudconnectoruser_uuid}" ]; then
  avi_api 2 2 POST "$(jq -n --arg n "ubuntu" --arg p "${generic_password}" '{name: $n, password: $p}')" api/cloudconnectoruser
  cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.uuid')
fi
avi_api 2 2 GET "" api/backupconfiguration
backupconfiguration_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
backup_json=$(jq -n --arg pw "${generic_password}" --arg host "${ip_gw}" --arg ssh "${cloudconnectoruser_uuid}" \
  '{replace: {name: "Backup-Configuration", backup_passphrase: $pw, save_local: true, upload_to_remote_host: true,
    remote_directory: "/home/ubuntu/avi/backup", remote_file_transfer_protocol: "SCP", remote_hostname: $host, ssh_user_ref: $ssh}}')
avi_api 2 2 PATCH "${backup_json}" "api/backupconfiguration/${backupconfiguration_uuid}"

#
# system config, fault config, controller properties
#
avi_api 2 2 GET "" api/systemconfiguration
avi_api 2 2 PUT "$(echo ${response_body} | jq -c '. + {welcome_workflow_complete: true, default_license_tier: "ENTERPRISE_WITH_CLOUD_SERVICES"}')" api/systemconfiguration
avi_api 2 2 GET "" api/inventoryfaultconfig
avi_api 2 2 PUT "$(echo ${response_body} | jq -c '. + {controller_faults: {sslprofile_faults: false, license_faults: false}}')" api/inventoryfaultconfig
avi_api 2 2 GET "" api/controllerproperties
avi_api 2 2 PUT "$(echo ${response_body} | jq -c '. + {api_idle_timeout: 240}')" api/controllerproperties

#
# cloud + NSX discovery (transport zone, tier1s, segments)
#
avi_api 2 2 GET "" api/cloud
cloud_uuid=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .uuid')
cloud_url=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .url')
nsx_url=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .nsxt_configuration.nsxt_url')
avi_api 2 2 GET "" api/cloudconnectoruser
nsx_cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.results[] | select(has("nsxt_credentials")) | .uuid')
vcenter_cloudconnectoruser_uuid=$(echo ${response_body} | jq -c -r '.results[] | select(has("vcenter_credentials")) | .uuid')

nsx_lookup_json=$(jq -n --arg h "${nsx_url}" --arg c "${nsx_cloudconnectoruser_uuid}" '{host: $h, credentials_uuid: $c}')
avi_api 2 2 POST "${nsx_lookup_json}" api/nsxt/transportzones
tz_id=$(echo ${response_body} | jq -c -r --arg arg "VCF-Created-Overlay-Zone" '.resource.nsxt_transportzones[] | select(.name == $arg) | .id')

avi_api 2 2 POST "${nsx_lookup_json}" api/nsxt/tier1s
t1_mgmt_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select( .avi_mgmt == true) | .tier1')" '.resource.nsxt_tier1routers[] | select(.name == $arg) | .id')
t1_vip_name=$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .tier1')
t1_vip_id=$(echo ${response_body} | jq -c -r --arg arg "${t1_vip_name}" '.resource.nsxt_tier1routers[] | select(.name == $arg) | .id')

avi_api 2 2 POST "$(echo ${nsx_lookup_json} | jq -c --arg tz "${tz_id}" '. + {transport_zone_id: $tz}')" api/nsxt/segments
seg_mgmt_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select( .avi_mgmt == true) | .display_name')" '.resource.nsxt_segments[] | select(.name == $arg) | .id')
seg_vip_id=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .display_name')" '.resource.nsxt_segments[] | select(.name == $arg) | .id')

#
# vcenterserver + content library attach (avi_content_library_id is Avi's
# own internal id for the library from its vCenter discovery, distinct
# from govc's content_library_id fetched/created above by name)
#
avi_api 2 2 GET "" api/vcenterserver
vcenter_server_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
vcenter_server_url=$(echo ${response_body} | jq -c -r '.results[0].vcenter_url')
avi_api 2 2 POST "$(jq -n --arg h "${vcenter_server_url}" --arg c "${vcenter_cloudconnectoruser_uuid}" '{host: $h, credentials_uuid: $c}')" api/vcenter/contentlibraries
avi_content_library_id=$(echo ${response_body} | jq -c -r --arg arg "${avi_content_library_name}" '.resource.vcenter_clibs[] | select(.name == $arg) | .id')
avi_api 2 2 PATCH "$(jq -n --arg id "${avi_content_library_id}" '{add: {content_lib: {id: $id}}}')" "api/vcenterserver/${vcenter_server_uuid}"

#
# cloud nsxt_configuration update (mgmt + data network placement)
#
cloud_update_json=$(jq -n --arg tz "${tz_id}" --arg t1m "${t1_mgmt_id}" --arg segm "${seg_mgmt_id}" --arg t1v "${t1_vip_id}" --arg segv "${seg_vip_id}" \
  '{add: {nsxt_configuration: {
      management_network_config: {tz_type: "OVERLAY", transport_zone: $tz, overlay_segment: {tier1_lr_id: $t1m, segment_id: $segm}},
      data_network_config: {tz_type: "OVERLAY", transport_zone: $tz, tier1_segment_config: {segment_config_mode: "TIER1_SEGMENT_MANUAL", manual: {tier1_lrs: [{tier1_lr_id: $t1v, segment_id: $segv}]}}}
  }}}')
avi_api 2 2 PATCH "${cloud_update_json}" "api/cloud/${cloud_uuid}"

#
# DNS profile, then re-login (matching the reference's own wait+relogin
# here, presumably to pick up the cloud placement before the next calls)
#
avi_api 2 2 POST "$(jq -n --arg fqdn "${avi_subdomain}.${domain}" '{name: "dns-avi", type: "IPAMDNS_TYPE_INTERNAL_DNS", internal_profile: {dns_service_domain: [{domain_name: $fqdn}]}}')" api/ipamdnsproviderprofile
log_only "configure Avi - waiting 120 seconds"
sleep 120
avi_login

#
# IPAM profile + cloud ipam/dns refs
#
avi_api 2 2 GET "" api/network
vip_uuid=$(echo ${response_body} | jq -c -r --arg arg "$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .display_name')" '.results[] | select(.name == $arg) | .uuid')
avi_api 2 2 POST "$(jq -n --arg ref "/api/network/${vip_uuid}" '{name: "ipam-avi", type: "IPAMDNS_TYPE_INTERNAL", internal_profile: {usable_networks: [{nw_ref: $ref}]}}')" api/ipamdnsproviderprofile
avi_api 2 2 PATCH '{"add": {"ipam_provider_ref": "/api/ipamdnsproviderprofile/?name=ipam-avi", "dns_provider_ref": "/api/ipamdnsproviderprofile/?name=dns-avi"}}' "api/cloud/${cloud_uuid}"

#
# network update - static VIP pool on the overlay segment
#
vip_cidr=$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .avi_ipam_vip.cidr')
vip_pool=$(echo ${nsx_segments_overlay} | jq -c -r '.[] | select(has("avi_ipam_vip")) | .avi_ipam_vip.pool')
network_update_json=$(jq -n --arg addr "$(echo ${vip_cidr} | cut -d'/' -f1)" --arg mask "$(echo ${vip_cidr} | cut -d'/' -f2)" \
  --arg begin "$(echo ${vip_pool} | cut -d'-' -f1)" --arg end "$(echo ${vip_pool} | cut -d'-' -f2)" \
  '{add: {dhcp_enabled: true, exclude_discovered_subnets: true, configured_subnets: [{
      prefix: {ip_addr: {addr: $addr, type: "V4"}, mask: $mask},
      static_ip_ranges: [{type: "STATIC_IPS_FOR_VIP", range: {begin: {addr: $begin, type: "V4"}, end: {addr: $end, type: "V4"}}}]
  }]}}')
avi_api 2 2 PATCH "${network_update_json}" "api/network/${vip_uuid}"

#
# Pulse cloud-services registration - optional, skipped entirely unless
# spec.sddc.avi.jwt_token/account_id are set.
#
if [ -n "${avi_jwt_token}" ] && [ -n "${avi_account_id}" ]; then
  avi_api 2 2 GET "" api/albservices/status
  avi_api 2 2 POST "$(jq -n --arg t "${avi_jwt_token}" '{jwt_token: $t}')" api/portal/refresh-access-token
  log_only "waiting 20 seconds"
  sleep 20
  random_string=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
  avi_api 2 2 POST "$(jq -n --arg n "workshop-demo-${random_string}" --arg acct "${avi_account_id}" '{name: $n, description: "Registration and deregistration", email: "avi.workshop@broadcom.com", account_id: $acct}')" api/albservices/register
  log_only "waiting 20 seconds"
  sleep 20
  avi_api 2 2 PATCH '{"replace": {"feature_opt_in_status": {"enable_appsignature_sync": true, "enable_ip_reputation": true, "enable_pulse_case_management": false, "enable_pulse_waf_management": true, "enable_user_agent_db_sync": false}, "waf_config": {"enable_auto_download_waf_signatures": true, "enable_waf_signatures_notifications": true}}}' api/albservicesconfig
  log_only "waiting 10 seconds"
  sleep 10
  avi_api 2 2 GET "" api/albservices/pool
  avi_api 2 2 POST "$(jq -n --arg id "$(echo ${response_body} | jq -c -r '.results[0].pool_id')" '{pool_id: $id}')" api/licensing/v1/cloud/subscribe
else
  log_only "avi_jwt_token/avi_account_id not set, skipping Pulse cloud-services registration"
fi

#
# availability zones (one per nested ESXi host, via Avi's NSX-T transport
# node discovery) and the default Service Engine Group
#
avi_api 2 2 GET "" api/vcenterserver
vcenter_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
log_only "waiting 10 seconds"
sleep 10
avi_api 2 2 GET "" api/cloud
cloud_uuid=$(echo ${response_body} | jq -c -r --arg arg "CLOUD_NSXT" '.results[] | select(.vtype == $arg) | .uuid')
log_only "waiting 60 seconds"
sleep 60
# transport_zone_id is required here even though neither the reference
# project's own script nor Avi's inferred-from-cloud-config behavior
# includes it - confirmed empirically (fails with "Transportzone path
# missing" / HTTP 500 without it, works with it) against this Avi
# version (32.1.1), despite the cloud object's own nsxt_configuration
# already having a valid transport_zone set. tz_id was already looked up
# earlier in this same script (transport zone discovery, above).
avi_api 2 2 POST "$(jq -n --arg c "${cloud_uuid}" --arg v "${vcenter_uuid}" --arg tz "${tz_id}" '{cloud_uuid: $c, vcenter_uuid: $v, transport_zone_id: $tz}')" api/nsxt/transportnodes
list_az_uuids="[]"
while read -r item
do
  az_json=$(jq -n --arg hid "$(echo ${item} | jq -c -r '.vc_mobj_id')" --arg vc "${vcenter_uuid}" --arg cloud "${cloud_uuid}" --arg n "az-$(echo ${item} | jq -c -r '.name')" \
    '{az_hosts: [{host_ids: [$hid], vcenter_ref: $vc}], cloud_ref: $cloud, name: $n}')
  log_only "waiting 10 seconds"
  sleep 10
  avi_api 2 2 POST "${az_json}" api/availabilityzone
  list_az_uuids=$(echo ${list_az_uuids} | jq -c --arg id "$(echo ${response_body} | jq -c -r '.uuid')" '. + [$id]')
done < <(echo ${response_body} | jq -c -r '.resource.nsxt_transportnodes[]')

avi_api 2 2 GET "" "api/serviceenginegroup?name=Default-Group&cloud_ref=${cloud_uuid}"
serviceenginegroup_uuid=$(echo ${response_body} | jq -c -r '.results[0].uuid')
seg_update_json=$(jq -n --argjson azs "$(echo ${list_az_uuids} | jq -c '.[-3:]')" \
  '{replace: {availability_zone_refs: $azs, cpu_reserve: false, mem_reserve: false, se_deprovision_delay: 120, buffer_se: 0, min_scaleout_per_vs: 1, algo: "PLACEMENT_ALGO_PACKED", ha_mode: "HA_MODE_SHARED", vcpus_per_se: 1, memory_per_se: 2048, disk_per_se: 15, realtime_se_metrics: {duration: 30, enable: false}}}')
avi_api 2 2 PATCH "${seg_update_json}" "api/serviceenginegroup/${serviceenginegroup_uuid}"

#
# DNS VsVip + DNS virtual service, then wait for it to come up
#
vsvip_json=$(jq -n --arg cloud "${cloud_url}" --arg fqdn "dns.${avi_subdomain}.${domain}" --arg ref "/api/network/${vip_uuid}" \
  --arg addr "$(echo ${vip_cidr} | cut -d'/' -f1)" --arg mask "$(echo ${vip_cidr} | cut -d'/' -f2)" --arg vrf "/api/vrfcontext/?name=${t1_vip_name}" \
  '{cloud_ref: $cloud, dns_info: [{algorithm: "DNS_RECORD_RESPONSE_CONSISTENT_HASH", fqdn: $fqdn, ttl: 30, type: "DNS_RECORD_A"}],
    name: "dns-VsVip", vip: [{auto_allocate_ip: true, ipam_network_subnet: {network_ref: $ref, subnet: {ip_addr: {addr: $addr, type: "V4"}, mask: $mask}}}],
    vrf_context_ref: $vrf}')
avi_api 2 2 POST "${vsvip_json}" api/vsvip
vsvip_url=$(echo ${response_body} | jq -c -r '.url')
avi_api 2 2 POST "$(jq -n --arg cloud "${cloud_url}" --arg vsvip "${vsvip_url}" '{cloud_ref: $cloud, name: "dns-vs", vsvip_ref: $vsvip, application_profile_ref: "/api/applicationprofile/?name=System-DNS", network_profile_ref: "/api/networkprofile/?name=System-UDP-Per-Pkt", services: [{port: 53, enable_ssl: false}]}')" api/virtualservice

avi_api 2 2 GET "" api/systemconfiguration
avi_api 2 2 PUT "$(echo ${response_body} | jq -c '. + {dns_virtualservice_refs: ["/api/virtualservice/?name=dns-vs"]}')" api/systemconfiguration

count_dns=1 ; pause_dns=10 ; dns_vs_status=""
until [[ ${dns_vs_status} == "OPER_UP" ]]
do
  avi_api 2 2 GET "" api/virtualservice-inventory
  dns_vs_status=$(echo ${response_body} | jq -c -r '.results[0].runtime.oper_status.state')
  if [[ ${dns_vs_status} == "OPER_UP" ]]; then
    break
  fi
  sleep ${pause_dns}
  ((count_dns++))
  if [[ "${count_dns}" -eq 120 ]]; then
    log_notify "ERROR: Unable to get the DNS VS UP after ${count_dns} attempts of ${pause_dns} seconds"
    exit 100
  fi
done
log_notify "DNS VS UP after ${count_dns} attempts of ${pause_dns} seconds"

#
# demo traffic generator - adds loopback IPs to source synthetic client
# traffic from, and a cron job that spreads requests (with random user
# agents) across any virtual-hosted VS every minute.
#
cat > /home/ubuntu/avi/traffic_gen_client.sh <<TRAFFICGEN_EOF
#!/bin/bash
IFS=\$'\n'
username="admin"
password="${generic_password}"
ip="${ip_avi}"
rm -f /home/ubuntu/avi/avi_cookie.txt
amount_of_ip=\$(ip a show lo: | grep -v 127 | grep -v inet6 | grep inet | cut -d" " -f6 | cut -d"/" -f1 | wc -l)
amount_of_user_agent=\$(jq -c -r '. | length' /home/ubuntu/json/user_agents.json)
curl -s -k -X POST -H "Content-Type: application/json" -d "{\\"username\\": \\"\$username\\", \\"password\\": \\"\$password\\"}" -c /home/ubuntu/avi/avi_cookie.txt "https://\$ip/login" > /dev/null
curl_tenants=\$(curl -s -k -X GET -H "Content-Type: application/json" -b /home/ubuntu/avi/avi_cookie.txt "https://\$ip/api/tenant")
echo \$curl_tenants | jq -c -r '.results[].name' | while read tenant
do
  if [[ \$tenant != "admin" ]]; then
    curl_virtualservice=\$(curl -s -k -X GET -H "Content-Type: application/json" -H "X-Avi-Tenant: \$tenant" -b /home/ubuntu/avi/avi_cookie.txt "https://\$ip/api/virtualservice")
    if [[ \$(echo \$curl_virtualservice | jq -c -r '.results | length') -gt 0 ]] ; then
      for vs in \$(echo \$curl_virtualservice | jq -c -r .results[])
      do
        if [[ \$(echo \$vs | jq -c -r .type) == "VS_TYPE_VH_CHILD" ]] ; then
          for vh_match in \$(echo \$vs | jq -c -r .vh_matches[])
          do
            host=\$(echo \$vh_match | jq -c -r '.host')
            random_number=\$(( RANDOM % 45 + 1 ))
            for i in \$(seq 1 "\$random_number")
            do
              ip_index=\$(( RANDOM % amount_of_ip + 1 ))
              user_agent_index=\$(( RANDOM % amount_of_user_agent ))
              user_agent=\$(jq -c -r --arg i "\$user_agent_index" '.[\$i | tonumber]' /home/ubuntu/json/user_agents.json)
              ip_source=\$(ip a show lo: | grep -v 127 | grep -v inet6 | grep inet | cut -d" " -f6 | cut -d"/" -f1 | head -\$ip_index | tail +\$ip_index)
              curl --interface \$ip_source -A "\$user_agent" -k -o /dev/null "https://\$host"
              curl --interface \$ip_source -A "\$user_agent" -k -o /dev/null "http://\$host"
              sleep 0.5
            done
            for i in \$(seq 1 2)
            do
              ip_index=\$(( RANDOM % amount_of_ip + 1 ))
              user_agent_index=\$(( RANDOM % amount_of_user_agent ))
              user_agent=\$(jq -c -r --arg i "\$user_agent_index" '.[\$i | tonumber]' /home/ubuntu/json/user_agents.json)
              ip_source=\$(ip a show lo: | grep -v 127 | grep -v inet6 | grep inet | cut -d" " -f6 | cut -d"/" -f1 | head -\$ip_index | tail +\$ip_index)
              curl --interface \$ip_source -A "\$user_agent" -k -o /dev/null "https://\$host/wrong-path"
              sleep 0.5
            done
          done
        fi
      done
    fi
  fi
done
TRAFFICGEN_EOF
chmod u+x /home/ubuntu/avi/traffic_gen_client.sh

echo ${avi_loopback_ips} | jq -c -r . | tee /home/ubuntu/json/loopback_ips.json > /dev/null
echo ${avi_user_agents} | jq -c -r . | tee /home/ubuntu/json/user_agents.json > /dev/null
echo ${avi_loopback_ips} | jq -c -r '.[]' | while read -r lo_ip ; do sudo ip a add ${lo_ip} dev lo: ; done
(crontab -l 2>/dev/null; echo "* * * * * /home/ubuntu/avi/traffic_gen_client.sh") | crontab -
log_notify "Avi ctrl configured, traffic generator scheduled"

log_notify "06-avi-configure.sh complete"
