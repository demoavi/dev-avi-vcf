#!/bin/bash
#
# Per-VCF-A-org Linux accounts on gw, one per org in vcf_a_organizations
# (org-1, org-2, ...). SSH login, password-based - each org's password is
# "VMware1!<4 hex chars from sha256(gw_accounts_secret + org_name)>
# VMware1!" (20 chars total), deliberately independent of generic_password
# (a different secret entirely, so rotating one never affects the other).
# Deterministic and reproducible elsewhere from the same two inputs - no
# separate secret store needed. The VMware1! prefix/suffix bookending a
# short hash segment (not a longer raw hash) is required, not cosmetic -
# confirmed live 2026-09-28 against the sddc reference environment that
# vCenter SSO's own password-strength check has an undocumented 20-
# character MAXIMUM length (21+ is rejected outright, "Password strength
# check" constraint violation, regardless of character-class mix), and
# VCFA's own local-user password policy separately requires at least one
# uppercase/lowercase/digit/special character - a raw hex string (no
# uppercase, no special char) fails VCFA's check, while a longer prefixed
# hex string fails vCenter's length cap. This exact 20-char shape is the
# only one confirmed live to satisfy vCenter, NSX, and VCFA simultaneously
# - see vcfa_tenant_bootstrap.sh's and vcfa_provider_bootstrap.sh's own
# copies of this same derivation, which must stay byte-for-byte identical
# to this one (same login/password across gw SSH, vCenter SSO, Avi,
# NSX, and the VCF-A org user, all for the same org).
#
# vApp use case only (deployment_kind == "vApp"): first generates gw's own
# WireGuard keypair (/home/ubuntu/wireguard, kept in gw_wg_private_key /
# gw_wg_public_key), then also creates
# /home/<org>/wireguard per org, owned by that org's account (mode 700), as
# the drop location for per-org files the student vApp consumes later, and
# writes the OpenRC "wg-quick" init script into it (mode 755), and generates
# that org's WireGuard keypair there (private.key/public.key, mode 600,
# created once and never regenerated) plus its wg0.conf (mode 600; tunnel
# address 10.8.0.<N>/24 from the org name's trailing number, the gw as peer).
#
# Runs first in vcf_bootstrap.sh's phase loop since it has no dependency
# on anything else in the pipeline.
#
jsonFile="${1}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source /home/ubuntu/bash/variables.sh
source "${script_dir}/functions.sh"
# sddc use case has no VCD at all - vcd_login (and everything it sets:
# vcd_host/vcd_auth_token/vcd_api_version/gw_vm_href) only makes sense for
# the vApp use case. log_notify below tolerates gw_vm_href being unset
# (its VCD-metadata-posting branch is gated on it), so skipping this is
# safe for sddc.
if [ "${deployment_kind}" == "vApp" ]; then
  vcd_login
fi
log_notify "gw-accounts.sh started"

if ! grep -qE '^\s*PasswordAuthentication\s+yes\s*$' /etc/ssh/sshd_config; then
  if grep -qE '^\s*#?\s*PasswordAuthentication\s' /etc/ssh/sshd_config; then
    sudo sed -i -E 's/^\s*#?\s*PasswordAuthentication\s+.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  else
    echo "PasswordAuthentication yes" | sudo tee -a /etc/ssh/sshd_config >/dev/null
  fi
  sudo systemctl reload ssh
  log_notify "enabled PasswordAuthentication in sshd_config"
fi

# vApp use case only: wg (wireguard-tools) generates gw's own keypair right
# below and each org's keypair inside the loop. Also in variables.json's
# apt_packages (installed at gw boot) - this is only the recovery path if
# that install silently failed or never happened (e.g. a gw built before the
# package was added), same pattern as skopeo in supervisor-bootstrap.sh. Key
# generation is skipped, with an error notification, if wg still isn't
# available.
if [ "${deployment_kind}" == "vApp" ] && ! command -v wg >/dev/null 2>&1; then
  sudo apt-get install -y wireguard-tools || log_notify "ERROR: apt-get install wireguard-tools failed, skipping WireGuard key generation"
fi

