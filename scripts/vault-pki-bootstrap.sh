#!/bin/bash
#
# Vault + cert-manager PKI bootstrap (root/intermediate CA) - optional, gated on any org needing namespace.vault_integration. Runs first, before the SDDC build pipeline, since it has no dependency on any of it; must only complete before configure_vcfa.sh, which reads its root token.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"
vcd_login
log_notify "vault-pki-bootstrap.sh started"

#
# Vault + cert-manager PKI bootstrap - ported from the reference project's
# own cloud-init (templates/userdata_external-gw-trunk.yaml.template), NOT
# from configure_vcfa.sh (that script assumes Vault is already up and only
# reads its root token/TLS cert). Deliberately done here in vcf_bootstrap.sh
# instead of gw's own cloud-init:
#   - gating is trivial here (vcf_a_organizations is already a plain bash
#     variable by this point) - doing it in cloud-init would mean computing
#     the same "does any org need vault" check a second time through a
#     separate Python code path, for a feature nothing else depends on.
#   - matches this project's existing convention of putting every other
#     big, optional, feature-specific phase (Avi deployment/config, NSX
#     Project/VPC, Supervisor enablement, VCFA org provisioning above) in
#     this script rather than cloud-init.
#   - cloud-init only ever runs once per gw - a bug in PKI/cert setup here
#     just needs a re-run of this script, not a fresh VM.
#   - vault_integration is per-namespace, but Vault itself is a single
#     shared instance on gw - only worth standing up once, gated on
#     whether ANY org in vcf_a_organizations actually wants it, not
#     repeated per org.
# apt's vault package and every vault_pki_*/vault_secret_file_path value
# used below are already provisioned/exported unconditionally regardless
# of this gate (cheap, harmless if unused) - only the actual service
# start/init/PKI setup is conditional.
#
# The reference project runs this whole block directly as root in
# cloud-init (no user-drop at all) - this port runs as ubuntu throughout
# (see vcf_bootstrap.sh's own top comment), so every operation below that
# touches /opt/vault, /etc/vault.d, or systemd needs an explicit sudo that
# the reference never needed. Confirmed elsewhere in this project (see
# configure_vcfa.sh's own "sudo cat /opt/vault/tls/tls.crt") that this
# user has passwordless sudo. Where the target itself is root-owned,
# "sudo tee file" is used instead of "cmd > file" or "sudo cmd > file" -
# a plain ">" redirect is opened by the CURRENT (unprivileged) shell
# before the command ever runs, so sudo on the command itself doesn't
# help; tee's own file-writing happens inside the (sudo'd) tee process
# instead, which does work.
if echo "${vcf_a_organizations}" | jq -e 'any(.[]; .namespace.vault_integration.enabled == true)' > /dev/null 2>&1; then
  log_notify "at least one org needs vault_integration, bootstrapping Vault"
  # Fail fast: none of the vault CLI calls below check their own exit
  # status, so without this a failure (e.g. an empty vault_pki_* var)
  # would silently fall through to the final "Vault bootstrap complete"
  # log_notify below, exactly as happened live on 2026-09-21 - the
  # unseal/root-CA/intermediate-CA calls all failed quietly against an
  # empty bash/variables.sh and the script still reported success.
  # pipefail is needed too since several of these run through `| tee`/
  # `| jq` pipelines, which set -e alone won't catch a failure in.
  set -e -o pipefail
  sudo mkdir -p /opt/vault/tls
  key_file="/opt/vault/tls/tls.key"
  cert_conf_file="/opt/vault/tls/crt.conf"
  cert_file="/opt/vault/tls/tls.crt"
  sudo openssl genrsa -out ${key_file} 4096
  sudo tee ${cert_conf_file} > /dev/null <<CERT_CONF_EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = ${domain}
