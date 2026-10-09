#!/bin/bash
#
# vApp use case only: installs/refreshes the gw's org-assignment API (see
# gw-org-api.py for the endpoints) as a systemd service on its own HTTPS
# port with a self-signed certificate and HTTP basic auth. Runs right after
# gw-accounts.sh, which creates the per-org accounts this API hands out.
#
# Opt-in via the CR's spec.vms.gw.org_api (username/password, optional
# port), rendered into variables.sh as org_api_username/org_api_password/
# org_api_port by userdata.py. Not set -> skipped (an unauthenticated
# credential-handing API is never started). Idempotent: the server, unit,
# certificate and config are only rewritten when their content changed, and
# the service is only restarted when something it can't re-read at runtime
# changed (the config itself is re-read per request, so a changed org list
# or password needs no restart).
#
# Soft-fails: every problem is a log_notify ERROR and exit 0, so a problem
# with this optional API never aborts the vcf_bootstrap.sh pipeline.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

if [ "${deployment_kind}" != "vApp" ]; then
  exit 0
fi
vcd_login
log_notify "gw-org-api.sh started"

if [ -z "${org_api_username}" ] || [ -z "${org_api_password}" ]; then
  log_notify "gw-org-api: spec.vms.gw.org_api not set (org_api_username/org_api_password empty in variables.sh), skipping"
  exit 0
fi
case "${org_api_username}" in
  *:*) log_notify "ERROR: gw-org-api: org_api_username must not contain ':' (basic auth), skipping"; exit 0 ;;
esac
org_api_port="${org_api_port:-8443}"
for tool in python3 openssl jq curl; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log_notify "ERROR: gw-org-api: ${tool} not found, skipping"
    exit 0
  fi
done

api_dir="/opt/gw-org-api"
conf_dir="/etc/gw-org-api"
unit_file="/etc/systemd/system/gw-org-api.service"
needs_restart="false"

# Server code: root-owned copy outside ubuntu's tree, since the service
# runs as root.
sudo install -d -m 755 -o root -g root "${api_dir}"
if ! sudo cmp -s "${script_dir}/gw-org-api.py" "${api_dir}/server.py"; then
  sudo install -m 755 -o root -g root "${script_dir}/gw-org-api.py" "${api_dir}/server.py"
  needs_restart="true"
  log_notify "gw-org-api: server installed in ${api_dir}"
fi

# Self-signed certificate, created once (10 years). SAN = the gw's own IP
# (source of its default route, same derivation as gw-accounts.sh's WireGuard
# endpoint); clients are expected to skip verification (curl -k).
sudo install -d -m 700 -o root -g root "${conf_dir}"
if ! sudo test -s "${conf_dir}/cert.pem" || ! sudo test -s "${conf_dir}/key.pem"; then
  gw_ip=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
  san="DNS:$(hostname)"
  [ -n "${gw_ip}" ] && san="${san},IP:${gw_ip}"
  if sudo sh -c "umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=$(hostname)' -addext 'subjectAltName=${san}' -keyout '${conf_dir}/key.pem' -out '${conf_dir}/cert.pem'" >/dev/null 2>&1; then
    needs_restart="true"
    log_notify "gw-org-api: self-signed certificate generated (${san})"
  else
    sudo rm -f "${conf_dir}/key.pem" "${conf_dir}/cert.pem"
    log_notify "ERROR: gw-org-api: certificate generation failed, skipping"
    exit 0
  fi
fi

# Config: credentials, port, the info fields and bookmarks below, and every org that has an account on this gw
# with the password gw-accounts.sh gave it (same formula). The password never
# appears in a command line: jq reads it from the environment, sudo tee from
# stdin. Root-only 600. Re-read by the server on every request.
orgs_json="[]"
while read -r org_name
do
  [ -n "${org_name}" ] || continue
  if ! id "${org_name}" >/dev/null 2>&1; then
    continue
  fi
  org_password="VMware1!$(echo -n "${gw_accounts_secret}${org_name}" | sha256sum | cut -c1-4)VMware1!"
  orgs_json=$(ORG_PW="${org_password}" jq -c --arg n "${org_name}" '. += [{"name": $n, "password": env.ORG_PW}]' <<< "${orgs_json}")
