# How it works

## The namespace trick

The whole design rests on one Docker feature: `network_mode: service:<name>`.
When the `tailscale` container declares `network_mode: service:wireguard`, it
does not get its own network stack. It joins the `wireguard` container's network
namespace and shares its interfaces, routing table, and firewall.

The `wireguard` container brings up a PIA WireGuard interface and policy-routes
the namespace's default path into it, with a kill switch dropping everything
else. So all payload traffic, including everything peers send through the exit
node, can only leave via the PIA tunnel. The one deliberate exception is
Tailscale's own transport, which is mark-routed around the tunnel in kernel
mode; see "The transport/payload split" below.

```
             shared network namespace
  ┌───────────────────────────────────────────────┐
  │  tailscale0 (TUN) ── kernel forward + NAT      │
  │      │  advertises: exit node                  │
  │      ▼                                          │
  │  default route ──▶ wg0 (PIA WireGuard) ──▶ internet
  │                    kill switch: DROP all else   │
  └───────────────────────────────────────────────┘
     ▲
     │ tailnet peers select this node as their exit node
     │ (LAN peers connect direct; remote peers may use DERP)
```

## What each piece does

### wireguard (`thrnz/docker-wireguard-pia`)

PIA does not expose plain WireGuard config files. Its WireGuard support needs a
per-region token exchange: authenticate with your PIA username and password, get
a token, then call the chosen server's `addKey` endpoint to register your public
key and receive the peer details. This image performs that dance on every start,
so you never hand-maintain a `wg0.conf`, and a region change is just an env-var
change.

It also installs a firewall kill switch: only traffic over the WireGuard
interface (plus any `LOCAL_NETWORK` you allow) is permitted. If the tunnel drops,
egress fails closed.

### tailscale (`tailscale/tailscale`)

Runs in kernel networking mode (`TS_USERSPACE=false`, the default here).
tailscaled creates its own `tailscale0` TUN device inside the shared namespace
and installs its iptables chains (`ts-input`, `ts-forward`, `ts-postrouting`)
alongside the PIA image's kill-switch rules. Exit-node traffic from peers
arrives on `tailscale0`, is forwarded by the kernel, masqueraded, and leaves via
`wg0`. The kill switch still holds: the only route out of the namespace for
payload traffic remains the PIA tunnel.

`--advertise-exit-node` tells the tailnet this node is willing to be an exit.
`TS_ACCEPT_DNS=false` stops Tailscale's MagicDNS from overriding the tunnel's
resolver, which would otherwise be a DNS-leak vector.

### The transport/payload split (kernel mode)

In kernel mode, tailscaled fwmarks its own transport sockets (`0x80000`) and
installs policy-routing rules (priority 5210-5250) that send marked packets via
the main routing table, bypassing the VPN redirect. This is deliberate,
standard Tailscale behaviour: the tunnel's own transport must not route through
the tunnel it provides, and it is the same split Tailscale's built-in Mullvad
integration uses. The compose adds one firewall rule (see the `entrypoint`
wrapper) whitelisting that mark, because the PIA image's kill switch only knows
its own mark and would otherwise drop tailscaled's control traffic outright,
leaving the node permanently logged out.

The result:

- **Payload** (what you browse via the exit node) is unmarked, hits the VPN
  policy route, and can only leave via `wg0`. Kill switch applies. PIA IP.
- **Transport** (control plane, DERP, encrypted WireGuard to your peers) leaves
  via the raw uplink. Your ISP sees encrypted Tailscale traffic, as it would
  for any Tailscale node; the coordination server sees your real IP. This is
  what makes direct peer connections possible instead of DERP relays.

If you want *everything*, transport included, inside the PIA tunnel, set
`TS_USERSPACE=true`: userspace mode never marks packets, so all traffic follows
the VPN route. The cost is roughly half your throughput (see below) and
DERP-relayed connections for peers that cannot reach the node over LAN.

Userspace mode is also the fallback if your host cannot grant
`NET_ADMIN`/`NET_RAW` or a TUN device to the tailscale container (some NAS and
rootless setups). In userspace mode, peer connections terminate in Tailscale's
userspace network stack (gVisor netstack) and are re-originated as ordinary
socket connections, so no TUN or extra capabilities are needed.

## Performance

Measured with both containers on the same Docker host and the client on the
same LAN, AU test targets, via PIA Melbourne.

Real-world (Ookla, parallel streams), exit node on versus off:

| Path | Download | Upload | Idle latency |
|---|---|---|---|
| Raw line, exit node off | 869 Mbps | 95 Mbps | 9.5 ms |
| Through the exit node, kernel mode | 676 Mbps | 89 Mbps | 11.2 ms |

Single-stream (one curl download), the controlled comparison between modes:

| Path | Throughput |
|---|---|
| PIA tunnel ceiling, measured inside the node | ~620 Mbps |
| Client through the exit node, kernel mode (default) | ~510 Mbps |
| Client through the exit node, userspace mode | ~285 Mbps |

