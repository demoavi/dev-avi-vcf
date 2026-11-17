#!/bin/bash
# Sourced by vcf_bootstrap.sh (the phase runner), NOT a phase and not meant to be run alone. Keeps /home/ubuntu/json/vcf_status.json: where the
# build is, per phase, with the exit code of each one, so something that cannot read vcf_bootstrap.log (the operator, a person on another
# machine) can tell "running / failed / finished" and decide: wait, delete and re-apply the CR, fix the code, or resume with --from.
#
#   {
#     "state":          "running" | "failed" | "paused" | "complete" | "partial" | "interrupted"
#                       (partial = a --from/--only run ended well but some phases are not "ok"; interrupted = the runner was killed)
#     "phase":          the phase running now (or the last one that ran), "phase_index" (1-based), "phase_count"
#     "phase_started":  when it started, "phase_exit_code": null while it runs, else the exit code of <phase>.sh
#     "failed_phase":   set when state is "failed", "resume_command": the exact command that continues from there
#     "run":            {started, mode: "full" | "from:<phase>" | "only:<phase>", pid, json}
#     "phases":         [{name, state: pending|running|ok|failed|interrupted, started, ended, seconds, exit_code}] in pipeline order;
#                       a resumed run keeps what the earlier run recorded for the phases it does not touch
#     "last_updated":   every write; the file changes only at events, so a quiet phase (the SDDC build can be silent for hours)
#                       is told apart from a dead gw by the uploader's own heartbeat, not by this file
#   }
#
# Every function is best effort: a failure to write the status must never stop the pipeline (hence "|| true" at the call sites' level
# is not needed, they all return 0).

vcf_status_file="${vcf_status_file:-/home/ubuntu/json/vcf_status.json}"

vcf_status_now() { date +%Y-%m-%dT%H:%M:%S%z; }

# Pushing the status (and the encrypted log) to the private diagnostics repo is vapp-diagnostics-upload.sh's job. It is started
# detached after every write below (flock makes a second one exit at once; the cron entry catches what that skipped) and runs from the
# crontab every 5 minutes as the heartbeat. vcf_status_install_uploader turns it on (and the command runner's own entry): only when spec.diagnostics is set.
vcf_status_uploader=""
vcf_status_uploader_json=""
vcf_status_install_uploader() { # <deployment json> <scripts dir>
  [ -n "${diagnostics_repo:-}" ] || return 0
  vcf_status_uploader="${2}/vapp-diagnostics-upload.sh"
  vcf_status_uploader_json="${1}"
  [ -f "${vcf_status_uploader}" ] || { vcf_status_uploader=""; return 0; }
  # the uploader every 5 minutes (heartbeat), the command runner every minute (vapp-diagnostics-command.sh: commands sent to this gw)
  local upload_line="*/5 * * * * bash ${vcf_status_uploader} ${1} >> /home/ubuntu/vapp-diagnostics.log 2>&1"
  local command_line="* * * * * bash ${2}/vapp-diagnostics-command.sh ${1} >> /home/ubuntu/vapp-diagnostics.log 2>&1"
  # after a boot (poweron-vapp, a gw restart): one forced upload, so the operator and whoever reads the diagnostics repo see that the gw is back (nothing
  # else changes on a plain reboot, and an idle gw uploads nothing); 90 s for the network and the clock
  local reboot_line="@reboot sleep 90; bash ${vcf_status_uploader} ${1} --force >> /home/ubuntu/vapp-diagnostics.log 2>&1"
  ( crontab -l 2> /dev/null | grep -v "vapp-diagnostics-"; echo "${upload_line}"; echo "${reboot_line}"; [ -f "${2}/vapp-diagnostics-command.sh" ] && echo "${command_line}" ) | crontab - 2> /dev/null
  return 0
}
vcf_status_kick() {
  [ -n "${vcf_status_uploader}" ] || return 0
  ( setsid nohup bash "${vcf_status_uploader}" "${vcf_status_uploader_json}" >> /home/ubuntu/vapp-diagnostics.log 2>&1 < /dev/null & ) > /dev/null 2>&1
  return 0
}

# vcf_status_update <jq filter> [jq options...]: applies the filter to the current file ({} when absent or unreadable), stamps
# last_updated, writes atomically (temp file + mv) so a reader never sees half a file.
vcf_status_update() {
  local filter="$1"; shift
  local current="{}" tmp="${vcf_status_file}.tmp.$$"
  [ -s "${vcf_status_file}" ] && current=$(jq -c . "${vcf_status_file}" 2> /dev/null || echo "{}")
  if echo "${current}" | jq --arg now "$(vcf_status_now)" "$@" "${filter} | .last_updated = \$now" > "${tmp}" 2> /dev/null; then
    chmod 644 "${tmp}" 2> /dev/null
    mv -f "${tmp}" "${vcf_status_file}" 2> /dev/null
  fi
  rm -f "${tmp}" 2> /dev/null
  vcf_status_kick
  return 0
}

# vcf_status_run_start <phases (space separated)> <mode> <json file>
vcf_status_run_start() {
  local names
  names=$(printf '%s\n' ${1} | jq -R . | jq -s -c .)
  vcf_status_update '
    ($names | length) as $count
    | (((.phases // []) | map({(.name): .}) | add) // {}) as $old
    | .phases = [$names[] as $n | ($old[$n] // {name: $n, state: "pending"})]
    | .phase_count = $count
    | .state = "running" | .failed_phase = null | .resume_command = null | .phase_exit_code = null
    | .run = {started: $now, mode: $mode, pid: ($pid | tonumber), json: $json}' \
    --argjson names "${names}" --arg mode "${2}" --arg json "${3}" --arg pid "$$"
}

# vcf_status_phase_start <phase> <index (1-based)>
vcf_status_phase_start() {
  vcf_status_update '
    .state = "running" | .phase = $p | .phase_index = ($i | tonumber) | .phase_started = $now | .phase_exit_code = null
    | .phases |= map(if .name == $p then {name: $p, state: "running", started: $now, ended: null, seconds: null, exit_code: null} else . end)' \
    --arg p "${1}" --arg i "${2}"
}

# vcf_status_phase_end <phase> <exit code> <seconds> <resume command>
vcf_status_phase_end() {
  local result="ok"
  [ "${2}" -ne 0 ] && result="failed"
  vcf_status_update '
    .phase_exit_code = ($rc | tonumber)
    | .phases |= map(if .name == $p then .state = $result | .ended = $now | .seconds = ($sec | tonumber) | .exit_code = ($rc | tonumber) else . end)
    | if $result == "failed" then .state = "failed" | .failed_phase = $p | .resume_command = $resume else . end' \
    --arg p "${1}" --arg rc "${2}" --arg sec "${3}" --arg result "${result}" --arg resume "${4}"
}

# vcf_status_paused <phase> <resume command>: stop_before_phase reached
vcf_status_paused() {
  vcf_status_update '.state = "paused" | .paused_before = $p | .resume_command = $resume' --arg p "${1}" --arg resume "${2}"
}

# vcf_status_run_end: the loop ended without a failure
vcf_status_run_end() {
  vcf_status_update '.state = (if all(.phases[]; .state == "ok") then "complete" else "partial" end) | .phase_exit_code = 0'
}

# EXIT trap: the runner is leaving while the file still says "running" (killed, crashed, ssh/cloud-init gone) - mark it, a failed or
# finished run was already written by the functions above and is left as it is.
vcf_status_exit() {
  vcf_status_update 'if .state == "running" then .state = "interrupted" | .phases |= map(if .state == "running" then .state = "interrupted" else . end) else . end'
}
