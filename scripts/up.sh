#!/usr/bin/env bash
# Convenience wrapper to bring up one region node.
#
#   ./scripts/up.sh nz          # uses envs/nz.env,        project pia-nz
#   ./scripts/up.sh melbourne   # uses envs/melbourne.env, project pia-melbourne
#
# The region name is just a label for the env file and project; the actual PIA
# region comes from PIA_LOC inside the env file.
set -euo pipefail

region="${1:?usage: ./scripts/up.sh <region-label>  (expects envs/<label>.env)}"
env_file="envs/${region}.env"
project="pia-${region}"

if [ ! -f "$env_file" ]; then
  echo "Missing $env_file. Copy .env.example to it and fill it in." >&2
  exit 1
fi

docker compose -p "$project" --env-file "$env_file" up -d
echo
echo "Node '$project' starting. Login URL (if not using TS_AUTHKEY):"
echo "  docker compose -p $project logs tailscale | grep -m1 'https://login.tailscale.com'"
