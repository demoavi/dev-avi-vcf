#!/bin/bash
#
# vApp use case ONLY. Runs on the gw as ubuntu: pushes the build status and the (encrypted) logs to the PRIVATE repo spec.diagnostics.repo,
# so the operator or a person on another machine can see where the long build is without ssh access to the gw.
#   bash vapp-diagnostics-upload.sh <deployment json> [--force]
# Started by a crontab entry every 5 minutes (installed by vcf_bootstrap.sh when spec.diagnostics is set), by vcf_status.sh at each phase event
# and by vapp-diagnostics-command.sh when a command starts or ends. Overlapping runs: the second one exits at once (flock). Always exits 0: a push
# that fails is logged and retried at the next run. The other direction (commands to the gw) is vapp-diagnostics-command.sh.
#
# What goes where. Branch  instance/<vApp uuid>  of the repo, ONE commit that every upload amends and force-pushes (an instance never
# accumulates history; the branch is the instance's own, so a force push touches nothing else), under  instances/<vApp uuid>/ :
#   status.json                  vcf_status.json (state, phase, exit codes, resume command; see vcf_status.sh) plus uploaded_at, the vApp uuid and
#                                name, "activity" (the scripts running on the gw right now, vcfa_org.sh by hand included), the log's size and age and, while there is one, "command" (the last command received and how it went).
#                                Plain text on purpose: it holds no secret.
#   vcf_bootstrap.log.gz.enc     the bootstrap log (vcfa_org.sh writes there too), gzipped then encrypted with the passphrase of
#                                spec.diagnostics.log_encryption_key (a log has secrets in it). Without that key no log is ever uploaded.
#   command-<id>.log.gz.enc      the output of the last commands (the 5 latest are kept), same encryption
#   decrypt:  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass file:<key file> -in <file>.gz.enc | gunzip
#
# When it pushes (the cron only decides when to LOOK):
#   status.json  when the status or the command changed since the last push (a phase started or ended, a failure, a pause, a command), or every 5
#                minutes while a build, a command or any script of the pipeline is "running" (the heartbeat: the SDDC build can be silent for hours). Idle costs nothing.
#   the logs     with every change, and every 30 minutes while "running". Failed or interrupted: the WHOLE log; else its last 3000 lines.

diag_name="vapp-diagnostics-upload"
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/vapp-diagnostics-common.sh"
jsonFile="${1:-}"; force="false"; [ "${2:-}" == "--force" ] && force="true"
status_src="${diag_home}/json/vcf_status.json"
shutdown_src="${diag_home}/json/vcf_shutdown_status.json"     # vcf_shutdown.sh's own status (same shape), sent as "shutdown"
log_src="${diag_home}/vcf_bootstrap.log"
cmd_state_file="${work_root}/command-state.json"
heartbeat_sec=270      # the cron runs every 300: slightly below, so a run is never skipped by a second of jitter
log_every_sec=1800
tail_lines=3000

diag_lock upload
# keep the cron log small
cron_log="${diag_home}/vapp-diagnostics.log"
[ -f "${cron_log}" ] && [ "$(stat -c %s "${cron_log}" 2> /dev/null || echo 0)" -gt 1048576 ] && tail -n 500 "${cron_log}" > "${cron_log}.tmp" && mv -f "${cron_log}.tmp" "${cron_log}"
diag_init "${jsonFile}" || exit 0
[ -f "${status_src}" ] || { say "no ${status_src} yet"; exit 0; }

# --- what changed ----------------------------------------------------------------------------------------------------------------------
state_file="${work_root}/state-${uuid}.json"
now=$(date +%s)
cmd_json=$(jq -c . "${cmd_state_file}" 2> /dev/null); [ -n "${cmd_json}" ] || cmd_json='null'
activity=$(diag_activity | head -5 | jq -R . | jq -s -c .)       # e.g. ["vcfa_org.sh add org-2"]: scripts running on the gw right now, whoever started them
[ -n "${activity}" ] || activity='[]'
shutdown_json=$(jq -c . "${shutdown_src}" 2> /dev/null); [ -n "${shutdown_json}" ] || shutdown_json='null'
hash=$( { jq -S 'del(.last_updated)' "${status_src}" 2> /dev/null; echo "${shutdown_json}" | jq -S 'del(.last_updated)' 2> /dev/null; echo "${cmd_json}" | jq -S . 2> /dev/null; echo "${activity}"; } | sha256sum | cut -d' ' -f1)
last_hash=$(jq -r '.hash // ""' "${state_file}" 2> /dev/null)
last_push=$(jq -r '.last_push // 0' "${state_file}" 2> /dev/null)
last_log_push=$(jq -r '.last_log_push // 0' "${state_file}" 2> /dev/null)
last_push=${last_push:-0}; last_log_push=${last_log_push:-0}   # no state file yet (first upload of this instance)
state=$(jq -r '.state // ""' "${status_src}" 2> /dev/null)
cmd_state=$(echo "${cmd_json}" | jq -r '.state // ""')
push_status="false"; push_log="false"
[ "${hash}" != "${last_hash}" ] && { push_status="true"; push_log="true"; }
if [ "${state}" == "running" ] || [ "${cmd_state}" == "running" ] || [ "$(echo "${shutdown_json}" | jq -r '.state // ""')" == "running" ] || [ "${activity}" != "[]" ]; then
  [ $((now - last_push)) -ge ${heartbeat_sec} ] && push_status="true"
  [ $((now - last_log_push)) -ge ${log_every_sec} ] && push_log="true"
