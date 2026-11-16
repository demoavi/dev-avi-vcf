#!/bin/bash
# Sourced by vapp-diagnostics-upload.sh, vapp-diagnostics-command.sh and vapp-diagnostics-ctl.sh. Functions only: nothing runs when it is sourced.
# vApp use case only (see those scripts). Test/override variables: VAPP_DIAG_HOME (default /home/ubuntu), VAPP_DIAG_UUID (skip VCD).

diag_home="${VAPP_DIAG_HOME:-/home/ubuntu}"
work_root="${diag_home}/.vapp-diagnostics"
key_file="${work_root}/log.key"      # spec.diagnostics.log_encryption_key: encrypts the logs AND signs the commands (HMAC)

say() { echo "$(date +%Y-%m-%dT%H:%M:%S%z) ${diag_name:-vapp-diagnostics}: $*"; }

# diag_lock <name>: one run of this script at a time, the second exits quietly (cron every minute / events can overlap)
diag_lock() {
  mkdir -p "${work_root}" 2> /dev/null && chmod 700 "${work_root}"
  exec 9> "${work_root}/lock-${1}"
  flock -n 9 || exit 0
}

# The vApp uuid cache: ${work_root}/uuid.cache holds "<boot id> <uuid>" and is only believed while /proc/sys/kernel/random/boot_id is the same, i.e. until the
# next boot (the old cache in /run was root-owned: ubuntu could not write it). A vApp made from a captured template boots with another boot id, so it asks VCD again.
diag_boot_id() { cat /proc/sys/kernel/random/boot_id 2> /dev/null; }
diag_uuid_cache_get() { local b u; [ -r "${work_root}/uuid.cache" ] || return 0; read -r b u < "${work_root}/uuid.cache"; [ -n "${b}" ] && [ "${b}" == "$(diag_boot_id)" ] && echo "${u}"; return 0; }
diag_uuid_cache_put() { [ -n "$(diag_boot_id)" ] && [ -d "${work_root}" ] && echo "$(diag_boot_id) ${1}" > "${work_root}/uuid.cache.tmp" 2> /dev/null && mv -f "${work_root}/uuid.cache.tmp" "${work_root}/uuid.cache" 2> /dev/null; return 0; }

# diag_init <deployment json>: sets deployment_kind/diagnostics_repo (variables.sh), repo_url and uuid. Returns 1 (and says why, when it is
# worth saying) when this gw has nothing to do: not the vApp use case, no spec.diagnostics, no vApp uuid.
diag_init() {
  local json="${1:-}" container
  [ -f "${diag_home}/bash/variables.sh" ] && source "${diag_home}/bash/variables.sh" < /dev/null
  [ "${deployment_kind:-}" == "vApp" ] || { say "not the vApp use case, nothing to do"; return 1; }
  [ -n "${diagnostics_repo:-}" ] || return 1
  # the ssh alias vapp-diagnostics (host github.com, only the deploy key) is written by gw-setup.sh.tpl
  repo_url="${diagnostics_repo/git@github.com:/git@vapp-diagnostics:}"
  # The vApp uuid comes from VCD (the container of the gw VM), cached per boot (boot id bound, see diag_uuid_cache_get), so a copy of the disk never reports under an old uuid: a vApp made from a
  # captured template has a copy of this disk but its own uuid, so it must not report under the old one.
  uuid="${VAPP_DIAG_UUID:-}"
  [ -z "${uuid}" ] && uuid=$(diag_uuid_cache_get)
  if [ -z "${uuid}" ]; then
    [ -n "${json}" ] && [ -f "${json}" ] || { say "need the deployment json to ask VCD for the vApp uuid"; return 1; }
    jsonFile="${json}"
    source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/functions.sh" < /dev/null
    vcd_login
    [ -n "${vcd_vapp:-}" ] || { say "no .vcd.vapp in ${json} (older gw): the gw VM cannot be told apart from the ones of the other shared vApps, not doing anything"; return 1; }
    container=$(curl -sk "https://${vcd_host}/api/query?type=vm&format=records&pageSize=128$(vcd_vm_filter gw)" \
      -H "Authorization: Bearer ${vcd_auth_token}" -H "Accept: application/*+json;version=${vcd_api_version}" \
      | jq -r '[.record[] | select(.name == "gw") | .container][0] // empty' 2> /dev/null)
    uuid="${container##*/vapp-}"
    case "${uuid}" in [0-9a-f]*-*-*-*-*) ;; *) say "could not get the vApp uuid from VCD (container='${container}')"; return 1 ;; esac
    diag_uuid_cache_put "${uuid}"
  fi
  return 0
}

# diag_activity: one line per bootstrap phase / vcfa_org.sh / cleaning run on the gw ("vcfa_org.sh add org-2"); only real script runs ("bash .../<name>.sh",
# not an ssh command line that merely mentions a name). Used for the conflict check of the commands and for status.json's "activity".
diag_activity() {
  ps -eo pid=,args= | awk '$2 == "bash" && $3 ~ /(vcf_bootstrap|vcfa_org|vcfa_tenant_cleaning|vcfa_provider_bootstrap|vcfa_tenant_bootstrap|supervisor-bootstrap|avi-bootstrap|k8s-bootstrap|git-bootstrap|nsx-bootstrap|nsx-project-vpc|esxi-bootstrap|vcenter-bootstrap|vcf-installer-bootstrap|vcfa-stabilize|gw-accounts|gw-org-api|vcf_shutdown|vault-pki-bootstrap|supervisor-blueprint-watcher)\.sh$/ {n = split($3, a, "/"); print a[n], $4, $5}'
}

# diag_sign <key file>: stdin = the canonical command text, prints the HMAC-SHA256 as hex (python3, so the key never shows up in a command line)
diag_sign() {
  python3 -I -c 'import hmac,hashlib,sys; k=open(sys.argv[1],"rb").read().strip(); print(hmac.new(k, sys.stdin.buffer.read(), hashlib.sha256).hexdigest())' "${1}"
}

# diag_canonical: stdin = command.json, prints the part that is signed (fixed key order and compact, so both sides get the same bytes)
diag_canonical() {
  jq -cS '{id, action, args: (.args // {}), issued_at, expires_at, uuid}'
}

# diag_git <dir> <args...>: git with a bounded network wait (the ssh alias and the deploy key come from ~/.ssh/config)
diag_git() {
  local dir="$1"; shift
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=20 -o BatchMode=yes}" timeout 180 git -C "${dir}" -c user.name="vapp-gw" -c user.email="vapp-gw@localhost" "$@"
}
