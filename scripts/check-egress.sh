#!/usr/bin/env bash
# Print the public IP and geo the given node is egressing from, straight out of
# the WireGuard container, so you can confirm the PIA tunnel and region before
# (or without) touching Tailscale.
#
#   ./scripts/check-egress.sh pia-nz
#
# Arg is the compose project name you brought the node up with (-p).
set -euo pipefail

project="${1:-pia-exit}"
cid="$(docker compose -p "$project" ps -q wireguard)"

if [ -z "$cid" ]; then
  echo "No running 'wireguard' container for project '$project'." >&2
  echo "Bring it up first, e.g.: docker compose -p $project --env-file envs/${project#pia-}.env up -d" >&2
  exit 1
fi

echo "Egress for project '$project':"
docker exec "$cid" sh -c 'wget -qO- https://ipinfo.io 2>/dev/null || curl -s https://ipinfo.io'
echo
