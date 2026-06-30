# Architecture — `venom` Homelab

## Overview

`venom` is a single bare-metal Proxmox VE node that consolidates several roles that would normally live on separate machines: a WireGuard VPN gateway, a media stack, a monitoring system, and a platform for disposable security-lab VMs. The guiding principle is **role separation with minimal exposure** — every service is isolated in its own container, and nothing is reachable from the internet except a single authenticated VPN port.

![Proxmox node — container and storage overview](images/proxmox-node-overview.png)

---

## Hardware

| Component | Detail |
|-----------|--------|
| CPU | Intel Core i9-9900K (8C / 16T) |
| RAM | 32 GB DDR4 3600 MHz |
| GPU | NVIDIA RTX 2070 Super |
| Motherboard | Z390 chipset |
| Hypervisor | Proxmox VE 8.x (bare metal) |

A repurposed desktop. The GPU is present for potential transcode/compute offload; the platform's value is in how it's organized, not the silicon.

---

## Network design

### Topology

```
Internet  (dynamic public IP → vpn.<your-domain> via DDNS)
      │   edge router: single port-forward, UDP <WG_PORT> → 192.168.50.50
      ▼
 venom  192.168.50.50
 ├── wg0  10.10.10.1/24        WireGuard gateway (on host)
 ├── LXC 120  192.168.50.120   cf-ddns
 ├── LXC 121  192.168.50.121   uptime-kuma
 ├── LXC 130  192.168.50.130   media-vpn
 └── LXC 140  192.168.50.140   jellyfin
```

### Tunnel-first remote access — the core decision

There is **no internet-facing management surface**. The only inbound rule at the edge router is a single UDP port forwarded to WireGuard. The Proxmox web UI, SSH, and every service are reachable **only after** the tunnel is up.

This is deliberate, for three reasons:

1. **WireGuard is silent to scanners.** It does not respond to packets that aren't cryptographically valid. Unlike an open TCP service (SSH, HTTPS) that announces itself with a banner or handshake, the WireGuard port looks closed to an internet scanner. The endpoint effectively doesn't advertise its own existence.
2. **One ingress, fully authenticated.** A single UDP port is the entire external attack surface. Everything past it requires a valid key — there is no "try the login page" path from outside.
3. **Least-privilege tunnel scope.** The tunnel advertises only its own `10.10.10.0/24`, not the full `192.168.50.0/24` LAN. A compromised peer key reaches the tunnel — not, automatically, the whole network. Lateral movement still requires authenticating to the host over SSH.

Remote workflow: bring up WireGuard → reach the host at `10.10.10.1` → SSH in → `pct enter` into a specific container. Step-by-step in [`remote-access.md`](remote-access.md).

### Why WireGuard runs on the host, not in a container

The tunnel terminates on the Proxmox host itself rather than inside an LXC. This lets a connected client reach every container and LAN service directly through the host's routing table, with no per-container VPN configuration and no extra hops.

The tradeoff: the tunnel lives in the host's network namespace, so a host compromise exposes the tunnel. That's an accepted cost — the host is the most-hardened layer (key-only SSH for the automation user, MFA for the interactive user, non-default port), and terminating the VPN anywhere else would mean either NAT gymnastics or a VPN container that becomes a single chokepoint for all remote access.

---

## Compute — containers over VMs

Persistent services run as **LXC containers**, not full virtual machines. Containers share the host kernel, so they carry near-zero virtualization overhead and start in under a second — appropriate for long-lived, trusted services where hardware-level isolation isn't required.

Full VMs are reserved for the opposite case: **untrusted, disposable** workloads — Kali attack boxes, Windows Active Directory lab targets — which run on the scratch storage tier and get destroyed and rebuilt freely. Matching the isolation level to the trust level keeps the trusted services lean and the untrusted ones properly sandboxed.

**Addressing convention:** `120–129` for infrastructure, `130–149` for application services, `150+` reserved. The last octet of each static IP matches the VMID, so the address and the ID are the same number. All containers run **unprivileged** — the container's root maps to a non-root UID on the host, so a container escape doesn't land as host root.

---

## Storage — three-tier trust model

Three physical NVMe drives, each with one job, and a rule that data never crosses between tiers.

![df -h — physical mounts](images/df-h-storage.png)

| Mount | Drive | Size | Use | Role |
|-------|-------|------|-----|------|
| `/` (pve-root) | nvme0n1 (LVM) | 94 GB | ~41% | OS, container disks, disposable scratch |
| `/mnt/datastore` | nvme2n1 | 1.8 TB | ~53% | Active services, media library |
| `/mnt/vault` | nvme1n1 | 1.8 TB | ~1% | Backups, critical configs |

**Trust tiers:**

- **Scratch (on root)** — Proxmox exposes two directory storages, `local` and `tactical`, plus the `local-lvm` thin pool, all backed by the root volume. This is the disposable tier: lab VM disks, build cache, transcode scratch, anything that can be wiped without a second thought. It is *not* for anything that needs to survive.
- **datastore** — active service data and the media library. Not for backups, not for anything disposable.
- **vault** — the only place backups and secrets live, on its own physical drive.

**Why the separation is physical, not just logical:** `vault` and `datastore` are different drives. If `datastore` fails, the backups on `vault` are untouched — the backup and the thing it protects can't die together. That single property is the whole reason the tiers map to separate disks instead of separate folders.

> Note: the `df -h` output shows several `overlay` mounts on the root filesystem — those are the Docker containers currently running on the host (see Technical Debt below).

---

## Known technical debt (tracked, not hidden)

- **Sonarr / Radarr / Jackett run in Docker directly on the Proxmox host** — visible as the `overlay2` mounts under `/var/lib/docker` in `df -h`. This couples application services to the hypervisor layer; they belong in a dedicated LXC (planned VMID 160). Migration is deferred while the media stack is idle, but it is the right next cleanup.
- **LXC 130 emits an `mp0` schema warning** on `pct list` — a mount point written under an older Proxmox schema version. Non-breaking; the container runs normally. Cleanup queued.

Documenting debt is intentional. Knowing exactly where the rough edges are — and why they're tolerated for now — is part of operating the system, not an admission against it.

---

*Part of the `proxmox-homelab` reference architecture.*
