#!/bin/bash
#
# vApp use case ONLY. Runs on the gw as ubuntu, from a crontab entry every minute (installed by vcf_bootstrap.sh when spec.diagnostics is set):
# looks in the PRIVATE repo spec.diagnostics.repo for a command addressed to this vApp and, when nothing else is going on, runs it. The reply
# (state, exit code, encrypted output) goes back through vapp-diagnostics-upload.sh. Always exits 0.
#   bash vapp-diagnostics-command.sh <deployment json>
#
# The command: main:instances/<vApp uuid>/command.json (written by the operator or by vapp-diagnostics-ctl.sh, never by the gw):
#   {"id": "<unique, [A-Za-z0-9._-]{1,64}>", "action": "<one of the list below>", "args": {...}, "issued_at": <epoch>, "expires_at": <epoch>,
#    "uuid": "<this vApp's uuid>", "sig": "<HMAC-SHA256 hex over the other fields (see vapp-diagnostics-common.sh), key = log_encryption_key>"}
# Refused (state "refused", with the reason, and the id is remembered so it is not looked at again): bad or missing signature, another vApp's
# uuid, an id seen before (replay), an unknown action or bad arguments. Expired (state "expired"): expires_at passed before it could start. With
# no log_encryption_key on the gw NO command is ever run. Nothing here is a shell: an action is a fixed entry of the table below.
#
# Actions (args):
#   status                       one line per org of the spec (vcfa_org.sh status --all)                     read-only, runs even when busy
#   upload-now                   push status and logs right away                                           read-only, runs even when busy
#   org-delete-all               vcfa_org.sh delete --all --yes   (dry_run: true -> --dry-run; force: true -> --force, for orgs assigned to a student:
#                                without it nothing is deleted while any org is assigned, the command ends failed with exit code 2)
#   org-add-all                  vcfa_org.sh add --all --yes      (the orgs that were deleted: see --all in vcfa_org.sh)
#   org-delete / org-add         vcfa_org.sh delete|add <args.org> --yes
#   bootstrap-from               vcf_bootstrap.sh <json> --from <args.phase>  (the phase must be in vcf_bootstrap.sh's list)
#   platform-shutdown            vcf_shutdown.sh <json>: shuts the nested platform down in order (VCF Automation, VSP, Supervisor, Avi, NSX, SDDC Manager,
#                                vCenter, vSAN flush, ESX hosts) and leaves the gw running; refuses (exit 2) while an org is not deleted (vcfa_org.sh delete --all
#                                first). args: dry_run (--dry-run), skip_flush (--skip-flush), flush_minutes (0-240, --flush-minutes),
#                                from (a phase of vcf_shutdown.sh: --from, resumes a run that stopped). The vApp itself is
#                                powered off afterwards by the operator through VCD, not by the gw.
#   platform-startup             vcf_startup.sh <json>: starts the nested platform in order, gated (see the script). args: dry_run (--dry-run),
#                                no_orgs (--no-orgs), from (a phase of vcf_startup.sh: --from, resumes a run that stopped), force (--force: without the
#                                cycle-complete marker of a finished shutdown). Normally it runs by itself after a boot (the @reboot entry, --auto).
# No conflict: the others start only when no bootstrap phase, vcfa_org.sh or cleaning run is on the gw and no earlier command is still
# running; until then the command is "waiting" and is looked at again every minute until it expires. One command at a time.
#
# State, for the uploader and for whoever reads status.json ("command"): ${work_root}/command-state.json
#   {id, action, args, state: waiting|running|done|failed|refused|expired, reason, rc, received_at, started_at, ended_at, dir, pid}

diag_name="vapp-diagnostics-command"
script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "${script_dir}/vapp-diagnostics-common.sh"
jsonFile="${1:-}"
cmd_state_file="${work_root}/command-state.json"
pending_file="${work_root}/command-pending.json"
cmd_repo="${work_root}/cmd-repo"

diag_lock command
diag_init "${jsonFile}" || exit 0
[ -s "${key_file}" ] || exit 0          # no key, no commands
seen_file="${work_root}/commands-seen-${uuid}.txt"
sha_file="${work_root}/main-sha-${uuid}"
now=$(date +%s)