fi
[ "${force}" == "true" ] && { push_status="true"; push_log="true"; }
[ "${push_status}" == "true" ] || exit 0
[ -s "${key_file}" ] || push_log="false"

# --- the work tree: one orphan branch per instance, one amended commit ----------------------------------------------------------------
work="${work_root}/work-${uuid}"
branch="instance/${uuid}"
folder="${work}/instances/${uuid}"
if [ ! -d "${work}/.git" ]; then
  mkdir -p "${work}" && git -C "${work}" init -q && git -C "${work}" checkout -q --orphan "${branch}" && git -C "${work}" remote add origin "${repo_url}" \
    || { say "could not create the work tree ${work}"; exit 0; }
fi
mkdir -p "${folder}"

# encrypt_to <source command...> -- <output file>: gzip + AES-256-CBC (PBKDF2), atomically
encrypt_to() {
  local out="${!#}" n=$(( $# - 2 ))
  "${@:1:${n}}" | gzip -c | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "file:${key_file}" -out "${out}.tmp" 2> /dev/null \
    && mv -f "${out}.tmp" "${out}" || { rm -f "${out}.tmp"; return 1; }
}

log_kind=""; log_lines=0
if [ "${push_log}" == "true" ]; then
  if [ -s "${log_src}" ]; then
    log_lines=$(wc -l < "${log_src}")
    case "${state}" in failed|interrupted) log_kind="full"; src_cmd=(cat "${log_src}") ;; *) log_kind="tail"; src_cmd=(tail -n ${tail_lines} "${log_src}") ;; esac
    if ! encrypt_to "${src_cmd[@]}" -- "${folder}/vcf_bootstrap.log.gz.enc"; then say "encrypting the log failed, uploading the status only"; log_kind=""; fi
  fi
  # the command's own output: the whole file of a finished command, the tail of a running one
  cmd_id=$(echo "${cmd_json}" | jq -r '.id // empty'); cmd_dir=$(echo "${cmd_json}" | jq -r '.dir // empty')
  if [ -n "${cmd_id}" ] && [ -s "${cmd_dir}/out.log" ]; then
    if [ "${cmd_state}" == "running" ]; then cmd_src=(tail -n ${tail_lines} "${cmd_dir}/out.log"); else cmd_src=(cat "${cmd_dir}/out.log"); fi
    encrypt_to "${cmd_src[@]}" -- "${folder}/command-${cmd_id}.log.gz.enc" || say "encrypting the output of command ${cmd_id} failed"
  fi
  ls -t "${folder}"/command-*.log.gz.enc 2> /dev/null | tail -n +6 | xargs -r rm -f
fi
# the last upload's log description stays valid in status.json when this push carries no new log
prev_log=$(jq -c '.log // {}' "${folder}/status.json" 2> /dev/null)
[ -n "${prev_log}" ] || prev_log='{}'
log_age=$(( now - $(stat -c %Y "${log_src}" 2> /dev/null || echo "${now}") ))
jq --arg uuid "${uuid}" --arg vapp "${vcd_vapp:-}" --arg host "$(hostname)" --arg up "$(date +%Y-%m-%dT%H:%M:%S%z)" \
   --argjson prev "${prev_log}" --argjson cmd "${cmd_json}" --argjson shut "${shutdown_json}" --argjson activity "${activity}" --arg kind "${log_kind}" --arg lines "${log_lines}" --arg age "${log_age}" \
   --arg size "$(stat -c %s "${log_src}" 2> /dev/null || echo 0)" --arg haskey "$([ -s "${key_file}" ] && echo true || echo false)" \
   '. + {uploaded_at: $up, vapp_uuid: $uuid, vapp_name: $vapp, gw_host: $host, activity: $activity,
         log: ((if $kind != "" then {kind: $kind, uploaded_at: $up, lines: ($lines | tonumber)} else $prev end)
               + {source_bytes: ($size | tonumber), seconds_since_last_line: ($age | tonumber), encryption_key_set: ($haskey == "true")})}
      + (if $cmd != null then {command: ($cmd | del(.dir, .pid))} else {} end)
      + (if $shut != null then {shutdown: $shut} else {} end)' \
   "${status_src}" > "${folder}/status.json.tmp" && mv -f "${folder}/status.json.tmp" "${folder}/status.json" \
   || { say "could not write status.json"; exit 0; }

cd "${work}" || exit 0
git add -A
if git rev-parse -q --verify HEAD > /dev/null 2>&1; then amend="--amend"; else amend=""; fi
diag_git "${work}" commit -q ${amend} -m "${uuid}: ${state} $(jq -r '.phase // "-"' "${status_src}") $(date +%H:%M)" > /dev/null 2>&1 \
  || { say "git commit failed"; exit 0; }
if diag_git "${work}" push -q --force origin "HEAD:refs/heads/${branch}" 2> "${work_root}/push.err"; then
  jq -n --arg hash "${hash}" --argjson last_push "${now}" --argjson last_log_push "$([ "${push_log}" == "true" ] && echo "${now}" || echo "${last_log_push}")" \
    '{hash: $hash, last_push: $last_push, last_log_push: $last_log_push}' > "${state_file}"
  say "pushed ${branch}: state=${state}$([ -n "${cmd_state}" ] && echo ", command ${cmd_state}")$([ "${push_log}" == "true" ] && echo ", logs (${log_kind:-no bootstrap log}, ${log_lines} lines)")"
else
  say "push failed (will retry at the next run): $(tr '\n' ' ' < "${work_root}/push.err" | cut -c1-300)"
fi
exit 0