# vApp use case only: gw's own WireGuard keypair, left in gw_wg_private_key /
# gw_wg_public_key for the rest of this script (nothing consumes them yet).
# Generated as ubuntu into /home/ubuntu/wireguard (700, ubuntu-owned): unlike
# the per-org directories below, ubuntu owns this one, so no sudo hop is
# needed and an "already exists" test works. Generated once and never
# regenerated - a re-run reuses the files on disk, because a fresh key on
# every run would silently invalidate any peer config holding the old
# public key. The subshell scopes umask 077 (both files end up 600) and
# pipefail (a failing wg stage fails the pipeline; an empty private.key left
# behind by tee counts as missing, so the next run regenerates it) to this
# block only. The variables are deliberately NOT exported, so the private key
# never reaches the environment of the sudo/useradd/curl children below, and
# nothing here ever logs key material - only a generic state word.
gw_wg_private_key=""
gw_wg_public_key=""
if [ "${deployment_kind}" == "vApp" ] && command -v wg >/dev/null 2>&1; then
  gw_wireguard_dir="/home/ubuntu/wireguard"
  mkdir -p "${gw_wireguard_dir}"
  chmod 700 "${gw_wireguard_dir}"
  if ! gw_wg_key_state=$(
    cd "${gw_wireguard_dir}" || exit 1
    set -o pipefail
    umask 077
    if [ ! -s private.key ]; then
      wg genkey | tee private.key | wg pubkey > public.key || exit 1
      echo generated
    elif [ ! -s public.key ]; then
      wg pubkey < private.key > public.key || exit 1
      echo rederived
    else
      echo exists
    fi
  ); then
    log_notify "ERROR: gw WireGuard key generation failed in ${gw_wireguard_dir}"
  else
    gw_wg_private_key=$(cat "${gw_wireguard_dir}/private.key")
    gw_wg_public_key=$(cat "${gw_wireguard_dir}/public.key")
    if [ "${gw_wg_key_state}" != "exists" ]; then
      log_notify "gw WireGuard keypair ${gw_wg_key_state}"
    fi
  fi
fi