set_state() { # jq filter and options: updates command-state.json atomically
  local cur; cur=$(jq -c . "${cmd_state_file}" 2> /dev/null); [ -n "${cur}" ] || cur='{}'
  echo "${cur}" | jq "$@" > "${cmd_state_file}.tmp" && mv -f "${cmd_state_file}.tmp" "${cmd_state_file}"
}
upload_now() { bash "${script_dir}/vapp-diagnostics-upload.sh" "${jsonFile}" --force >> "${diag_home}/vapp-diagnostics.log" 2>&1; }
# a command that ends here without having run: remember the id so it is not looked at again
finish_without_running() { # <state> <reason>
  local a="${args}"; [ -n "${a}" ] || a='{}'
  echo "${id}" >> "${seen_file}"
  set_state --argjson now "${now}" --arg id "${id}" --arg action "${action:-}" --argjson args "${a}" --arg state "${1}" --arg reason "${2}" \
    '{id: $id, action: $action, args: $args, state: $state, reason: $reason, received_at: $now, ended_at: $now}'
  rm -f "${pending_file}"; [ -n "${main_sha:-}" ] && echo "${main_sha}" > "${sha_file}"
  say "command ${id}: ${1} (${2})"; upload_now; exit 0
}

# --- 1. a command is running: has it ended? ------------------------------------------------------------------------------------------
cur_state=$(jq -r '.state // ""' "${cmd_state_file}" 2> /dev/null)
if [ "${cur_state}" == "running" ]; then
  dir=$(jq -r '.dir' "${cmd_state_file}"); pid=$(jq -r '.pid' "${cmd_state_file}")
  if [ -f "${dir}/rc" ]; then
    rc=$(cat "${dir}/rc"); [ "${rc}" == "0" ] && st="done" || st="failed"
  elif ! kill -0 "${pid}" 2> /dev/null; then
    rc=255; st="failed"; echo "(the command's process ended without leaving an exit code)" >> "${dir}/out.log"
  else
    exit 0
  fi
  set_state --argjson now "${now}" --arg st "${st}" --argjson rc "${rc}" '.state = $st | .rc = $rc | .ended_at = $now'
  say "command $(jq -r .id "${cmd_state_file}") ended: ${st} (exit code ${rc})"
  upload_now; exit 0
fi

# --- 2. is there a new command? --------------------------------------------------------------------------------------------------------
raw=""; main_sha=""
if [ "${cur_state}" == "waiting" ] && [ -s "${pending_file}" ]; then
  raw=$(cat "${pending_file}")
else
  main_sha=$(GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=20 -o BatchMode=yes}" timeout 60 git ls-remote "${repo_url}" refs/heads/main 2> /dev/null | cut -f1)
  [ -n "${main_sha}" ] || exit 0                       # no main yet, or no network: try again next minute
  [ "${main_sha}" == "$(cat "${sha_file}" 2> /dev/null)" ] && exit 0
  [ -d "${cmd_repo}/.git" ] || { mkdir -p "${cmd_repo}" && git -C "${cmd_repo}" init -q && git -C "${cmd_repo}" remote add origin "${repo_url}"; } || exit 0
  diag_git "${cmd_repo}" fetch -q --depth 1 origin main 2> /dev/null || exit 0
  raw=$(git -C "${cmd_repo}" show "FETCH_HEAD:instances/${uuid}/command.json" 2> /dev/null)
  [ -n "${raw}" ] || { echo "${main_sha}" > "${sha_file}"; exit 0; }     # main moved, but nothing for this vApp
fi