done < <(echo "${vcf_a_organizations}" | jq -r '.[].name')
# Extra fields returned with every POST /org: the vCenter SSO domain
# (info) and the bookmarks - one {name, url} per service the student logs
# in to. The hostnames are the very records gw-setup.sh.tpl puts in the gw's
# DNS zone (-vc01, -nsx01, the NSX VIP; -avi, the Avi cluster VIP;
# -auto-vip, VCF Automation), built from the same basename_sddc/domain, so
# nothing is hardcoded and a bookmark can't point at a name the zone doesn't
# serve. One line per service: <label>|<hostname without domain>[|<path>]. A path may contain
# {org_name}, which the server replaces by the org it assigns on each POST /org (the VCF Automation
# tenant URL is per org); it is kept as a literal placeholder in the config.
sso_domain=$(jq -c -r '.sddc.vcenter.ssoDomain // empty' "${jsonFile}")
info_json=$(jq -n -c --arg sso "${sso_domain}" '{sso_domain: $sso}')
bookmarks_json="[]"
while IFS='|' read -r bookmark_name bookmark_host bookmark_path
do
  [ -n "${bookmark_name}" ] || continue
  bookmarks_json=$(jq -c --arg n "${bookmark_name}" --arg u "https://${bookmark_host}.${domain}${bookmark_path}" '. += [{name: $n, url: $u}]' <<< "${bookmarks_json}")
done <<BOOKMARKS
vCenter|${basename_sddc}-vc01
NSX|${basename_sddc}-nsx01
Avi|${basename_sddc}-avi
VCF Automation|${basename_sddc}-auto-vip|/tenant/{org_name}/
BOOKMARKS
new_conf=$(API_USER="${org_api_username}" API_PW="${org_api_password}" jq -n -c \
  --argjson orgs "${orgs_json}" --argjson port "${org_api_port}" --argjson info "${info_json}" --argjson bookmarks "${bookmarks_json}" \
  --arg cert "${conf_dir}/cert.pem" --arg key "${conf_dir}/key.pem" \
  '{username: env.API_USER, password: env.API_PW, port: $port, cert: $cert, key: $key, home_base: "/home", info: $info, bookmarks: $bookmarks, orgs: $orgs}')
if [ -z "${new_conf}" ]; then
  log_notify "ERROR: gw-org-api: config rendering failed (is org_api_port '${org_api_port}' a number?), skipping"
  exit 0
fi
old_port=$(sudo jq -r '.port // empty' "${conf_dir}/config.json" 2>/dev/null)
printf '%s\n' "${new_conf}" | sudo sh -c "umask 077; cat > '${conf_dir}/config.json.new'"
if sudo cmp -s "${conf_dir}/config.json.new" "${conf_dir}/config.json"; then
  sudo rm -f "${conf_dir}/config.json.new"
else
  sudo mv "${conf_dir}/config.json.new" "${conf_dir}/config.json"
  log_notify "gw-org-api: config written ($(echo "${orgs_json}" | jq 'length') orgs, port ${org_api_port})"
  if [ -n "${old_port}" ] && [ "${old_port}" != "${org_api_port}" ]; then
    needs_restart="true"
  fi
fi

unit_content="[Unit]
Description=gw org-assignment API
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 ${api_dir}/server.py ${conf_dir}/config.json
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target"
printf '%s\n' "${unit_content}" | sudo tee "${unit_file}.new" >/dev/null
if sudo cmp -s "${unit_file}.new" "${unit_file}"; then
  sudo rm -f "${unit_file}.new"
else
  sudo mv "${unit_file}.new" "${unit_file}"
  sudo systemctl daemon-reload
  needs_restart="true"
fi

if ! sudo systemctl enable --now gw-org-api.service >/dev/null 2>&1; then
  log_notify "ERROR: gw-org-api: systemctl enable --now gw-org-api.service failed (journalctl -u gw-org-api)"
  exit 0
fi
if [ "${needs_restart}" == "true" ]; then
  sudo systemctl restart gw-org-api.service || log_notify "ERROR: gw-org-api: restart failed"
fi

# Verify with a real authenticated request (credentials via curl's stdin
# config, not argv). The server may need a moment after a (re)start.
api_check_code=""
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  api_check_code=$(printf 'user = "%s"\n' "$(printf '%s:%s' "${org_api_username}" "${org_api_password}" | sed 's/[\\"]/\\&/g')" \
    | curl -sk -m 5 -K - -o /tmp/gw-org-api-check.json -w '%{http_code}' "https://127.0.0.1:${org_api_port}/orgs")
  [ "${api_check_code}" == "200" ] && break
  sleep 1
done
if [ "${api_check_code}" == "200" ]; then
  log_notify "gw-org-api active on https://<gw>:${org_api_port} ($(jq '.orgs | length' /tmp/gw-org-api-check.json) orgs available)"
else
  log_notify "ERROR: gw-org-api: authenticated GET /orgs returned '${api_check_code}' (journalctl -u gw-org-api)"
fi
rm -f /tmp/gw-org-api-check.json
log_notify "gw-org-api.sh complete"
