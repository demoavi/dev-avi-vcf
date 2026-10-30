#!/bin/bash
#
# Guardrail for the Avi virtual services (VS) of the orgs, meant for ubuntu's crontab every 5 minutes (like dedicated-host-placement.sh).
# An Avi service engine (SE) has 9 data vNICs and needs one per org network it serves, so an org whose VSes are spread over several
# SEs takes a vNIC on each of them. This keeps every org on ONE SE, which keeps the number of SEs low (2 SEs carry up to 18 orgs):
#
#   1. per Avi tenant other than admin: the anchor is the VKS control-plane VIP VS (the only VS_TYPE_NORMAL of the tenant; when the
#      tenant has more than one, the one whose cluster has VSes made by its own AKO), and its SE is the SE of the org.
#   2. every other parent or normal VS of the tenant that is on another SE is moved there: POST api/virtualservice/<uuid>/migrate
#      (to_new_se false). Child VSes (VS_TYPE_VH_CHILD, the HTTPRoutes) follow their parent and are left alone. When the
#      ArgoCD VS (marker GatewayName gw-argocd in namespace argocd) was not on the SE of the VKS VS, that is reported with log_notify
#      (it should not happen: vcfa_tenant_bootstrap.sh puts it there), and it is moved like the others.
#   3. only when the tenants are all in place (nothing left to move, nothing failed): an SE with no VS at all is removed, when it was
#      idle on two runs in a row and online for 10 minutes, its SE group (SEG) has buffer_se 0 (otherwise Avi creates it again at
#      once: it is the buffer, and that is reported once) and keeps more than min_se SEs. With --no-delete-idle-se the idle SE is
#      only reported. A tenant without a VKS control-plane VIP VS is left alone, so is one where it cannot be told which VS it is
#      (reported once).
#
# usage: enforce-vs-placement.sh <json file> [--dry-run] [--org <org>] [--no-delete-idle-se]
#        enforce-vs-placement.sh <json file> --install-cron [--no-delete-idle-se]   (ubuntu's crontab, every 5 minutes, replaces an entry)
#   --dry-run   changes nothing, prints what would be moved or removed
#   --no-delete-idle-se   report an idle SE, do not remove it
#   --org       only that org's Avi tenant (testing)
# vApp use case only (the sddc use case runs 2-3 orgs and does not need it; ENFORCE_ALLOW_NON_VAPP=1 only to test against another
# deployment). Does nothing while vcf_bootstrap.sh, one of its phases or vcfa_org.sh runs (they create VSes and SEs). Each move takes the VS out for a
# few seconds. A problem that stays is reported once (log_notify: log, Google chat webhook; from cron there is no VCD session, so no
# VCD metadata), and again after it was gone. Log: /home/ubuntu/enforce-vs-placement.log.
#
jsonFile="${1:-/home/ubuntu/json/deployment.json}"
shift
dry_run="false"; only_org=""; delete_idle="true"; install_cron="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run="true"; shift ;;
    --org) only_org="${2:?}"; shift 2 ;;
    --no-delete-idle-se) delete_idle="false"; shift ;;
    --install-cron) install_cron="true"; shift ;;
    -h|--help) sed -n 2,28p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"
[ "${deployment_kind}" == "vApp" ] || [ "${ENFORCE_ALLOW_NON_VAPP:-}" == "1" ] || exit 0
state_dir="/home/ubuntu/.enforce-vs-placement"
mkdir -p "${state_dir}"

if [ "${install_cron}" == "true" ]; then
  cron_line="*/5 * * * * flock -n /tmp/enforce-vs-placement.lock ${script_dir}/enforce-vs-placement.sh ${jsonFile}$([ "${delete_idle}" != "true" ] && echo " --no-delete-idle-se") >> /home/ubuntu/enforce-vs-placement.log 2>&1"
  (crontab -l 2>/dev/null | grep -v 'enforce-vs-placement.sh'; echo "${cron_line}") | crontab -
  log_only "enforce-vs-placement.sh installed in ubuntu's crontab (every 5 minutes$([ "${delete_idle}" == "true" ] && echo ", idle SEs are removed" || echo ", idle SEs are only reported"), log: /home/ubuntu/enforce-vs-placement.log)"
  exit 0
fi

# changes the team must hear about; a dry run only prints them
notify() { if [ "${dry_run}" == "true" ]; then log_only "[dry-run, nothing changed] $1"; else log_notify "$1"; fi; }
# a problem that stays is reported once; the marker goes away when the problem does
notify_once() { # key message
  [ -f "${state_dir}/once_$1" ] && return 0
  [ "${dry_run}" == "true" ] || touch "${state_dir}/once_$1"
  notify "$2"
}
clear_once() { rm -f "${state_dir}/once_$1"; }

