#!/bin/bash
#
# Per-org Avi Controller user account, one per org in vcf_a_organizations.
# Tenant is the org's own Avi tenant (same name as org_name) - auto-
# created by NSX-T's PROVIDER_MANAGED Avi integration when
# configure_vcfa.sh enables Avi for that org (confirmed live 2026-09-28:
# Avi's own api/tenant already has a tenant literally named org-1/org-2/
# ... by the time this runs). Password matches gw-accounts.sh's own
# per-org derivation exactly (sha256(gw_accounts_secret + org_name),
# truncated) - same account/password, just a login on Avi instead of a
# Linux account on gw. Runs last in vcf_bootstrap.sh's phase loop since
# it depends on configure_vcfa.sh having already created each org's Avi
# tenant.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"
vcd_login
log_notify "avi-accounts.sh started"

avi_login
avi_api 3 3 GET "" "api/role?name=Tenant-Admin"
tenant_admin_role_ref=$(echo ${response_body} | jq -c -r '.results[0].url')
if [ -z "${tenant_admin_role_ref}" ] || [ "${tenant_admin_role_ref}" == "null" ]; then
  log_notify "ERROR: Avi role 'Tenant-Admin' not found, aborting avi-accounts.sh"
  exit 100
fi

while read -r item
do
  org_name=$(echo ${item} | jq -c -r '.name')

  avi_api 3 3 GET "" "api/user?name=${org_name}"
  existing_count=$(echo ${response_body} | jq -c -r '.count')
  if [ "${existing_count}" != "0" ]; then
    log_notify "Avi user ${org_name} already exists, skipping creation"
    continue
  fi

  # Not every org necessarily has a PROVIDER_MANAGED Avi tenant (see
  # avi_mode in configure_vcfa.sh) - skip rather than abort the whole
  # run if one's missing.
  avi_api 3 3 GET "" "api/tenant?name=${org_name}"
  tenant_ref=$(echo ${response_body} | jq -c -r '.results[0].url')
  if [ -z "${tenant_ref}" ] || [ "${tenant_ref}" == "null" ]; then
    log_notify "ERROR: Avi tenant ${org_name} not found (enable_avi/avi_mode PROVIDER_MANAGED not set for this org?), skipping Avi account creation for ${org_name}"
    continue
  fi

  org_password=$(echo -n "${gw_accounts_secret}${org_name}" | sha256sum | cut -c1-24)
  user_json=$(jq -n --arg u "${org_name}" --arg p "${org_password}" --arg t "${tenant_ref}" --arg r "${tenant_admin_role_ref}" \
    '{username: $u, password: $p, is_superuser: false, default_tenant_ref: $t, access: [{tenant_ref: $t, role_ref: $r}]}')
  avi_api 3 3 POST "${user_json}" "api/user"
  log_notify "Avi user ${org_name} created (Tenant-Admin, tenant ${org_name})"
done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

log_notify "avi-accounts.sh complete"
