# Fused single-container image: PIA WireGuard tunnel + Tailscale exit node.
#
# Base: thrnz/docker-wireguard-pia (does PIA's native WireGuard token/addKey
# registration and runs the kill switch). Tailscale's static binaries are
# grafted on and started via the base image's POST_UP hook, so tailscaled
# comes up only after the tunnel is up, and is re-asserted after every
# reconnect.
#
# Because everything runs in one container, the firewall holes for Tailscale
# are punched with the SAME iptables binary the kill switch uses - the whole
# class of legacy-vs-nftables backend mismatch bugs is gone by construction.

FROM tailscale/tailscale:stable AS tailscale

FROM thrnz/docker-wireguard-pia:latest

COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscale

COPY tailscale-up.sh /opt/tailscale-up.sh
RUN chmod +x /opt/tailscale-up.sh

# POST_UP starts tailscaled once the tunnel is up; POST_RECONNECT re-punches
# the firewall holes and re-ups after the base image rebuilds its rules.
ENV POST_UP=/opt/tailscale-up.sh \
    POST_RECONNECT=/opt/tailscale-up.sh \
    TS_DEBUG_FIREWALL_MODE=nftables

VOLUME /var/lib/tailscale
