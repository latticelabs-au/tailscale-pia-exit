#!/usr/bin/env bash
# tailscale-pia-exit magic installer
#
#   curl -fsSL https://latticelabs.au/pia.sh | bash
#
# Interactively collects your PIA + Tailscale details, writes the compose
# stack, deploys one exit node per region, and (with a Tailscale OAuth
# client) approves the exit nodes and configures adblocking tailnet DNS.
# Source: https://github.com/latticelabs-au/tailscale-pia-exit
#
# Non-interactive use: set env vars and ASSUME_YES=1, e.g.
#   PIA_USER=p1234567 PIA_PASS=... REGIONS="nz aus_melbourne" \
#   TS_OAUTH_CLIENT_ID=... TS_OAUTH_CLIENT_SECRET=... \
#   LAN_NETWORK=192.168.1.0/24 SETUP_DNS=yes ASSUME_YES=1 bash setup.sh
set -euo pipefail

# ---------- ui ----------
if [ -t 1 ]; then
    B=$'\033[1m'; D=$'\033[2m'; C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
    B=""; D=""; C=""; G=""; Y=""; R=""; N=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s\n' "${G}  ✓${N} $*"; }
warn() { printf '%s\n' "${Y}  !${N} $*"; }
die()  { printf '%s\n' "${R}  ✗ $*${N}" >&2; exit 1; }
step() { printf '\n%s\n' "${B}${C}── $* ──${N}"; }

banner() {
    say ""
    say "${C}${B}  tailscale-pia-exit${N}"
    say "${D}  Tailscale exit nodes routed through PIA WireGuard.${N}"
    say "${D}  MIT · github.com/latticelabs-au/tailscale-pia-exit${N}"
}

# Piped install: read answers from the terminal, not the pipe.
INTERACTIVE=1
if [ "${ASSUME_YES:-}" = "1" ]; then
    INTERACTIVE=0
elif [ -r /dev/tty ]; then
    exec 3</dev/tty
else
    INTERACTIVE=0
fi

# ask VAR "Prompt" "default"  (env var wins; then tty; then default; else die)
ask() {
    local __var="$1" __prompt="$2" __def="${3:-}" __cur __in
    __cur="$(eval "printf '%s' \"\${$__var:-}\"")"
    if [ -n "$__cur" ]; then return 0; fi
    if [ "$INTERACTIVE" = "1" ]; then
        if [ -n "$__def" ]; then
            printf '%s' "  ${B}${__prompt}${N} ${D}[${__def}]${N}: " >&2
        else
            printf '%s' "  ${B}${__prompt}${N}: " >&2
        fi
        IFS= read -r __in <&3 || __in=""
        eval "$__var=\"\${__in:-\$__def}\""
    elif [ -n "$__def" ]; then
        eval "$__var=\"\$__def\""
    else
        die "$__var is required (set it as an env var for non-interactive use)"
    fi
    [ -n "$(eval "printf '%s' \"\$$__var\"")" ] || die "$__var cannot be empty"
}

ask_secret() {
    local __var="$1" __prompt="$2" __in
    if [ -n "$(eval "printf '%s' \"\${$__var:-}\"")" ]; then return 0; fi
    [ "$INTERACTIVE" = "1" ] || die "$__var is required (set it as an env var)"
    printf '%s' "  ${B}${__prompt}${N} ${D}(hidden)${N}: " >&2
    IFS= read -rs __in <&3 || __in=""
    printf '\n' >&2
    eval "$__var=\"\$__in\""
    [ -n "$(eval "printf '%s' \"\$$__var\"")" ] || die "$__var cannot be empty"
}

