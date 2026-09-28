#!/bin/bash
#
# Per-VCF-A-org Linux accounts on gw, one per org in vcf_a_organizations
# (org-1, org-2, ...). SSH login, password-based - each org's password is
# "VMware1!<4 hex chars from sha256(gw_accounts_secret + org_name)>
# VMware1!" (20 chars total), deliberately independent of generic_password
# (a different secret entirely, so rotating one never affects the other).
# Deterministic and reproducible elsewhere from the same two inputs - no
# separate secret store needed. The VMware1! prefix/suffix bookending a
# short hash segment (not a longer raw hash) is required, not cosmetic -
# confirmed live 2026-09-28 against the sddc reference environment that
# vCenter SSO's own password-strength check has an undocumented 20-
# character MAXIMUM length (21+ is rejected outright, "Password strength
# check" constraint violation, regardless of character-class mix), and
# VCFA's own local-user password policy separately requires at least one
# uppercase/lowercase/digit/special character - a raw hex string (no
# uppercase, no special char) fails VCFA's check, while a longer prefixed
# hex string fails vCenter's length cap. This exact 20-char shape is the
# only one confirmed live to satisfy vCenter, NSX, and VCFA simultaneously
# - see vcfa_tenant_bootstrap.sh's and vcfa_provider_bootstrap.sh's own
# copies of this same derivation, which must stay byte-for-byte identical
# to this one (same login/password across gw SSH, vCenter SSO, Avi,
# NSX, and the VCF-A org user, all for the same org).
#
# Runs first in vcf_bootstrap.sh's phase loop since it has no dependency
# on anything else in the pipeline.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"
vcd_login
log_notify "gw-accounts.sh started"

if ! grep -qE '^\s*PasswordAuthentication\s+yes\s*$' /etc/ssh/sshd_config; then
  if grep -qE '^\s*#?\s*PasswordAuthentication\s' /etc/ssh/sshd_config; then
    sudo sed -i -E 's/^\s*#?\s*PasswordAuthentication\s+.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  else
    echo "PasswordAuthentication yes" | sudo tee -a /etc/ssh/sshd_config >/dev/null
  fi
  sudo systemctl reload ssh
  log_notify "enabled PasswordAuthentication in sshd_config"
fi

while read -r item
do
  org_name=$(echo ${item} | jq -c -r '.name')
  if id "${org_name}" >/dev/null 2>&1; then
    log_notify "account ${org_name} already exists, skipping creation"
  else
    sudo useradd -m -s /bin/bash "${org_name}"
    log_notify "created account ${org_name}"
  fi
  # chpasswd hashes this itself (system default scheme) - no need to
  # pre-hash with openssl passwd. Re-set every run so a rotated
  # gw_accounts_secret (or a manual re-run) always syncs the password,
  # not just at account-creation time.
  org_password="VMware1!$(echo -n "${gw_accounts_secret}${org_name}" | sha256sum | cut -c1-4)VMware1!"
  echo "${org_name}:${org_password}" | sudo chpasswd
done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

log_notify "gw-accounts.sh complete"