# not while the pipeline or vcfa_org.sh works (the same test as vcfa_org.sh: real script runs only, not this process)
busy=$(ps -eo pid=,ppid=,args= | awk -v me=$$ '$1 != me && $2 != me && $3 == "bash" && $4 ~ /(vcf_bootstrap|vcfa_provider_bootstrap|vcfa_tenant_bootstrap|vcfa_tenant_cleaning|supervisor-bootstrap|avi-bootstrap|nsx-bootstrap|k8s-bootstrap|git-bootstrap|vcfa_org)\.sh$/ {print $4}' | head -1)
if [ -n "${busy}" ]; then log_only "${busy##*/} is running: placement not checked this time"; exit 0; fi

ip_avi=$(echo "${ips_avi:-[]}" | jq -r '.[0] // empty' 2>/dev/null)   # variables.sh only has the plural ips_avi, like the other phases derive it
[ -n "${ip_avi:-}" ] || { log_only "no Avi controller address in the variables: nothing to do"; exit 0; }
jar=$(mktemp); trap 'rm -f "${jar}"' EXIT
curl -sk -m 20 -c "${jar}" -o /dev/null -X POST -H 'Content-Type: application/json' -d "{\"username\": \"admin\", \"password\": \"${generic_password}\"}" "https://${ip_avi}/login"
tok=$(awk '/csrftoken/{print $7}' "${jar}")
if [ -z "${tok}" ]; then notify_once login "Avi controller ${ip_avi} does not answer (no login): VS placement not checked"; exit 0; fi
clear_once login
av() { # endpoint [tenant] [curl args...]
  local ep="$1" tenant="${2:-*}"; shift 2 2> /dev/null || shift 1
  curl -sk -m 40 -b "${jar}" -H "X-CSRFToken: ${tok}" -H "Referer: https://${ip_avi}" -H "X-Avi-Version: ${avi_version:-32.1.1}" -H "X-Avi-Tenant: ${tenant}" -H 'Content-Type: application/json' "$@" "https://${ip_avi}/api/${ep}"
}

