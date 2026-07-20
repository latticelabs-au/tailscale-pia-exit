# How it works

## The namespace trick

The whole design rests on one Docker feature: `network_mode: service:<name>`.
When the `tailscale` container declares `network_mode: service:wireguard`, it
does not get its own network stack. It joins the `wireguard` container's network
namespace and shares its interfaces, routing table, and firewall.

The `wireguard` container brings up a PIA WireGuard interface and sets the
default route to it (with a kill switch dropping everything else). So from the
moment Tailscale starts, the only way out of the shared namespace is the PIA
tunnel. Tailscale cannot leak around it, because there is no other route to leak
to.

```
             shared network namespace
  ┌───────────────────────────────────────────────┐
  │  tailscaled (userspace netstack)               │
  │      │  advertises: exit node                  │
  │      ▼                                          │
  │  default route ──▶ wg0 (PIA WireGuard) ──▶ internet
  │                    kill switch: DROP all else   │
  └───────────────────────────────────────────────┘
     ▲
     │ tailnet peers select this node as their exit node
     │ (traffic arrives over WireGuard, relayed via DERP)
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

Runs in userspace-networking mode (`TS_USERSPACE=true`). Userspace mode is enough
to run an exit node: incoming connections from tailnet peers terminate in
Tailscale's userspace network stack and are re-originated as ordinary socket
connections from the container, which then follow the namespace's default route
out through PIA. No second TUN device is needed, which keeps the single
`/dev/net/tun` free for the WireGuard side.

`--advertise-exit-node` tells the tailnet this node is willing to be an exit.
`TS_ACCEPT_DNS=false` stops Tailscale's MagicDNS from overriding the tunnel's
resolver, which would otherwise be a DNS-leak vector.

## Trade-offs and gotchas

- **DERP-relayed connections.** Because the node sits behind a VPN with a
  firewalled namespace, tailnet peers usually cannot establish a direct
  peer-to-peer path to it and fall back to a DERP relay. That is fine for
  browsing and general use; it is not ideal if you need maximum throughput. This
  is inherent to the "Tailscale behind a VPN" pattern, not specific to this repo.
- **Exit-node approval is manual.** `--advertise-exit-node` only offers the node.
  You still approve it once in the admin console (or via an auto-approver ACL).
- **Key expiry.** Tailscale nodes expire (about 90 days) unless you disable key
  expiry on the node or use a reusable, tagged auth key. For a long-lived exit
  node, do one of those so it does not silently drop off the tailnet.
- **MTU.** If you see fast uploads but slow downloads, that is the classic sign
  of an MTU mismatch. The PIA WireGuard MTU is handled by the image; if you still
  hit it, tune it down toward 1280 on the WireGuard side.
- **`ip_forward`.** The compose sets `net.ipv4.ip_forward=1` on the WireGuard
  container (the namespace owner) so the shared namespace will forward exit-node
  traffic.

## Why not gluetun?

[gluetun](https://github.com/qdm12/gluetun) is excellent and supports PIA over
**OpenVPN** natively. For PIA over **WireGuard**, gluetun does not perform the
token/`addKey` registration itself: you have to generate the WireGuard config
out of band and feed it in as a custom provider. `thrnz/docker-wireguard-pia` was
built specifically for the PIA WireGuard path and does that registration on its
own from your username and password, which is why it is the WireGuard side here.
If you prefer OpenVPN, swapping in gluetun is a drop-in change to the `wireguard`
service.
