# Multi-region example: New Zealand + Melbourne

Two exit nodes on one host, so any tailnet device can switch between a New
Zealand egress and a Melbourne egress from the exit-node menu.

Copy the two example env files up into your `envs/` directory, fill in your PIA
credentials, and bring both up:

```bash
mkdir -p envs
cp examples/multi-region/nz.env.example        envs/nz.env
cp examples/multi-region/melbourne.env.example envs/melbourne.env
# edit both: PIA_USER, PIA_PASS

docker compose -p pia-nz   --env-file envs/nz.env        up -d
docker compose -p pia-melb --env-file envs/melbourne.env up -d
```

Each project keeps its own volumes (`pia-nz_*`, `pia-melb_*`), so their PIA keys
and Tailscale state never collide.

Authenticate each node once:

```bash
docker compose -p pia-nz   logs tailscale | grep -m1 'https://login.tailscale.com'
docker compose -p pia-melb logs tailscale | grep -m1 'https://login.tailscale.com'
```

Open both URLs, then in the admin console approve each as an exit node and
disable key expiry on both.
