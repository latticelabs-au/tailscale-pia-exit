# tailscale-pia-exit

A Tailscale [exit node](https://tailscale.com/kb/1103/exit-nodes) whose internet
egress is routed through a [Private Internet Access](https://www.privateinternetaccess.com/)
WireGuard tunnel, in two small containers.

Pick a device on your tailnet, flip on the exit node, and all of its traffic
leaves via PIA in the region you chose. You get Tailscale **and** a commercial
VPN at the same time, without installing a VPN client on every device and
without choosing one over the other.

```
 your phone / laptop  ──tailnet──▶  [ tailscale ]──shares netns──[ wireguard/PIA ]──▶  internet
   (exit node: on)                   exit node          PIA WireGuard tunnel        (PIA egress IP)
```

## Why

Running a VPN client and Tailscale on the same machine usually means they fight
over the default route: one wins, the other breaks. This side-steps that. The
exit node lives in its own network namespace where the **only** route out is the
PIA tunnel, and Tailscale simply offers that namespace to the rest of your
tailnet. Any device can opt in per-connection from the exit-node menu, and opt
back out just as fast.

Run one per region and you get a menu of exit locations (for example, a New
Zealand node and a Melbourne node) that any tailnet device can switch between.

## How it works

- **`wireguard`** ([`thrnz/docker-wireguard-pia`](https://github.com/thrnz/docker-wireguard-pia))
  does PIA's native WireGuard handshake: it exchanges your PIA username and
  password for a token, registers a key with the chosen region's server, brings
  up the tunnel, and runs a kill switch so nothing leaks if the tunnel drops.
- **`tailscale`** runs with `network_mode: service:wireguard`, so it has no
  network of its own: its uplink is the PIA tunnel. It advertises itself as an
  exit node with `--advertise-exit-node`.

Because the two containers share a namespace, Tailscale's own control-plane and
DERP traffic also travel through PIA. To the tailnet the node is just another
exit option; to the internet it is a PIA IP.

See [`docs/how-it-works.md`](docs/how-it-works.md) for the routing detail and the
known trade-offs (chiefly: peers usually reach the node over a DERP relay rather
than a direct connection, which is fine for browsing).

## Requirements

- A host running Docker with the Compose plugin.
- `/dev/net/tun` available on the host (standard on Linux; present on TrueNAS SCALE).
- A PIA subscription (username like `p1234567` and its password).
- A Tailscale account.

## Quick start

```bash
git clone https://github.com/latticelabs-au/tailscale-pia-exit.git
cd tailscale-pia-exit

mkdir -p envs
cp .env.example envs/nz.env
# edit envs/nz.env: PIA_USER, PIA_PASS, PIA_LOC, TS_HOSTNAME

docker compose -p pia-nz --env-file envs/nz.env up -d
```

If you left `TS_AUTHKEY` empty, grab the one-time login URL and open it to add
the node to your tailnet:

```bash
docker compose -p pia-nz logs tailscale | grep -m1 'https://login.tailscale.com'
```

Then, in the [Tailscale admin console](https://login.tailscale.com/admin/machines):

1. Open the new machine's menu and **approve the exit node**.
2. (Recommended) **Disable key expiry** on the machine so the node does not drop
   off the tailnet in ~90 days.

Now on any device, pick this machine from the exit-node menu. Confirm your
egress:

```bash
curl https://ipinfo.io    # should show a PIA IP in your chosen region
```

## Multiple regions

The same compose file spins up as many regions as you want: give each its own
project name (`-p`) and env file. Compose prefixes the volumes with the project
name, so their state stays separate.

```bash
docker compose -p pia-nz   --env-file envs/nz.env        up -d
docker compose -p pia-melb --env-file envs/melbourne.env up -d
```

A worked two-region example lives in [`examples/multi-region/`](examples/multi-region/).

## Verifying egress

You can confirm the PIA tunnel is up and in the right region before Tailscale is
even authenticated:

```bash
./scripts/check-egress.sh pia-nz     # prints the container's public IP + geo
```

## Operating notes

- **Stop / start:** `docker compose -p pia-nz down` / `up -d`.
- **Change region:** edit `PIA_LOC` in the env file and `up -d` again.
- **Update images:** `docker compose -p pia-nz pull && docker compose -p pia-nz up -d`.
- **Key expiry:** either disable key expiry on the node, or deploy with a
  reusable, tagged `TS_AUTHKEY` and let it re-auth on restart.
- **Kill switch:** if the PIA tunnel drops, the wireguard container's firewall
  blocks all other egress, so the exit node fails closed rather than leaking to
  your raw uplink.

## Credits

Stands on the shoulders of [`thrnz/docker-wireguard-pia`](https://github.com/thrnz/docker-wireguard-pia)
and the official [`tailscale/tailscale`](https://tailscale.com/kb/1282/docker)
image. This repo is just the glue and the documentation.

## License

MIT. See [`LICENSE`](LICENSE).
