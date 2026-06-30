# Remote Access — `venom`

All remote administration goes through a single WireGuard tunnel. There is no internet-facing management surface: the Proxmox web UI, SSH, and every service are reachable only *after* the tunnel is established. See [`architecture.md`](architecture.md) for the design rationale; this document is the operational walkthrough.

---

## The model in one line

Connect WireGuard → land on the host at `10.10.10.1` → SSH into the host → `pct enter` into the container you need.

```
your client  ──WireGuard──>  venom (10.10.10.1)  ──SSH──>  host shell  ──pct enter──>  container
```

---

## One-time setup

**Server side** (on the Proxmox host) lives in `/etc/wireguard/wg0.conf` — see [`../config/wg0.conf.example`](../config/wg0.conf.example) for the sanitized template. WireGuard runs on the host itself (not in a container) so the tunnel can reach every LXC and LAN service through the host's routing.

**Edge router:** a single inbound rule forwards `UDP <WG_PORT>` to the host. That one port is the entire external attack surface.

**Client side:** a standard WireGuard `[Interface]` + `[Peer]` config. The client's `AllowedIPs` is set to `10.10.10.0/24` — it routes only the tunnel subnet through the VPN, not all traffic, so normal internet use on the client is unaffected.

---

## Connecting

```bash
# 1. Bring the tunnel up (client side)
wg-quick up wg0

# 2. Confirm the tunnel is alive — you should get replies from the server's tunnel IP
ping 10.10.10.1

# 3. Confirm the handshake (look for a recent "latest handshake" line)
wg show
```

- `wg-quick up wg0` — reads the client `wg0.conf`, creates the interface, applies routes.
- `ping 10.10.10.1` — the server's in-tunnel address; a reply means the encrypted path is working end to end.
- `wg show` — prints peer state. A `latest handshake` within the last ~2 minutes means the tunnel is current.

---

## Reaching services through the tunnel

```bash
# Proxmox web UI (in a browser)
https://10.10.10.1:8006

# SSH into the host (non-default port)
ssh -p <SSH_PORT> <user>@10.10.10.1

# From the host, drop into a specific container
pct enter 120        # cf-ddns
pct enter 121        # uptime-kuma
pct enter 130        # media-vpn
pct enter 140        # jellyfin
```

- `https://10.10.10.1:8006` — the web UI answers on the tunnel IP; it is not exposed on the public internet.
- `ssh -p <SSH_PORT>` — `-p` picks the non-default port. SSH is configured key-only for the automation user and password + MFA for the interactive user.
- `pct enter <VMID>` — Proxmox's container-attach command; opens a root shell inside the LXC straight from the host, no per-container SSH needed.

---

## Why lateral movement is gated, not free

The tunnel advertises only its own `10.10.10.0/24`. A client that connects reaches the host — it does **not** automatically get the run of the `192.168.50.0/24` LAN. To touch a container or LAN service, you authenticate to the host over SSH first and move from there. A leaked client key gets someone onto the tunnel; it does not hand them the network.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `ping 10.10.10.1` fails | `wg show` for a handshake; confirm the edge router still forwards `UDP <WG_PORT>` to the host |
| Tunnel up but no handshake | Public IP may have changed — confirm DDNS: `dig vpn.<your-domain> +short` should equal the host's current public IP |
| Endpoint won't resolve | The DDNS updater (LXC 120) may be down — check its timer: `systemctl status cf-ddns.timer` |
| Web UI unreachable but SSH works | Service/firewall issue on the host, not the tunnel |

---

*Part of the `proxmox-homelab` reference architecture.*