confirm() { # confirm "question" -> 0/1 (non-interactive: yes)
    [ "$INTERACTIVE" = "1" ] || return 0
    local __in
    printf '%s' "  ${B}$1${N} ${D}[Y/n]${N}: " >&2
    IFS= read -r __in <&3 || __in=""
    case "${__in:-y}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------- preflight ----------
banner
step "Preflight"
command -v docker >/dev/null 2>&1 || die "docker is required (https://docs.docker.com/engine/install/)"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
[ -e /dev/net/tun ] || die "/dev/net/tun not present on this host"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (permissions?)"
ok "docker, compose, python3, /dev/net/tun"

# ---------- inputs ----------
step "PIA account"
ask PIA_USER "PIA username (p1234567 style)"
ask_secret PIA_PASS "PIA password"

step "Regions"
say "  ${D}Common ids: nz · aus_melbourne · aus (Sydney) · us_california · uk · japan${N}"
say "  ${D}Full list: https://github.com/latticelabs-au/tailscale-pia-exit/blob/main/docs/regions.md${N}"
ask REGIONS "Region id(s), space-separated" "nz"
REGIONS="$(printf '%s' "$REGIONS" | tr ',' ' ')"

# Validate against the live serverlist when reachable.
_valid="$(curl -sf --max-time 8 "https://serverlist.piaservers.net/vpninfo/servers/v6" 2>/dev/null | head -1 | python3 -c "
import sys, json
try:
    print(' '.join(r['id'] for r in json.load(sys.stdin)['regions']))
except Exception:
    pass
" 2>/dev/null || true)"
for r in $REGIONS; do
    if [ -n "$_valid" ] && ! printf '%s' " $_valid " | grep -q " $r "; then
        die "unknown PIA region id: $r (see docs/regions.md)"
    fi
done
ok "regions: $REGIONS"

step "Network"
_lan_guess="$(python3 - <<'PY' 2>/dev/null || true
import ipaddress, socket, struct, subprocess
try:
    out = subprocess.check_output(['ip', '-4', 'route', 'show', 'default'], text=True)
    dev = out.split(' dev ')[1].split()[0]
    out = subprocess.check_output(['ip', '-4', '-o', 'addr', 'show', 'dev', dev, 'scope', 'global'], text=True)
    cidr = out.split()[3]
    print(ipaddress.ip_network(cidr, strict=False))
except Exception:
    pass
PY
)"
ask LAN_NETWORK "Your LAN range (lets LAN devices reach the node directly)" "${_lan_guess:-192.168.1.0/24}"
_vpndns_def="8.8.8.8,8.8.4.4"
ask VPN_DNS "DNS inside the tunnel" "$_vpndns_def"
case "$LAN_NETWORK" in 10.0.0.*) warn "LAN overlaps PIA's internal DNS (10.0.0.242/.243); keeping VPNDNS explicit is required" ;; esac

step "Tailscale"
say "  ${D}Three ways to connect the node(s) to your tailnet:${N}"
say "  ${D}  1. paste an auth key   (admin console → Settings → Keys)${N}"
say "  ${D}  2. OAuth client        (Settings → Trust credentials) — also auto-approves"
say "  ${D}     the exit nodes and can set adblocking tailnet DNS for you${N}"
say "  ${D}  3. nothing             (you click a login URL per node, approve manually)${N}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_OAUTH_CLIENT_ID="${TS_OAUTH_CLIENT_ID:-}"
TS_OAUTH_CLIENT_SECRET="${TS_OAUTH_CLIENT_SECRET:-}"
if [ -z "$TS_AUTHKEY" ] && [ -z "$TS_OAUTH_CLIENT_ID" ] && [ "$INTERACTIVE" = "1" ]; then
    ask TS_AUTH_MODE "Choose 1, 2 or 3" "3"
    case "$TS_AUTH_MODE" in
        1) ask_secret TS_AUTHKEY "Auth key (tskey-auth-...)" ;;
        2) ask TS_OAUTH_CLIENT_ID "OAuth client id"
           ask_secret TS_OAUTH_CLIENT_SECRET "OAuth client secret (tskey-client-...)" ;;
        *) : ;;
    esac
elif [ -n "$TS_OAUTH_CLIENT_ID" ]; then
    ask_secret TS_OAUTH_CLIENT_SECRET "OAuth client secret (tskey-client-...)"
fi