id=$(echo "${raw}" | jq -r '.id // empty' 2> /dev/null)
action=$(echo "${raw}" | jq -r '.action // empty' 2> /dev/null)
args=$(echo "${raw}" | jq -c '.args // {}' 2> /dev/null); [ -n "${args}" ] || args='{}'
case "${id}" in ''|*[!A-Za-z0-9._-]*) id="invalid-$(date +%s)"; finish_without_running refused "missing or invalid id" ;; esac
[ ${#id} -le 64 ] || { id="${id:0:64}"; finish_without_running refused "id longer than 64 characters"; }
if grep -qxF -- "${id}" "${seen_file}" 2> /dev/null; then [ -n "${main_sha}" ] && echo "${main_sha}" > "${sha_file}"; exit 0; fi   # already handled
want=$(echo "${raw}" | diag_canonical 2> /dev/null | diag_sign "${key_file}")
have=$(echo "${raw}" | jq -r '.sig // empty' 2> /dev/null)
[ -n "${want}" ] && [ "${want}" == "${have}" ] || finish_without_running refused "bad or missing signature"
[ "$(echo "${raw}" | jq -r '.uuid // empty')" == "${uuid}" ] || finish_without_running refused "addressed to another vApp"
issued=$(echo "${raw}" | jq -r '.issued_at // empty'); expires=$(echo "${raw}" | jq -r '.expires_at // empty')
case "${issued}${expires}" in *[!0-9]*|'') finish_without_running refused "issued_at / expires_at are not epoch seconds" ;; esac
[ "${issued}" -le $((now + 600)) ] || finish_without_running refused "issued_at is in the future"
[ $((expires - issued)) -le 604800 ] || finish_without_running refused "valid for more than 7 days"
[ "${now}" -le "${expires}" ] || finish_without_running expired "expires_at passed before the command could start"

# --- 3. the action table: a fixed command line per action, arguments checked ---------------------------------------------------------------
one="${script_dir}/vcfa_org.sh"
dry=(); [ "$(echo "${args}" | jq -r '.dry_run // false')" == "true" ] && dry=(--dry-run)
frc=(); [ "$(echo "${args}" | jq -r '.force // false')" == "true" ] && frc=(--force)   # delete only: orgs assigned to a student
readonly_action="false"
case "${action}" in
  status) cmd=(bash "${one}" status --all --json "${jsonFile}"); readonly_action="true" ;;
  upload-now) readonly_action="true"; cmd=() ;;
  org-delete-all) cmd=(bash "${one}" delete --all --yes "${frc[@]}" "${dry[@]}" --json "${jsonFile}") ;;
  org-add-all) cmd=(bash "${one}" add --all --yes "${dry[@]}" --json "${jsonFile}") ;;
  org-delete|org-add)
    o=$(echo "${args}" | jq -r '.org // empty')
    [[ "${o}" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || finish_without_running refused "args.org is missing or not an org name"
    one_force=(); [ "${action}" == "org-delete" ] && one_force=("${frc[@]}")
    cmd=(bash "${one}" "${action#org-}" "${o}" --yes "${one_force[@]}" "${dry[@]}" --json "${jsonFile}") ;;
  bootstrap-from)
    p=$(echo "${args}" | jq -r '.phase // empty')
    phases_list=$(sed -n 's/^phases="\(.*\)"$/\1/p' "${script_dir}/vcf_bootstrap.sh" | head -1)
    case " ${phases_list} " in *" ${p} "*) [ -n "${p}" ] || finish_without_running refused "args.phase is missing" ;; *) finish_without_running refused "args.phase is not a phase of vcf_bootstrap.sh" ;; esac
    cmd=(bash -c 'bash "$1" "$2" --from "$3" >> /home/ubuntu/vcf_bootstrap.log 2>&1' _ "${script_dir}/vcf_bootstrap.sh" "${jsonFile}" "${p}") ;;
  platform-shutdown)
    fm=$(echo "${args}" | jq -r '.flush_minutes // empty')
    case "${fm}" in ''|*[!0-9]*) [ -z "${fm}" ] || finish_without_running refused "args.flush_minutes is not a whole number" ;; *) [ "${fm}" -le 240 ] || finish_without_running refused "args.flush_minutes is more than 240" ;; esac
    skf=(); [ "$(echo "${args}" | jq -r '.skip_flush // false')" == "true" ] && skf=(--skip-flush)
    fmo=(); [ -n "${fm}" ] && fmo=(--flush-minutes "${fm}")
    frm=(); fp=$(echo "${args}" | jq -r '.from // empty')   # resume a run that stopped: the phases before it are not done again
    if [ -n "${fp}" ]; then
      sd_phases=$(sed -n 's/^phases="\(.*\)"$/\1/p' "${script_dir}/vcf_shutdown.sh" | head -1)
      case " ${sd_phases} " in *" ${fp} "*) frm=(--from "${fp}") ;; *) finish_without_running refused "args.from is not a phase of vcf_shutdown.sh" ;; esac
    fi
    cmd=(bash "${script_dir}/vcf_shutdown.sh" "${jsonFile}" "${dry[@]}" "${skf[@]}" "${fmo[@]}" "${frm[@]}") ;;
  platform-startup)
    sdr=(); [ "$(echo "${args}" | jq -r '.no_orgs // false')" == "true" ] && sdr+=(--no-orgs); [ "$(echo "${args}" | jq -r '.force // false')" == "true" ] && sdr+=(--force)
    fp=$(echo "${args}" | jq -r '.from // empty')
    if [ -n "${fp}" ]; then
      su_phases=$(sed -n 's/^phases="\(.*\)"$/\1/p' "${script_dir}/vcf_startup.sh" | head -1)
      case " ${su_phases} " in *" ${fp} "*) sdr+=(--from "${fp}") ;; *) finish_without_running refused "args.from is not a phase of vcf_startup.sh" ;; esac
    fi
    cmd=(bash "${script_dir}/vcf_startup.sh" "${jsonFile}" "${dry[@]}" "${sdr[@]}") ;;
  *) finish_without_running refused "unknown action '${action}'" ;;
