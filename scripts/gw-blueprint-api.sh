#!/bin/bash
#
# Installs/refreshes the gw's blueprint API (see gw-blueprint-api.py for the endpoints) as a systemd service on its own
# HTTPS port: the receiver that keeps the dropdown of one input of one VCF-A blueprint in sync with the "app" labels of the
# VMs in each org's Supervisor namespace. The Supervisor side (supervisor-blueprint-watcher.sh, the LAST phase) posts the
# state here; this service holds the VCF-A credentials, validates every project with VCF-A and rewrites the blueprint.
# Runs right after gw-org-api.sh and, unlike it, on both use cases (SDDC and vApp): it is gw-local and needs nothing
# from the SDDC build - VCF-A is only needed when a message arrives (a post for a project whose blueprint does not exist
# yet is dropped and healed by the watcher's next periodic resync).
#
# Switch and names: blueprints.auto_update (enabled, blueprint_name, input_name) of the orgs in spec.sddc.vcf_a.organization_templates/organization_overrides -> blueprint_apps_* in
# variables.sh; the port is variables.json's blueprint_apps block (8444: gw-org-api's default is 8443). Not enabled ->
# skipped. What it creates under /etc/gw-blueprint-api (root only): a self-signed certificate (10 years, SAN = the gw's
# address and name; renewed when the address changed), the HMAC secret shared with the watcher (generated once) and
# config.json (re-read by the server per request: a changed blueprint/input name needs no restart).
#
# Idempotent: the server, unit, certificate and config are only rewritten when their content changed, and the service is
# only restarted when something it cannot re-read at runtime changed. Soft-fails: every problem is a log_notify ERROR and
# exit 0, so this optional service never aborts the vcf_bootstrap.sh pipeline.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"

if [ "${blueprint_apps_enabled}" != "true" ]; then
  log_only "no org enabled blueprints.auto_update, skipping gw-blueprint-api"
  exit 0
fi
vcd_login
log_notify "gw-blueprint-api.sh started"

bpa_fail() {
  log_notify "ERROR: gw-blueprint-api: $1 - the blueprint dropdown will not follow the VM labels, continuing with the rest of the deployment"
  exit 0
}

for tool in openssl jq curl python3 systemctl; do
  command -v "${tool}" > /dev/null 2>&1 || bpa_fail "${tool} is not installed on gw"
done
if ! python3 -c 'import yaml' > /dev/null 2>&1; then
  sudo apt-get install -y python3-yaml > /dev/null 2>&1
  python3 -c 'import yaml' > /dev/null 2>&1 || bpa_fail "PyYAML (python3-yaml) is missing and could not be installed"
fi
case "${blueprint_apps_port}" in
  ''|*[!0-9]*) bpa_fail "blueprint_apps port '${blueprint_apps_port}' is not a number" ;;
esac

api_dir="/opt/gw-blueprint-api"
conf_dir="/etc/gw-blueprint-api"
unit_file="/etc/systemd/system/gw-blueprint-api.service"
needs_restart="false"

# Server code: root-owned copy outside ubuntu's tree, since the service runs as root.
sudo install -d -m 755 -o root -g root "${api_dir}"
if ! sudo cmp -s "${script_dir}/gw-blueprint-api.py" "${api_dir}/server.py"; then
  sudo install -m 755 -o root -g root "${script_dir}/gw-blueprint-api.py" "${api_dir}/server.py"
  needs_restart="true"
  log_notify "gw-blueprint-api: server installed in ${api_dir}"
fi

# The address the service listens on and puts in its certificate: the source of the gw's default route (same derivation
# as gw-org-api.sh's certificate and gw-accounts.sh's WireGuard endpoint). Not 0.0.0.0, so the per-org WireGuard
# tunnels do not see it.
gw_ip=$(ip -4 route get 8.8.8.8 2> /dev/null | grep -oP 'src \K[0-9.]+' | head -1)
[ -n "${gw_ip}" ] || bpa_fail "cannot determine the gw's own address (ip route get 8.8.8.8)"

