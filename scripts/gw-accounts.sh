#!/bin/bash
#
# Per-VCF-A-org Linux accounts on gw, one per org in vcf_a_organizations
# (org-1, org-2, ...). SSH login, password-based - each org's password is
# sha256(gw_accounts_secret + org_name), truncated, deliberately
# independent of generic_password (a different secret entirely, so
# rotating one never affects the other). Deterministic and reproducible
# elsewhere from the same two inputs - no separate secret store needed.
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
  org_password=$(echo -n "${gw_accounts_secret}${org_name}" | sha256sum | cut -c1-24)
  echo "${org_name}:${org_password}" | sudo chpasswd
done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

log_notify "gw-accounts.sh complete"