# vApp use case only: values for each org's wg0.conf (rendered inside the
# loop below). The tunnel subnet, the routed ranges and the port are fixed
# choices, not CR-driven. Each org's own tunnel address is
# <prefix>.<N>/24, N being the trailing number of the org's name (org-2 ->
# 10.8.0.2/24) - a number taken from the NAME rather than the org's position
# in the list, so an org keeps the same address even if orgs are added or
# reordered. N must be 1-253 (a /24 host octet; .254 is the gw's own end of
# the tunnel, hence a hard limit of 253 orgs); an org name without such a
# number gets no wg0.conf and no gw peer, with an error notification, rather
# than a made-up address.
wg_org_tunnel_prefix="10.8.0"
wg_gw_tunnel_address="${wg_org_tunnel_prefix}.254/24"
wg_allowed_ips="192.168.0.0/16, 172.16.0.0/17"
wg_endpoint_port="51820"
org_tunnel_number() {
  local digits n
  [[ "$1" =~ ([0-9]+)$ ]] || return 1
  digits="${BASH_REMATCH[1]}"
  [ "${#digits}" -le 3 ] || return 1
  n=$((10#${digits}))
  [ "${n}" -ge 1 ] && [ "${n}" -le 253 ] || return 1
  echo "${n}"
}

# The Endpoint every org's wg0.conf points at: the gw's own IP on the network
# it reaches the outside through (the org network the student vApp shares),
# i.e. the source address of its default route. Derived at runtime, never
# hardcoded - it differs per deployment. wg0.conf rendering needs both this
# and the gw's public key; if either is missing it is skipped for every org,
# with ONE error notification here instead of one per org.
wg0_conf_ready="false"
gw_peers_conf=""
if [ "${deployment_kind}" == "vApp" ]; then
  gw_wg_endpoint_ip=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
  if [ -n "${gw_wg_public_key}" ] && [ -n "${gw_wg_endpoint_ip}" ]; then
    wg0_conf_ready="true"
  else
    log_notify "ERROR: skipping per-org wg0.conf rendering - gw WireGuard public key available: $([ -n "${gw_wg_public_key}" ] && echo yes || echo no), gw endpoint IP: '${gw_wg_endpoint_ip}'"
  fi
fi

while read -r item
do
  org_name=$(echo ${item} | jq -c -r '.name')
  if id "${org_name}" >/dev/null 2>&1; then
    log_notify "account ${org_name} already exists, skipping creation"
  else
    sudo useradd -m -s /bin/bash "${org_name}"
    log_notify "created account ${org_name}"
  fi
  # useradd -m's default home-dir mode has no "other" traversal at all -
  # confirmed live 2026-09-29 this silently breaks every later script
  # that writes into this org's home dir as ubuntu (e.g.
  # vcfa_provider_bootstrap.sh's demo-yaml rendering into
  # /home/${org_name}/yaml-files/): chowning/creating the SUBDIRECTORY as
  # ubuntu isn't enough, Unix requires execute/traverse permission on
  # EVERY ancestor directory, and /home/${org_name} itself still blocked
  # it regardless. o+x only grants traverse (not listing/read) of the
  # home dir itself - its contents stay only as readable as their own
  # individual permissions allow. Re-applied every run (not just at
  # creation) in case an already-existing account predates this fix.
  sudo chmod o+x "/home/${org_name}"
  # chpasswd hashes this itself (system default scheme) - no need to
  # pre-hash with openssl passwd. Re-set every run so a rotated
  # gw_accounts_secret (or a manual re-run) always syncs the password,
  # not just at account-creation time.
  org_password="VMware1!$(echo -n "${gw_accounts_secret}${org_name}" | sha256sum | cut -c1-4)VMware1!"
  echo "${org_name}:${org_password}" | sudo chpasswd

  # vApp use case only: per-org directory for the files the student vApp
  # will later consume (e.g. /home/org-3/wireguard). This script runs as
  # ubuntu, which has no write access inside /home/${org_name} (owned by
  # that org's own account, o+x above only grants traverse), so every step
  # here needs sudo. Owned by the org itself, mode 700: the files that end
  # up here are per-org secrets, so no other org's account (or any other
  # non-root user) should be able to list or read them. ubuntu keeps
  # access via its passwordless sudo, which is also how whatever generates
  # the files later will have to write into it. Re-applied every run
  # (chown/chmod are no-ops once correct), same convergence approach as
  # the password above.
  if [ "${deployment_kind}" == "vApp" ]; then
    wireguard_dir="/home/${org_name}/wireguard"
    if [ ! -d "${wireguard_dir}" ]; then
      sudo mkdir -p "${wireguard_dir}"
      log_notify "created ${wireguard_dir}"
    fi
    sudo chown "${org_name}:${org_name}" "${wireguard_dir}"
    sudo chmod 700 "${wireguard_dir}"

    # OpenRC init script the student VM uses to bring a WireGuard tunnel up
    # and down (wg-quick up/down <interface>, the interface name comes from
    # the service name suffix). Identical for every org, nothing in it is
    # secret - so unlike the directory it sits in, it is mode 755: OpenRC
    # only runs executable init scripts. The quoted heredoc delimiter is
    # required, not cosmetic: it keeps bash from expanding the literal
    # ${SVCNAME#*.} references and $? below. Rewritten every run so a
    # change to the content here always reaches existing orgs too.
    sudo tee "${wireguard_dir}/wg-quick" > /dev/null <<'WG_QUICK_EOF'
#!/sbin/openrc-run

description="WireGuard Tunnel (${SVCNAME#*.})"

depend() {
    need net
    use dns
}

start() {
    ebegin "Starting WireGuard ${SVCNAME#*.}"
    wg-quick up "${SVCNAME#*.}"
    eend $?
}

stop() {
    ebegin "Stopping WireGuard ${SVCNAME#*.}"
    wg-quick down "${SVCNAME#*.}"
    eend $?
}
WG_QUICK_EOF
    sudo chown "${org_name}:${org_name}" "${wireguard_dir}/wg-quick"
    sudo chmod 755 "${wireguard_dir}/wg-quick"

    # WireGuard keypair for this org (wg genkey | tee private.key | wg
    # pubkey > public.key). The whole generate-or-skip decision runs inside
    # ONE shell as the org's own account, not as ubuntu: the directory is
    # 700 and owned by the org, so ubuntu can't create files in it and
    # can't even stat files in it (no search permission). An "does
    # private.key already exist" test run as ubuntu would therefore always
    # come back false and regenerate the key on every run, silently
    # invalidating any peer config that already holds the old public key.
    # umask 077 makes both files 600 and org-owned with no chown needed.
    # An existing private.key is never regenerated; if only public.key went
    # missing it is re-derived from the existing private key. pipefail so a
    # failing wg stage fails the whole pipeline (an empty private.key left
    # behind by tee counts as missing, so the next run regenerates it).
    # Only a generic state word is ever echoed - no key material in logs.
    org_keys_ok="false"
    if command -v wg >/dev/null 2>&1; then
      if ! wg_key_state=$(sudo -u "${org_name}" bash -c '
        set -o pipefail
        umask 077
        cd "$1" || exit 1
        if [ ! -s private.key ]; then
          wg genkey | tee private.key | wg pubkey > public.key || exit 1
          echo generated
        elif [ ! -s public.key ]; then
          wg pubkey < private.key > public.key || exit 1
          echo rederived
        else
          echo exists
        fi' _ "${wireguard_dir}"); then
        log_notify "ERROR: WireGuard key generation failed for ${org_name} in ${wireguard_dir}"
      else
        org_keys_ok="true"
        if [ "${wg_key_state}" != "exists" ]; then
          log_notify "WireGuard keypair ${wg_key_state} for ${org_name}"
        fi
      fi
    fi

    # This org's WireGuard client config, wireguard/wg0.conf: its own tunnel
    # address (see org_tunnel_number above), its own private key (read from
    # the private.key just generated/kept above), the gw as the single peer
    # (gw_wg_public_key, endpoint = gw's IP) and the routed ranges. Rendered
    # as the org's own account for the same reason as the keypair above
    # (ubuntu can't read or stat anything inside the 700 directory), which
    # also keeps the private key out of every command line: it is read from
    # the file inside that shell and only ever lands in the unquoted heredoc,
    # never in an argument. Only non-secret values are passed in as
    # arguments. umask 077 -> file is 600 and org-owned (it holds a private
    # key). Written to a temp file and moved into place only when the content
    # actually changed, so a re-run with nothing new leaves wg0.conf (and its
    # mtime) alone; a changed gw key, endpoint or range reaches existing orgs.
    # Skipped for this org if its keys or the gw-level inputs are missing.
    if [ "${org_keys_ok}" == "true" ] && [ "${wg0_conf_ready}" == "true" ]; then
      if org_tunnel_n=$(org_tunnel_number "${org_name}"); then
        if ! wg0_state=$(sudo -u "${org_name}" bash -c '
          set -o pipefail
          umask 077
          cd "$1" || exit 1
          pk=$(cat private.key) || exit 1
          [ -n "${pk}" ] || exit 1
          cat > wg0.conf.new <<WG_CONF_EOF || exit 1
[Interface]
Address = $2
PrivateKey = ${pk}

[Peer]
# Ubuntu Server
PublicKey = $3
Endpoint = $4:$6
AllowedIPs = $5
PersistentKeepalive = 25
WG_CONF_EOF
          if cmp -s wg0.conf.new wg0.conf; then
            rm -f wg0.conf.new
            echo unchanged
          else
            mv wg0.conf.new wg0.conf
            echo written
          fi' _ "${wireguard_dir}" "${wg_org_tunnel_prefix}.${org_tunnel_n}/24" "${gw_wg_public_key}" "${gw_wg_endpoint_ip}" "${wg_allowed_ips}" "${wg_endpoint_port}"); then
          log_notify "ERROR: wg0.conf rendering failed for ${org_name} in ${wireguard_dir}"
        elif [ "${wg0_state}" != "unchanged" ]; then
          log_notify "wg0.conf ${wg0_state} for ${org_name} (tunnel address ${wg_org_tunnel_prefix}.${org_tunnel_n}/24)"
        fi
        # The same org as a [Peer] of the gw's own /etc/wireguard/wg0.conf
        # (rendered after the loop): its public key (read as the org, inside
        # the 700 directory) and a /32 on its tunnel address. Only collected
        # here; an org whose key can't be read is left out with an error.
        if org_pub=$(sudo -u "${org_name}" cat "${wireguard_dir}/public.key") && [ -n "${org_pub}" ]; then
          gw_peers_conf+="
[Peer]
# ${org_name}
PublicKey = ${org_pub}
AllowedIPs = ${wg_org_tunnel_prefix}.${org_tunnel_n}/32
"
        else
          log_notify "ERROR: could not read ${wireguard_dir}/public.key for ${org_name}, leaving it out of the gw's wg0.conf"
        fi
      else
        log_notify "ERROR: no tunnel address for ${org_name} (its name must end in a number 1-253), skipping its wg0.conf"
      fi
    fi
  fi
done < <(echo "${vcf_a_organizations}" | jq -c -r .[])

# vApp use case only: the gw's own WireGuard server config, consumed on the gw
# itself: /etc/wireguard/wg0.conf (root-owned, 600) with the gw's tunnel
# address (.254), listen port and private key, plus one [Peer] per org
# collected above. Rendered from the orgs currently in the CR, so an org that
# disappeared drops out on the next run. The private key travels only via
# stdin (printf is a builtin, nothing in argv) and the file is created under
# umask 077. Compared against the live file and moved into place only when
# the content changed. Then wg-quick@wg0 is enabled and started (enable
# --now: idempotent, survives reboots). If it was already running and the
# config changed, the new peers are applied live with `wg syncconf` (existing
# tunnels stay up; unlike a restart); if the live wg0 address differs from
# the configured one (syncconf can't change it) it is restarted instead.
if [ "${deployment_kind}" == "vApp" ] && [ -n "${gw_wg_private_key}" ]; then
  gw_wg0_conf="[Interface]
Address = ${wg_gw_tunnel_address}
ListenPort = ${wg_endpoint_port}
PrivateKey = ${gw_wg_private_key}
${gw_peers_conf}"
  gw_wg0_changed="false"
  sudo mkdir -p /etc/wireguard
  sudo chmod 700 /etc/wireguard
  if printf '%s\n' "${gw_wg0_conf}" | sudo sh -c 'umask 077; cat > /etc/wireguard/wg0.conf.new'; then
    if sudo cmp -s /etc/wireguard/wg0.conf.new /etc/wireguard/wg0.conf; then
      sudo rm -f /etc/wireguard/wg0.conf.new
    else
      sudo mv /etc/wireguard/wg0.conf.new /etc/wireguard/wg0.conf
      gw_wg0_changed="true"
      log_notify "gw /etc/wireguard/wg0.conf written ($(printf '%s' "${gw_peers_conf}" | grep -c '^\[Peer\]') peers)"
    fi
  else
    sudo rm -f /etc/wireguard/wg0.conf.new
    log_notify "ERROR: rendering /etc/wireguard/wg0.conf failed"
  fi
  if [ -f /etc/wireguard/wg0.conf ] || sudo test -f /etc/wireguard/wg0.conf; then
    gw_wg0_was_active="false"
    if sudo systemctl is-active --quiet wg-quick@wg0; then gw_wg0_was_active="true"; fi
    if sudo systemctl enable --now wg-quick@wg0; then
      if [ "${gw_wg0_was_active}" == "true" ] && [ "${gw_wg0_changed}" == "true" ]; then
        if ! ip -4 addr show dev wg0 2>/dev/null | grep -q "inet ${wg_gw_tunnel_address} "; then
          # live interface still has another address (e.g. a hand-made wg0):
          # syncconf can't change it, so restart
          if sudo systemctl restart wg-quick@wg0; then
            log_notify "wg0 restarted (its live address differed from ${wg_gw_tunnel_address})"
          else
            log_notify "ERROR: restart of wg-quick@wg0 failed"
          fi
        elif sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'; then
          log_notify "wg0 peers applied live (wg syncconf)"
        else
          log_notify "ERROR: wg syncconf wg0 failed - restart wg-quick@wg0 to apply the new peers"
        fi
      fi
      if sudo systemctl is-active --quiet wg-quick@wg0; then
        log_notify "wg-quick@wg0 enabled and active on ${wg_gw_tunnel_address} udp/${wg_endpoint_port}"
      else
        log_notify "ERROR: wg-quick@wg0 is not active after enable --now"
      fi
    else
      log_notify "ERROR: systemctl enable --now wg-quick@wg0 failed"
    fi
  fi
elif [ "${deployment_kind}" == "vApp" ]; then
  log_notify "ERROR: skipping /etc/wireguard/wg0.conf - no gw WireGuard private key"
fi

log_notify "gw-accounts.sh complete"