sudo install -d -m 700 -o root -g root "${conf_dir}"
san="DNS:$(hostname),IP:${gw_ip}"
if ! sudo test -s "${conf_dir}/cert.pem" || ! sudo test -s "${conf_dir}/key.pem" \
   || ! sudo openssl x509 -in "${conf_dir}/cert.pem" -noout -ext subjectAltName 2> /dev/null | grep -q "IP Address:${gw_ip}"; then
  if sudo sh -c "umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=$(hostname)' -addext 'subjectAltName=${san}' -keyout '${conf_dir}/key.pem' -out '${conf_dir}/cert.pem'" > /dev/null 2>&1; then
    needs_restart="true"
    log_notify "gw-blueprint-api: self-signed certificate generated (${san})"
  else
    sudo rm -f "${conf_dir}/key.pem" "${conf_dir}/cert.pem"
    bpa_fail "certificate generation failed"
  fi
fi
sudo chmod 600 "${conf_dir}/key.pem"
sudo chmod 644 "${conf_dir}/cert.pem"

# HMAC secret shared with the watcher: generated once, never rotated here (the watcher phase copies it into the
# Supervisor).
if ! sudo test -s "${conf_dir}/secret"; then
  sudo sh -c "umask 077; openssl rand -hex 32 > '${conf_dir}/secret'" || bpa_fail "cannot generate the HMAC secret"
  needs_restart="true"
  log_notify "gw-blueprint-api: HMAC secret generated"
fi

# Config: VCF-A access (the same admin account the other phases use) + what to update. Written only when it changed.
vcfa_host="https://${basename_sddc}-auto-vip.${domain}"
config_tmp=$(mktemp)
if ! sudo jq -n --arg bind "${gw_ip}" --argjson port "${blueprint_apps_port}" --arg cert "${conf_dir}/cert.pem" \
     --arg key "${conf_dir}/key.pem" --rawfile secret "${conf_dir}/secret" --arg host "${vcfa_host}" \
     --arg pw "${generic_password}" --arg bp "${blueprint_apps_blueprint_name}" --arg input "${blueprint_apps_input_name}" \
     '{bind: $bind, port: $port, cert: $cert, key: $key, secret: ($secret | rtrimstr("\n")), vcfa_host: $host, vcfa_user: "admin",
       vcfa_password: $pw, vcfa_version: "9.1.0", blueprint_name: $bp, input_name: $input, verify_tls: false, max_skew: 60}' > "${config_tmp}"; then
  rm -f "${config_tmp}"
  bpa_fail "config rendering failed"
fi
config_changed="false"
if ! sudo cmp -s "${config_tmp}" "${conf_dir}/config.json"; then
  sudo install -m 600 -o root -g root "${config_tmp}" "${conf_dir}/config.json"
  config_changed="true"
  log_notify "gw-blueprint-api: config written (blueprint ${blueprint_apps_blueprint_name}, input ${blueprint_apps_input_name}, ${gw_ip}:${blueprint_apps_port})"
fi
rm -f "${config_tmp}"
# bind/port/cert are read once at start, the rest per request
if [ "${config_changed}" == "true" ]; then
  needs_restart="true"
fi

unit_content="[Unit]
Description=gw blueprint API (keeps a blueprint dropdown in sync with the VM labels of the Supervisor)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 ${api_dir}/server.py ${conf_dir}/config.json
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target"
printf '%s\n' "${unit_content}" | sudo tee "${unit_file}.new" > /dev/null
if sudo cmp -s "${unit_file}.new" "${unit_file}"; then
  sudo rm -f "${unit_file}.new"
else
  sudo mv "${unit_file}.new" "${unit_file}"
  sudo systemctl daemon-reload
  needs_restart="true"
fi

if ! sudo systemctl enable --now gw-blueprint-api.service > /dev/null 2>&1; then
  bpa_fail "systemctl enable --now gw-blueprint-api.service failed (journalctl -u gw-blueprint-api)"
fi
if [ "${needs_restart}" == "true" ]; then
  sudo systemctl restart gw-blueprint-api.service || log_notify "ERROR: gw-blueprint-api: restart failed"
fi

# Verify with a real request. The server may need a moment after a (re)start.
health_code=""
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  health_code=$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://${gw_ip}:${blueprint_apps_port}/healthz")
  [ "${health_code}" == "200" ] && break
  sleep 1
done
if [ "${health_code}" != "200" ]; then
  bpa_fail "the service does not answer on https://${gw_ip}:${blueprint_apps_port}/healthz (HTTP ${health_code:-none}), see journalctl -u gw-blueprint-api"
fi
log_notify "gw-blueprint-api: listening on https://${gw_ip}:${blueprint_apps_port} (PUT /apps/state, HMAC-authenticated), updating input '${blueprint_apps_input_name}' of blueprint '${blueprint_apps_blueprint_name}'"
