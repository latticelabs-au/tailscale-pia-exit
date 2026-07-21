#!/usr/bin/env bash
# Rotate a node's PIA egress IP by forcing a fresh PIA server registration.
#
#   ./scripts/rotate.sh pia-nz          # compose (two-container) project
#   ./scripts/rotate.sh pia-nz 1        # also wait and print old -> new IP
#
# Works for both deployment modes:
#   - two-container compose: restarts wireguard (new tunnel + netns), then the
#     tailscale sidecar so it rejoins the new namespace
#   - single fused container: one restart does everything
#
# Schedule it (cron) with jitter so the cadence isn't a fingerprint, e.g.:
#   0 */6 * * * bash -c 'sleep $((RANDOM % 1800)); /path/to/rotate.sh pia-nz'
set -euo pipefail

project="${1:?usage: rotate.sh <compose-project> [verify]}"
verify="${2:-}"

wg="${project}-wireguard-1"
ts="${project}-tailscale-1"
fused="${project}-pia-exit-1"

ip_of() { docker exec "$1" curl -s --max-time 8 ipinfo.io/ip 2>/dev/null || echo "?"; }

if docker inspect "$fused" >/dev/null 2>&1; then
    old="$(ip_of "$fused")"
    docker restart "$fused" >/dev/null
    main="$fused"
elif docker inspect "$wg" >/dev/null 2>&1; then
    old="$(ip_of "$wg")"
    docker restart "$wg" >/dev/null
    # Wait for the tunnel before reviving the sidecar into the new netns.
    for _ in $(seq 1 30); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$wg" 2>/dev/null)" = "healthy" ] && break
        sleep 2
    done
    docker restart "$ts" >/dev/null
    main="$wg"
else
    echo "no container found for project '$project'" >&2
    exit 1
fi

if [ -n "$verify" ]; then
    new="?"
    for _ in $(seq 1 24); do
        new="$(ip_of "$main")"
        [ "$new" != "?" ] && [ -n "$new" ] && break
        sleep 5
    done
    echo "$project rotated: $old -> $new"
else
    echo "$project rotation triggered (was $old)"
fi