O = Organization
L = City
ST = State
C = US

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = vault.${domain}
IP.1 = ${ip_gw}
CERT_CONF_EOF
  sudo openssl req -new -x509 -key ${key_file} -out ${cert_file} -days 365 -config ${cert_conf_file} -extensions v3_req
  sudo mkdir -p /etc/vault.d
  sudo mv /etc/vault.d/vault.hcl /etc/vault.d/vault.hcl.ori 2>/dev/null || true
  export VAULT_ADDR="https://127.0.0.1:8200"
  # api_addr breaks out of the single-quoted string to expand ${ip_gw}
  # ("'"${ip_gw}"'" - close quote, double-quoted expansion, reopen quote)
  # rather than leaving it inside the single-quoted block like the rest of
  # this string - a bare ${ip_gw} there would never expand at all
  # (confirmed live: literally shipped as api_addr = "https://${ip_gw}:8200"
  # in the real rendered vault.hcl). Matches the technique the reference
  # project's own cloud-init version of this same config already used
  # correctly (concatenating '$ip_gw' outside the quotes).
  vault_config='
  storage "file" {
    path    = "/opt/vault/data"
  }
    listener "tcp" {
      address     = "0.0.0.0:8200"
      tls_disable = "false"
      tls_cert_file = "/opt/vault/tls/tls.crt"
      tls_key_file = "/opt/vault/tls/tls.key"
    }
    ui = true
    api_addr = "https://'"${ip_gw}"':8200"'
  echo "${vault_config}" | sudo tee /etc/vault.d/vault.hcl
  sudo systemctl start vault
  sudo systemctl enable vault
  # Idempotency: a re-run of just this phase script against a gw where
  # Vault already got initialized (e.g. retrying after a later phase
  # failed) must not hard-fail on vault operator init's "already
  # initialized" error - reuse the existing secret file instead.
  if vault status -tls-skip-verify 2>/dev/null | grep -q "Initialized.*true"; then
    log_notify "Vault already initialized, reusing existing ${vault_secret_file_path}"
  else
    vault operator init -key-shares=1 -key-threshold=1 -tls-skip-verify -format json | tee ${vault_secret_file_path}
  fi
  vault operator unseal -tls-skip-verify $(jq -c -r .unseal_keys_hex[0] ${vault_secret_file_path})
  vault login -tls-skip-verify $(jq -c -r .root_token ${vault_secret_file_path})
  # root ca
  vault secrets enable -tls-skip-verify ${vault_pki_name}
  vault secrets tune -tls-skip-verify -max-lease-ttl=${vault_pki_max_lease_ttl} "${vault_pki_name}"
  vault write -tls-skip-verify -field=certificate ${vault_pki_name}/root/generate/internal common_name="${vault_pki_cert_common_name}" issuer_name="${vault_pki_cert_issuer_name}" ttl=${vault_pki_cert_ttl} > ${vault_pki_cert_path}
  vault write -tls-skip-verify ${vault_pki_name}/roles/${vault_pki_role_name} allow_any_name=true
  vault write -tls-skip-verify ${vault_pki_name}/config/urls issuing_certificates="https://${ip_gw}:8200/v1/${vault_pki_role_name}/ca" crl_distribution_points="https://${ip_gw}:8200/v1/${vault_pki_role_name}/crl"
  # intermediate ca
  vault secrets enable -tls-skip-verify -path=${vault_pki_intermediate_name} ${vault_pki_name}
  vault secrets tune -tls-skip-verify -max-lease-ttl=${vault_pki_intermediate_max_lease_ttl} ${vault_pki_intermediate_name}
  vault write -tls-skip-verify -format=json ${vault_pki_intermediate_name}/intermediate/generate/internal common_name="${vault_pki_intermediate_cert_common_name}" issuer_name="${vault_pki_intermediate_cert_issuer_name}" | jq -r '.data.csr' | tee ${vault_pki_intermediate_cert_path}
  vault write -tls-skip-verify -format=json ${vault_pki_name}/root/sign-intermediate issuer_ref="${vault_pki_cert_issuer_name}" csr=@${vault_pki_intermediate_cert_path} format=pem_bundle ttl="${vault_pki_intermediate_max_lease_ttl}" | jq -r '.data.certificate' | tee ${vault_pki_intermediate_cert_path_signed}
  vault write -tls-skip-verify ${vault_pki_intermediate_name}/intermediate/set-signed certificate=@${vault_pki_intermediate_cert_path_signed}
  vault write -tls-skip-verify ${vault_pki_intermediate_name}/roles/${vault_pki_intermediate_role_name} issuer_ref="$(vault read -tls-skip-verify -field=default ${vault_pki_intermediate_role_name}/config/issuers)" allowed_domains="${domain}" allow_subdomains=${vault_pki_intermediate_role_allow_subdomains} max_ttl="${vault_pki_intermediate_role_max_ttl}"
  log_notify "Vault bootstrap complete"
else
  log_notify "no org needs vault_integration, skipping Vault bootstrap"
fi