INSTALL_DIR="${INSTALL_DIR:-$HOME/pia-exit}"
SETUP_DNS="${SETUP_DNS:-ask}"

# ---------- tailscale api helpers ----------
TS_API="https://api.tailscale.com/api/v2"
TOKEN=""
api() { curl -sf --max-time 20 -H "Authorization: Bearer $TOKEN" "$@"; }
oauth_token() {
    TOKEN="$(curl -sf --max-time 20 -d "client_id=$TS_OAUTH_CLIENT_ID" -d "client_secret=$TS_OAUTH_CLIENT_SECRET" \
        "$TS_API/oauth/token" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")"
    [ -n "$TOKEN" ] || die "OAuth token exchange failed (check client id/secret)"
}

# Optional fast path: OAuth-minted keys must carry an ACL tag (Tailscale rule).
if [ -n "$TS_OAUTH_CLIENT_ID" ] && [ -z "$TS_AUTHKEY" ] && [ -n "${TS_TAG:-}" ]; then
    oauth_token
    _minted="$(api -X POST -H "Content-Type: application/json" -d "{
        \"capabilities\": {\"devices\": {\"create\": {\"reusable\": true, \"ephemeral\": false,
        \"preauthorized\": true, \"tags\": [\"$TS_TAG\"]}}},
        \"expirySeconds\": 3600, \"description\": \"tailscale-pia-exit setup\"}" \
        "$TS_API/tailnet/-/keys" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" || true)"
    if [ -n "$_minted" ]; then
        TS_AUTHKEY="$_minted"
        ok "minted a 1-hour auth key tagged $TS_TAG"
    else
        warn "could not mint an auth key for $TS_TAG (tag must exist in your ACL tagOwners); falling back to login URLs"
    fi
fi

# ---------- write stack ----------
step "Writing stack to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/envs"
cat > "$INSTALL_DIR/docker-compose.yml" <<'YML'
# Generated by the tailscale-pia-exit installer.
# One region per env file: docker compose -p pia-<region> --env-file envs/<region>.env up -d
services:
  pia-exit:
    image: ghcr.io/latticelabs-au/tailscale-pia-exit:latest
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      net.ipv4.ip_forward: "1"
      net.ipv6.conf.all.forwarding: "1"
    environment:
      LOC: ${PIA_LOC:?}
      USER: ${PIA_USER:?}
      PASS: ${PIA_PASS:?}
      LOCAL_NETWORK: ${LAN_NETWORK:-}
      VPNDNS: ${VPN_DNS:-8.8.8.8,8.8.4.4}
      FIREWALL: "1"
      PORT_FORWARDING: "0"
      TS_HOSTNAME: ${TS_HOSTNAME:?}
      TS_AUTHKEY: ${TS_AUTHKEY:-}
    volumes:
      - pia:/pia
      - tailscale:/var/lib/tailscale
    restart: unless-stopped
volumes:
  pia:
  tailscale:
YML

declare -a NODE_NAMES=()
for r in $REGIONS; do
    node="pia-$(printf '%s' "$r" | tr '_' '-')-exit"
    NODE_NAMES+=("$node")
    envf="$INSTALL_DIR/envs/$r.env"
    {
        printf 'PIA_LOC=%s\n' "$r"
        printf 'PIA_USER=%s\n' "$PIA_USER"
        printf 'PIA_PASS=%s\n' "$PIA_PASS"
        printf 'LAN_NETWORK=%s\n' "$LAN_NETWORK"
        printf 'VPN_DNS=%s\n' "$VPN_DNS"
        printf 'TS_HOSTNAME=%s\n' "$node"
        printf 'TS_AUTHKEY=%s\n' "$TS_AUTHKEY"
    } > "$envf"
    chmod 600 "$envf"
    ok "envs/$r.env (node: $node)"
done

# ---------- deploy ----------
step "Deploying"
for r in $REGIONS; do
    proj="pia-$(printf '%s' "$r" | tr '_' '-')"
    say "  ${D}docker compose -p $proj up -d${N}"
    (cd "$INSTALL_DIR" && docker compose -p "$proj" --env-file "envs/$r.env" up -d --quiet-pull 2>&1 | tail -1)
done

say ""
say "  ${D}waiting for tunnels to come up...${N}"
for r in $REGIONS; do
    proj="pia-$(printf '%s' "$r" | tr '_' '-')"
    cname="${proj}-pia-exit-1"
    country=""
    for _ in $(seq 1 24); do
        country="$(docker exec "$cname" sh -c "wget -qO- -T 4 'http://ip-api.com/line/?fields=countryCode'" 2>/dev/null || true)"
        [ -n "$country" ] && break
        sleep 5
    done
    if [ -n "$country" ]; then
        ok "$cname tunnel up, egress country: $country"
    else
        warn "$cname tunnel not confirmed yet; check: docker logs $cname"
    fi
done

# ---------- tailnet join ----------
step "Connecting to your tailnet"
if [ -z "$TS_AUTHKEY" ]; then
    for r in $REGIONS; do
        proj="pia-$(printf '%s' "$r" | tr '_' '-')"
        cname="${proj}-pia-exit-1"
        url=""
        for _ in $(seq 1 24); do
            url="$(docker logs "$cname" 2>&1 | grep -o 'https://login\.tailscale\.com/[A-Za-z0-9/]*' | head -1 || true)"
            [ -n "$url" ] && break
            sleep 5
        done
        if [ -n "$url" ]; then
            say "  ${B}$cname${N} → open and sign in: ${C}$url${N}"
        else
            warn "$cname: no login URL yet; run: docker logs $cname | grep login.tailscale.com"
        fi
    done
    say "  ${D}(waiting for you to authenticate each node before continuing)${N}"
else
    ok "auth key provided; nodes should join automatically (verified below)"
fi

if [ -n "$TS_OAUTH_CLIENT_ID" ]; then
    [ -n "$TOKEN" ] || oauth_token
    say ""
    say "  ${D}waiting for node(s) to appear in the tailnet, then approving exit routes...${N}"
    DEVICE_WAIT_SECS="${DEVICE_WAIT_SECS:-300}"
    for i in "${!NODE_NAMES[@]}"; do
        node="${NODE_NAMES[$i]}"
        r="$(printf '%s' "$REGIONS" | tr ' ' '\n' | sed -n "$((i + 1))p")"
        cname="pia-$(printf '%s' "$r" | tr '_' '-')-pia-exit-1"
        dev_id=""
        url_shown=0
        waited=0
        while [ "$waited" -lt "$DEVICE_WAIT_SECS" ]; do
            dev_id="$(api "$TS_API/tailnet/-/devices" | python3 -c "
import sys, json
for d in json.load(sys.stdin)['devices']:
    if d.get('hostname') == '$node':
        print(d['id']); break
" 2>/dev/null || true)"
            [ -n "$dev_id" ] && break
            # A dead/expired auth key fails silently forever; detect it and
            # fall back to the interactive login URL instead of waiting.
            # (substring match, not grep -q: pipefail + grep -q dies of
            # SIGPIPE on long logs and the condition silently never fires)
            _recent_logs="$(docker logs "$cname" 2>&1 | tail -200 || true)"
            if [ "$url_shown" = "0" ] && [ "${_recent_logs#*invalid key}" != "$_recent_logs" ]; then
                warn "$node: the auth key was rejected (expired/revoked); switching to login-URL flow"
                url="$(docker exec "$cname" sh -c 'timeout 15 tailscale login 2>&1 || true' | grep -o 'https://login\.tailscale\.com/[A-Za-z0-9/]*' | head -1 || true)"
                if [ -n "$url" ]; then
                    say "  ${B}$node${N} → open and sign in: ${C}$url${N}"
                else
                    warn "$node: get a login URL with: docker exec $cname tailscale login"
                fi
                url_shown=1
            fi
            sleep 5; waited=$((waited + 5))
        done
        [ -n "$dev_id" ] || { warn "$node not in the tailnet yet; once it joins, approve it in the admin console"; continue; }
        # Union existing enabled routes with the exit routes (never clobber).
        api "$TS_API/device/$dev_id?fields=all" | python3 -c "
import sys, json
d = json.load(sys.stdin)
routes = sorted(set(d.get('enabledRoutes') or []) | {'0.0.0.0/0', '::/0'})
print(json.dumps({'routes': routes}))
" | api -X POST -H "Content-Type: application/json" -d @- "$TS_API/device/$dev_id/routes" >/dev/null \
            && ok "$node approved as an exit node" \
            || warn "$node: route approval failed; approve manually in the admin console"
    done

    # ---------- adblocking dns ----------
    want_dns=0
    case "$SETUP_DNS" in
        yes) want_dns=1 ;;
        no)  want_dns=0 ;;
        *)   confirm "Set adblocking tailnet DNS (AdGuard + Mullvad, all devices)?" && want_dns=1 || true ;;
    esac
    if [ "$want_dns" = "1" ]; then
        step "Tailnet DNS"
        TARGET_DNS='["94.140.14.14", "94.140.15.15", "194.242.2.4"]'
        current="$(api "$TS_API/tailnet/-/dns/nameservers" | python3 -c "import sys,json; print(' '.join(sorted(json.load(sys.stdin).get('dns',[]))))")"
        target_flat="$(printf '%s' "$TARGET_DNS" | python3 -c "import sys,json; print(' '.join(sorted(json.load(sys.stdin))))")"
        if [ "$current" = "$target_flat" ]; then
            # Same set (order-insensitive): write nothing, preserve the
            # console-side per-nameserver settings exactly as they are.
            ok "global nameservers already set ($current)"
        elif [ -n "$current" ]; then
            warn "tailnet already has nameservers: $current"
            # Replacing someone's existing resolvers is destructive; it never
            # happens implicitly. Interactive: ask. Non-interactive: only
            # with REPLACE_DNS=1.
            if { [ "$INTERACTIVE" = "1" ] && confirm "Replace them with the adblocking set ($target_flat)?"; } \
               || [ "${REPLACE_DNS:-}" = "1" ]; then
                api -X POST -H "Content-Type: application/json" -d "{\"dns\": $TARGET_DNS}" "$TS_API/tailnet/-/dns/nameservers" >/dev/null
                ok "nameservers set: $target_flat"
            else
                ok "keeping your existing nameservers (set REPLACE_DNS=1 to override)"
            fi
        else
            api -X POST -H "Content-Type: application/json" -d "{\"dns\": $TARGET_DNS}" "$TS_API/tailnet/-/dns/nameservers" >/dev/null
            ok "nameservers set: $target_flat (AdGuard x2 + Mullvad base)"
        fi
        api -X POST -H "Content-Type: application/json" -d '{"magicDNS": true}' "$TS_API/tailnet/-/dns/preferences" >/dev/null || true
        ok "MagicDNS on"
        say ""
        warn "two toggles the API cannot set — takes 20 seconds in the console:"
        say "     ${C}https://login.tailscale.com/admin/dns${N}"
        say "     1. ${B}Override DNS servers${N} → on (forces every device through these resolvers)"
        say "     2. each nameserver → ${B}Use with exit node${N} → on (keeps adblocking active on exit nodes)"
    fi
else
    say ""
    say "  ${D}No OAuth client: finish in the admin console (https://login.tailscale.com/admin/machines):${N}"
    say "  ${D}each node → ⋯ → Edit route settings → Use as exit node; and consider Disable key expiry.${N}"
fi

# ---------- summary ----------
step "Done"
for node in "${NODE_NAMES[@]}"; do
    say "  ${G}●${N} ${B}$node${N} ${D}— pick it from the Tailscale exit-node menu on any device${N}"
done
say ""
say "  ${D}verify:   curl https://ipinfo.io      (with the exit node selected)${N}"
say "  ${D}manage:   cd $INSTALL_DIR && docker compose -p pia-<region> ...${N}"
say "  ${D}docs:     https://github.com/latticelabs-au/tailscale-pia-exit${N}"
say ""
