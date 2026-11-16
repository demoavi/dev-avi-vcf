#!/bin/bash
#
# The other end of the vapp-diagnostics channel: run it on any machine that holds the repo's deploy key (the operator host), NOT on a gw.
# Lists the vApps that report to the private repo, shows their status and decrypted logs, and sends them a signed command
# (vapp-diagnostics-command.sh on the gw checks and runs it). Read-only except for `send`, which writes one file on main.
#
#   vapp-diagnostics-ctl.sh [options] list
#   vapp-diagnostics-ctl.sh [options] status <uuid>
#   vapp-diagnostics-ctl.sh [options] log    <uuid> [<command id>]    the bootstrap log, or the output of that command (decrypted)
#   vapp-diagnostics-ctl.sh [options] send   <uuid> <action> [--args '<json>'] [--ttl <seconds, default 3600, max 604800>] [--id <id>]
#     actions: status, upload-now, org-delete-all, org-add-all, org-delete, org-add, bootstrap-from (see vapp-diagnostics-command.sh)
#     e.g.  send <uuid> org-delete-all --args '{"dry_run": true}'      send <uuid> bootstrap-from --args '{"phase": "avi-bootstrap"}'
# options: --repo <git url, default git@github.com:demoavi/vapp-diagnostics.git>  --ssh-key <default ~/.ssh/id_vapp_diagnostics>
#          --log-key <the CR's log_encryption_key as a file, default ~/creds/vapp-diagnostics-log.key>
# The <uuid> is the vApp's VCD id (the part after "vapp-" in urn:vcloud:vapp:<uuid>); `list` shows the ones that report.

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "${script_dir}/vapp-diagnostics-common.sh"
repo="git@github.com:demoavi/vapp-diagnostics.git"; ssh_key="${HOME}/.ssh/id_vapp_diagnostics"; log_key="${HOME}/creds/vapp-diagnostics-log.key"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:?}"; shift 2 ;;
    --ssh-key) ssh_key="${2:?}"; shift 2 ;;
    --log-key) log_key="${2:?}"; shift 2 ;;
    *) break ;;
  esac
done
action="${1:-}"; shift
[ -f "${ssh_key}" ] || { echo "no ssh key ${ssh_key}" >&2; exit 1; }
export GIT_SSH_COMMAND="ssh -i ${ssh_key} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"
tmp=$(mktemp -d); trap 'rm -rf "${tmp}"' EXIT
git init -q --bare "${tmp}/r" && git -C "${tmp}/r" remote add origin "${repo}"
fetch_instances() { git -C "${tmp}/r" fetch -q --depth 1 origin '+refs/heads/instance/*:refs/remotes/inst/*' 2> /dev/null; }
show_file() { git -C "${tmp}/r" show "refs/remotes/inst/${1}:instances/${1}/${2}" 2> /dev/null; }
decrypt() { openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:${log_key}" | gunzip; }

case "${action}" in
  list)
    fetch_instances
    for ref in $(git -C "${tmp}/r" for-each-ref --format='%(refname:short)' refs/remotes/inst/ 2> /dev/null); do
      u="${ref#origin/}"; u="${u#inst/}"
      show_file "${u}" status.json | jq -r --arg u "${u}" '"\($u)  \(.vapp_name // "-")  state=\(.state // "-")  phase=\(.phase // "-")  exit=\(.phase_exit_code // "-")  command=\(.command.action // "-"):\(.command.state // "-")  uploaded=\(.uploaded_at // "-")"'
    done ;;
  status)
    u="${1:?uuid}"; fetch_instances; show_file "${u}" status.json | jq . || { echo "no status for ${u}" >&2; exit 1; } ;;
  log)
    u="${1:?uuid}"; f="vcf_bootstrap.log.gz.enc"; [ -n "${2:-}" ] && f="command-${2}.log.gz.enc"
    [ -s "${log_key}" ] || { echo "no log key ${log_key}" >&2; exit 1; }
    fetch_instances; show_file "${u}" "${f}" | decrypt || { echo "could not read ${f} of ${u}" >&2; exit 1; } ;;
  send)
    u="${1:?uuid}"; act="${2:?action}"; shift 2
    args='{}'; ttl=3600; id="$(date +%Y%m%d-%H%M%S)-${RANDOM}"
    while [ $# -gt 0 ]; do
      case "$1" in --args) args="${2:?}"; shift 2 ;; --ttl) ttl="${2:?}"; shift 2 ;; --id) id="${2:?}"; shift 2 ;; *) echo "unknown argument $1" >&2; exit 1 ;; esac
    done
    echo "${args}" | jq -e 'type == "object"' > /dev/null 2>&1 || { echo "--args must be a JSON object" >&2; exit 1; }
    case "${ttl}" in ''|*[!0-9]*) echo "--ttl is a number of seconds" >&2; exit 1 ;; esac
    [ "${ttl}" -le 604800 ] || { echo "--ttl is 604800 (7 days) at most" >&2; exit 1; }
    [ -s "${log_key}" ] || { echo "no key ${log_key}: the command cannot be signed" >&2; exit 1; }
    now=$(date +%s)
    cmd=$(jq -n --arg id "${id}" --arg action "${act}" --argjson args "${args}" --argjson i "${now}" --argjson e "$((now + ttl))" --arg uuid "${u}" \
      '{id: $id, action: $action, args: $args, issued_at: $i, expires_at: $e, uuid: $uuid}')
    sig=$(echo "${cmd}" | diag_canonical | diag_sign "${log_key}")
    cmd=$(echo "${cmd}" | jq --arg sig "${sig}" '. + {sig: $sig}')
    w="${tmp}/w"; mkdir -p "${w}"; git -C "${w}" init -q; git -C "${w}" remote add origin "${repo}"
    for attempt in 1 2 3; do
      if git -C "${w}" fetch -q --depth 1 origin main 2> /dev/null; then git -C "${w}" checkout -q -B main FETCH_HEAD; else git -C "${w}" checkout -q --orphan main 2> /dev/null; fi
      mkdir -p "${w}/instances/${u}"; echo "${cmd}" | jq . > "${w}/instances/${u}/command.json"
      git -C "${w}" add -A
      git -C "${w}" -c user.name=vapp-ctl -c user.email=vapp-ctl@localhost commit -q -m "command ${id}: ${act} -> ${u}" || { echo "nothing to commit" >&2; exit 1; }
      if git -C "${w}" push -q origin HEAD:refs/heads/main 2> "${tmp}/push.err"; then
        echo "sent: id=${id} action=${act} to ${u}, valid ${ttl}s. Watch it with:  $0 status ${u}   and   $0 log ${u} ${id}"; exit 0
      fi
      sleep 2
    done
    echo "push failed: $(cat "${tmp}/push.err")" >&2; exit 1 ;;
  *) sed -n 3,17p "$0"; exit 1 ;;
esac