# One plan per org tenant: the anchor VS and its SE, and the VSes to move. Markers and type only exist on the VS objects, the SE of a VS
# only in the inventory; they are joined by uuid.
make_plan() {
  local inv full
  inv=$(av "virtualservice-inventory?page_size=200&include_name=true" "*")
  full=$(av "virtualservice?page_size=200&include_name=true" "*")
  jq -n -c --argjson inv "${inv:-null}" --argjson full "${full:-null}" --arg only "${only_org}" '
    def mk($k): ([.markers[]? | select(.key == $k) | .values[0]] | first // "");
    ($inv.results // [] | map({key: .uuid, value: {se: (.runtime.vip_summary[0].service_engine[0].uuid // ""), sen: (.runtime.vip_summary[0].service_engine[0].url // "" | split("#")[-1]), vip: (.runtime.vip_summary[0].vip_id // "0")}}) | from_entries) as $m
    | [($full.results // [])[] | select((.tenant_ref | split("#")[-1]) as $t | $t != "admin" and ($only == "" or $t == $only))]
    | group_by(.tenant_ref | split("#")[-1])
    | map(. as $vs | ($vs[0].tenant_ref | split("#")[-1]) as $t
      | [$vs[] | select(.type == "VS_TYPE_NORMAL")] as $normal
      | (if ($normal | length) == 1 then $normal
         else [$normal[] | . as $n | select(any($vs[]; mk("clustername") | startswith(($n | mk("GatewayName"))[0:15] + "-")))] end) as $anch
      | (if ($anch | length) == 1 then $anch[0] else null end) as $a
      | (if $a == null then "" else (($m[$a.uuid] // {}).se // "") end) as $se
      | {tenant: $t, anchor: ($a.name // null), anchor_se: $se, anchor_sen: (if $a == null then "" else (($m[$a.uuid] // {}).sen // "") end),
         ambiguous: ($a == null and ($normal | length) > 1),
         moves: (if $se == "" then [] else [$vs[] | select(.type != "VS_TYPE_VH_CHILD" and .uuid != $a.uuid)
                 | select((($m[.uuid] // {}).se // "") != "" and (($m[.uuid] // {}).se) != $se)
                 | {uuid, name, vip: $m[.uuid].vip, from: $m[.uuid].sen, argocd: (mk("Namespace") == "argocd" and mk("GatewayName") == "gw-argocd")}] end)})' 2> /dev/null
}

vs_on_se() { # tenant vs-uuid -> its SE uuid
  av "virtualservice-inventory/$2" "$1" | jq -r '.runtime.vip_summary[0].service_engine[0].uuid // empty' 2> /dev/null
}

plan=$(make_plan)
if [ -z "${plan}" ] || [ "${plan}" == "null" ]; then notify_once inventory "Avi did not return the virtual services: VS placement not checked"; exit 0; fi
clear_once inventory
failed=0; moved=0
while IFS= read -r t; do
  tenant=$(echo "${t}" | jq -r .tenant)
  if [ "$(echo "${t}" | jq -r .ambiguous)" == "true" ]; then
    notify_once "ambiguous_${tenant}" "Avi tenant ${tenant} has several normal virtual services and none of them is the VKS control-plane VIP: its VS placement is not enforced"
    continue
  fi
  clear_once "ambiguous_${tenant}"
  anchor_se=$(echo "${t}" | jq -r .anchor_se); anchor_sen=$(echo "${t}" | jq -r .anchor_sen)
  [ -n "${anchor_se}" ] || continue
  if [ "$(echo "${t}" | jq '.moves | length')" == "0" ]; then clear_once "move_${tenant}"; clear_once "argocd_${tenant}"; continue; fi
  while IFS= read -r mv; do
    uuid=$(echo "${mv}" | jq -r .uuid); name=$(echo "${mv}" | jq -r .name); vip=$(echo "${mv}" | jq -r .vip); from=$(echo "${mv}" | jq -r .from)
    if [ "$(echo "${mv}" | jq -r .argocd)" == "true" ]; then
      notify_once "argocd_${tenant}" "Avi tenant ${tenant}: the ArgoCD virtual service is on ${from} but the VKS virtual service is on ${anchor_sen}: moving it"
    fi
    if [ "${dry_run}" == "true" ]; then log_only "[dry-run, nothing changed] tenant ${tenant}: would move ${name} from ${from} to ${anchor_sen}"; continue; fi
    code=$(av "virtualservice/${uuid}/migrate" "${tenant}" -o /dev/null -w '%{http_code}' -X POST -d "{\"vip_id\": \"${vip}\", \"serviceengine_ref\": \"https://${ip_avi}/api/serviceengine/${anchor_se}\", \"to_new_se\": false}")
    if [[ "${code}" != 2* ]]; then
      failed=$((failed + 1)); notify_once "move_${tenant}" "Avi tenant ${tenant}: moving ${name} from ${from} to ${anchor_sen} failed (HTTP ${code}), left where it is"
      continue
    fi
    for _ in $(seq 1 24); do sleep 5; [ "$(vs_on_se "${tenant}" "${uuid}")" == "${anchor_se}" ] && break; done
    if [ "$(vs_on_se "${tenant}" "${uuid}")" == "${anchor_se}" ]; then
      moved=$((moved + 1)); log_only "Avi tenant ${tenant}: ${name} moved from ${from} to ${anchor_sen}"
    else
      failed=$((failed + 1)); notify_once "move_${tenant}" "Avi tenant ${tenant}: ${name} did not arrive on ${anchor_sen} within 2 minutes after the move from ${from}"
    fi
  done < <(echo "${t}" | jq -c '.moves[]')
done < <(echo "${plan}" | jq -c '.[]')
[ "${moved}" -gt 0 ] && log_only "${moved} virtual service(s) moved onto the SE of their org's VKS control-plane VIP"

# ---- idle SEs: only when every tenant is in place ----
remaining=0
if [ "${dry_run}" == "true" ]; then remaining=$(echo "${plan}" | jq '[.[].moves | length] | add // 0')
else remaining=$(make_plan | jq '[.[].moves | length] | add // 0'); fi
if [ "${failed}" -gt 0 ] || [ "${remaining}" -gt 0 ]; then log_only "${remaining} virtual service(s) still on another SE than their org's, ${failed} failed: idle SEs are not looked at"; exit 0; fi

ses=$(av "serviceengine-inventory?page_size=200&include_name=true" "admin" | jq -c '[.results[]? | {uuid: .uuid, name: .config.name, seg: (.config.se_group_ref // "" | split("#")[-1]), seg_uuid: (.config.se_group_ref // "" | split("#")[0] | split("/")[-1]), vs: ((.config.virtualservice_refs // []) | length), idle_state: (.runtime.migrate_state // ""), online: (.runtime.online_since // "")}]' 2> /dev/null)
segs=$(av "serviceenginegroup?page_size=100" "admin" | jq -c '[.results[]? | {uuid, name, buffer_se: (.buffer_se // 0), min_se: (.min_se // 1)}]' 2> /dev/null)
[ -n "${ses}" ] && [ "${ses}" != "[]" ] || exit 0
declare -A removed   # SEs taken out of each SE group in this run, so two idle SEs never empty a group
while IFS= read -r se; do
  uuid=$(echo "${se}" | jq -r .uuid); name=$(echo "${se}" | jq -r .name); seg=$(echo "${se}" | jq -r .seg); seg_uuid=$(echo "${se}" | jq -r .seg_uuid)
  if [ "$(echo "${se}" | jq -r .vs)" != "0" ]; then rm -f "${state_dir}/idle_${uuid}"; clear_once "idlese_${uuid}"; continue; fi
  idle_runs=$(( $(cat "${state_dir}/idle_${uuid}" 2> /dev/null || echo 0) + 1 ))
  [ "${dry_run}" == "true" ] || echo "${idle_runs}" > "${state_dir}/idle_${uuid}"
  buffer=$(echo "${segs}" | jq -r --arg g "${seg_uuid}" '[.[] | select(.uuid == $g)][0].buffer_se // 0'); min_se=$(echo "${segs}" | jq -r --arg g "${seg_uuid}" '[.[] | select(.uuid == $g)][0].min_se // 1')
  count=$(( $(echo "${ses}" | jq --arg g "${seg_uuid}" '[.[] | select(.seg_uuid == $g)] | length') - ${removed[${seg_uuid}]:-0} ))
  if [ "${buffer}" != "0" ]; then
    notify_once "idlese_${uuid}" "SE ${name} (${seg}) serves no virtual service, but the SE group has buffer_se ${buffer}: Avi keeps it as the buffer. Set buffer_se to 0 on ${seg} to let it be removed"; continue
  fi
  if [ "${count}" -le "${min_se}" ]; then log_only "SE ${name} is idle, but ${seg} has only ${count} SE(s) (min_se ${min_se}): kept"; continue; fi
  online_ts=$(date -u -d "$(echo "${se}" | jq -r .online | sed -E 's/^([0-9]{4})-([A-Za-z]{3})-([0-9]{2}) /\2 \3 \1 /')" +%s 2> /dev/null || echo 0)   # Avi says "2026-Oct-26 20:02:03" (UTC)
  if [ "${online_ts}" -eq 0 ] || [ $(( $(date +%s) - online_ts )) -lt 600 ] || [ "$(echo "${se}" | jq -r .idle_state)" != "SE_MIGRATE_STATE_IDLE" ]; then log_only "SE ${name} is idle but not settled yet (online since $(echo "${se}" | jq -r .online)): kept"; continue; fi
  if [ "${idle_runs}" -lt 2 ]; then log_only "SE ${name} (${seg}) serves no virtual service (seen once, removed if it is still idle at the next run)"; continue; fi
  if [ "${delete_idle}" != "true" ]; then notify_once "idlese_${uuid}" "SE ${name} (${seg}) has served no virtual service for ${idle_runs} runs: it would be removed (run without --no-delete-idle-se)"; continue; fi
  if [ "${dry_run}" == "true" ]; then log_only "[dry-run, nothing changed] would delete the idle SE ${name} (${seg})"; removed[${seg_uuid}]=$(( ${removed[${seg_uuid}]:-0} + 1 )); continue; fi
  # last look right before: a VS may have been placed on it meanwhile
  if [ "$(av "serviceengine-inventory/${uuid}" "admin" | jq -r '(.config.virtualservice_refs // []) | length' 2> /dev/null)" != "0" ]; then log_only "SE ${name} got a virtual service meanwhile: kept"; continue; fi
  code=$(av "serviceengine/${uuid}" "admin" -o /dev/null -w '%{http_code}' -X DELETE)
  if [[ "${code}" == 2* ]]; then notify "removed the idle SE ${name} (${seg}, no virtual service for ${idle_runs} runs)"; rm -f "${state_dir}/idle_${uuid}"; removed[${seg_uuid}]=$(( ${removed[${seg_uuid}]:-0} + 1 ))
  else notify_once "idlese_${uuid}" "removing the idle SE ${name} (${seg}) failed (HTTP ${code})"; fi
done < <(echo "${ses}" | jq -c '.[]')
exit 0
