#!/bin/bash
# Runs as the base image's POST_UP hook (after the PIA WireGuard interface is
# up) and again as POST_RECONNECT (after a reconnect rebuilds the firewall).
# Everything here is idempotent.

# --- Firewall holes for Tailscale alongside the PIA kill switch -------------
# Uses this image's own iptables, i.e. the exact binary/backend the kill
# switch rules live in.
#
#   OUTPUT mark 0x80000: tailscaled fwmarks its own transport (control plane,
#   DERP, peer WireGuard) to bypass the exit route - standard Tailscale
#   behaviour. Payload traffic is unmarked and still leaves only via wg0.
#   INPUT/FORWARD tailscale0: the kill switch's DROP policies must accept
#   exit-node traffic in their own table; an ACCEPT in tailscaled's table
#   cannot override another table's DROP.
add() { iptables -C "$@" 2>/dev/null || iptables -I "$@"; }
add OUTPUT -m mark --mark 0x80000/0xff0000 -j ACCEPT
add INPUT -i tailscale0 -j ACCEPT
add FORWARD -i tailscale0 -j ACCEPT
add FORWARD -o tailscale0 -j ACCEPT

# Exit-node forwarding needs ip_forward inside the namespace. Compose usually
# sets this via sysctls; this covers plain `docker run` too. v6 forwarding
# only satisfies Tailscale's health check (::/0 is advertised); PIA tunnels
# are v4-only so no v6 traffic actually egresses.
sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
sysctl -qw net.ipv6.conf.all.forwarding=1 2>/dev/null || true

# --- optional PIA IP rotation -----------------------------------------------
# ROTATE_HOURS=<n> cleanly shuts the container down after ~n hours; the
# restart policy brings it back with a freshly registered PIA server and a
# different shared egress IP. The interval is jittered +/-20% so the rotation
# cadence itself is not a fingerprint. ROTATE_SECONDS overrides for testing.
case "${ROTATE_HOURS:-0}" in
    ''|0) : ;;
    *[!0-9]*) echo "[rotate] ROTATE_HOURS must be a whole number of hours; rotation disabled" >&2 ;;
    *)
        if [ ! -e /var/run/rotate-supervisor ]; then
            touch /var/run/rotate-supervisor
            (
                base="${ROTATE_SECONDS:-$((ROTATE_HOURS * 3600))}"
                jitter=$((base / 5))
                [ "$jitter" -gt 0 ] || jitter=1
                sleep_for=$((base - jitter + RANDOM % (2 * jitter + 1)))
                echo "[rotate] next PIA IP rotation in ${sleep_for}s" >&2
                sleep "$sleep_for"
                echo "[rotate] rotating: clean shutdown, restart policy re-registers with PIA" >&2
                kill -TERM 1
            ) &
        fi
        ;;
esac

# --- tailscaled -------------------------------------------------------------
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
mkdir -p "$TS_STATE_DIR" /var/run/tailscale

# Supervise tailscaled in the background; started once, survives reconnect
# hook re-entry.
if [ ! -e /var/run/tailscale-supervisor ]; then
    touch /var/run/tailscale-supervisor
    (
        while true; do
            /usr/local/bin/tailscaled \
                --state="$TS_STATE_DIR/tailscaled.state" \
                --socket=/var/run/tailscale/tailscaled.sock
            echo "[tailscale-up] tailscaled exited; restarting in 5s" >&2
            sleep 5
        done
    ) &
fi

# Wait for the daemon socket, then bring the node up. Without TS_AUTHKEY the
# login URL is printed to the container log; the timeout stops the hook from
# blocking the base image's startup while it waits for the browser login
# (tailscaled keeps the pending login alive, so the URL stays clickable).
for _ in $(seq 1 30); do
    [ -S /var/run/tailscale/tailscaled.sock ] && break
    sleep 1
done

if [ -z "${TS_AUTHKEY:-}" ]; then
    echo "[tailscale-up] TS_AUTHKEY not set: authenticate via the login URL below (docker logs | grep login.tailscale.com)"
fi

/usr/local/bin/tailscale up \
    --timeout=60s \
    ${TS_AUTHKEY:+--authkey="$TS_AUTHKEY"} \
    --hostname="${TS_HOSTNAME:-pia-exit}" \
    --accept-dns="${TS_ACCEPT_DNS:-false}" \
    ${TS_EXTRA_ARGS:---advertise-exit-node} || true