esac

# --- 4. no conflict ----------------------------------------------------------------------------------------------------------------------
if [ "${readonly_action}" != "true" ]; then
  busy=$(diag_activity | head -1)
  if [ -n "${busy}" ]; then
    echo "${raw}" > "${pending_file}"
    prev=$(jq -r '.reason // ""' "${cmd_state_file}" 2> /dev/null)
    set_state --argjson now "${now}" --arg id "${id}" --arg action "${action}" --argjson args "${args}" --arg reason "waiting for ${busy} to end" \
      '{id: $id, action: $action, args: $args, state: "waiting", reason: $reason, received_at: (.received_at // $now), expires_at: '"${expires}"'}'
    [ "${prev}" == "waiting for ${busy} to end" ] || { say "command ${id} (${action}) waits: ${busy}"; upload_now; }
    exit 0
  fi
fi

# --- 5. start it ---------------------------------------------------------------------------------------------------------------------------
echo "${id}" >> "${seen_file}"; rm -f "${pending_file}"; [ -n "${main_sha}" ] && echo "${main_sha}" > "${sha_file}"
dir="${work_root}/cmd-${id}"; mkdir -p "${dir}"; rm -f "${dir}/rc" "${dir}/out.log"
if [ "${action}" == "upload-now" ]; then
  set_state --argjson now "${now}" --arg id "${id}" --arg action "${action}" --argjson args "${args}" --arg dir "${dir}" \
    '{id: $id, action: $action, args: $args, state: "done", rc: 0, received_at: $now, started_at: $now, ended_at: $now, dir: $dir}'
  say "command ${id}: upload-now"; upload_now; exit 0
fi
{ echo '#!/bin/bash'; printf '%q ' "${cmd[@]}"; echo; echo 'echo $? > "$(dirname "$0")/rc.tmp" && mv "$(dirname "$0")/rc.tmp" "$(dirname "$0")/rc"'; } > "${dir}/run.sh"
setsid nohup bash "${dir}/run.sh" > "${dir}/out.log" 2>&1 < /dev/null &
pid=$!
set_state --argjson now "${now}" --arg id "${id}" --arg action "${action}" --argjson args "${args}" --arg dir "${dir}" --argjson pid "${pid}" \
  '{id: $id, action: $action, args: $args, state: "running", received_at: (.received_at // $now), started_at: $now, dir: $dir, pid: $pid}'
say "command ${id}: started ${action} (pid ${pid})"
upload_now
exit 0