Userspace netstack costs roughly half the tunnel's ceiling because every
forwarded flow is terminated and re-originated in userspace. Kernel mode
forwards packets in the kernel and recovers most of that gap (~83% of the
tunnel ceiling on the reference deploy), which is why it is the default.

## Trade-offs and gotchas

- **Connection paths.** In kernel mode (default), Tailscale transport uses the
  raw uplink, so peers negotiate direct connections the same way they would to
  any ordinary node: LAN peers punch through immediately (verified: ~1ms
  direct), and remote peers hole-punch or fall back to DERP depending on NATs,
  as usual. In userspace mode, transport is forced through the VPN, so remote
  peers usually end up DERP-relayed.
- **Exit-node approval is manual.** `--advertise-exit-node` only offers the node.
  You still approve it once in the admin console (or via an auto-approver ACL).
  Until approved, clients show "no exit node available" even though the node is
  advertising.
- **Key expiry.** Tailscale nodes expire (about 90 days) unless you disable key
  expiry on the node or use a reusable, tagged auth key. For a long-lived exit
  node, do one of those so it does not silently drop off the tailnet.
- **VPN reconnects vs firewall rules (kernel mode).** tailscaled installs its
  iptables chains once at startup. If the PIA image rebuilds its firewall on a
  reconnect and Tailscale's jump rules get flushed, exit traffic stops until the
  tailscale container restarts. If the exit node goes quiet after a VPN blip,
  `docker compose -p <project> restart tailscale` fixes it.
- **MTU.** If you see fast uploads but slow downloads, that is the classic sign
  of an MTU mismatch. The PIA WireGuard MTU is handled by the image; if you still
  hit it, tune it down toward 1280 on the WireGuard side.
- **`ip_forward`.** The compose sets `net.ipv4.ip_forward=1` on the WireGuard
  container (the namespace owner) so the shared namespace will forward exit-node
  traffic.
- **IPv6.** PIA tunnels are IPv4-only, so the node only usefully routes IPv4.
  Tailscale still advertises `::/0` and will warn that IPv6 forwarding is off;
  that is expected and harmless here.

## The single-container image

`ghcr.io/latticelabs-au/tailscale-pia-exit` fuses both halves into one
container: the thrnz base image plus Tailscale's static binaries, started via
the base image's `POST_UP` hook so tailscaled only comes up after the tunnel
is up. `POST_RECONNECT` runs the same script again, so the firewall holes and
tailscaled are re-asserted after every PIA reconnect, which closes the
"reconnect flushed my rules" edge the two-container mode documents.

Because there is only one container, the firewall holes are punched with the
same iptables binary the kill switch uses, so the legacy-vs-nftables backend
mismatch (see below) cannot occur by construction. Built for amd64 + arm64 by
[the publish workflow](../.github/workflows/publish.yml), rebuilt weekly to
pick up upstream updates.

## Firewall gotchas this repo absorbs for you

Three real bugs were found and fixed while building this, all invisible until
you test end to end. Recorded here for anyone assembling this pattern by hand:

1. **Transport fwmark vs kill switch.** Kernel-mode tailscaled fwmarks its
   transport (`0x80000`) and policy-routes it around the VPN. The PIA kill
   switch only whitelists its own wg-quick mark, so the node's control-plane
   traffic is silently dropped and it sits logged out forever. Fix: accept the
   tailscale mark in the kill switch's OUTPUT chain.
2. **iptables backend mismatch.** The `tailscale/tailscale` image's plain
   `iptables` is the *legacy* backend; the PIA image's rules live in
   *nftables*. Rules written with the wrong binary land in a table the kill
   switch never consults and do nothing. Fix: always use `iptables-nft` from
   the sidecar (or the base image's own binary in single-container mode), and
   pin `TS_DEBUG_FIREWALL_MODE=nftables` so tailscaled's own rules land there
   too.
3. **Cross-table DROP wins.** nftables gives every hook chain a vote and any
   DROP wins, so an ACCEPT in tailscaled's own table cannot override the PIA
   table's `FORWARD DROP` policy. Exit traffic dies even though tailscaled's
   rules look correct. Fix: accept `tailscale0` INPUT/FORWARD in the PIA
   table itself.

## Why not gluetun?

[gluetun](https://github.com/qdm12/gluetun) is excellent and supports PIA over
**OpenVPN** natively. For PIA over **WireGuard**, gluetun does not perform the
token/`addKey` registration itself: you have to generate the WireGuard config
out of band and feed it in as a custom provider. `thrnz/docker-wireguard-pia` was
built specifically for the PIA WireGuard path and does that registration on its
own from your username and password, which is why it is the WireGuard side here.
If you prefer OpenVPN, swapping in gluetun is a drop-in change to the `wireguard`
service.
