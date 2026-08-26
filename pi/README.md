# Phase 4b (optional) — Raspberry Pi as the out-of-band box

**Entirely optional. Skip it and nothing else breaks.**

A Pi 3 (1GB, quad A53, microSD, 100Mbit) is too small to be a Kubernetes node.
It is exactly the right size for the things that should *not* live on the
cluster — the services whose whole job is to still work when the cluster
doesn't.

Three real gaps in the main design that this closes:

| Gap | Today | With the Pi |
|---|---|---|
| DNS dies with the cluster | `k8s-gateway` runs *in* the cluster, so `*.DOMAIN` stops resolving during any reboot | CoreDNS on the Pi keeps answering |
| "Backups" are on the same disk | Velero writes to Ceph RGW — the same two partitions | restic to a USB drive on the Pi is genuinely off-box |
| Nothing watches the watcher | Grafana cannot alert that Grafana is down | Uptime Kuma pings from outside |

And one architectural upgrade: **Headscale belongs here, not on the cluster.**
A coordination server that runs inside the thing it provides access to is a
circular dependency — if the cluster dies, so does the way in.

## Do it in two tiers

**Tier 1 is an hour and low risk. Tier 2 is neither.** Do Tier 1, run it for a
week, and only then decide about Headscale.

---

## Tier 1 — DNS, watchdog, backups

### Base install

Raspberry Pi OS Lite **64-bit**. In Imager, preset the hostname (`pi-oob`), SSH
key, and WiFi/ethernet before writing the card.

```bash
sudo apt update && sudo apt full-upgrade -y
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER" && newgrp docker
```

Give the Pi a **DHCP reservation**. Everything below depends on its address
never moving.

**Use a USB SSD, not the microSD, for anything that writes.** microSD cards die
under sustained write load — measured in months for a busy container host. A
$15 USB stick is only marginally better; a small USB SSD is the real fix.

### Bring it up

```bash
cd pi && docker compose up -d
```

That starts CoreDNS (53), Uptime Kuma (3001), and — if you uncomment it —
Headscale.

### Point your LAN at it

Router → DHCP → DNS server → the Pi's IP. Now `*.__DOMAIN__` resolves for every
device at home, cluster up or down.

This also **removes the LoadBalancer dependency** in Phase 4: the Pi has a
stable LAN address, so no Cilium L2 announcement is needed for DNS to work. On a
WiFi-only box that is the last remaining caveat gone.

### Watchdog

Open `http://<pi>:3001`, then add monitors for the node (ping), the API server
(TCP 6443), Grafana, and ArgoCD. Set up a notification channel — ntfy, Discord,
or Telegram all work and are free. Point it at your phone.

The one that matters is the node ping. Everything else is downstream of it.

### Off-box backups

```bash
sudo apt install -y restic
sudo cp backup/restic-backup.sh /usr/local/bin/
sudo cp backup/restic-backup.{service,timer} /etc/systemd/system/
sudo systemctl enable --now restic-backup.timer
```

Pulls the Ceph RGW bucket and etcd snapshots to a USB drive on the Pi. Restic
deduplicates and encrypts, so the repo password is the thing you must not lose —
store it in a password manager, not on either machine.

**Also back up the sealed-secrets key here.** Without it a rebuild cannot
decrypt anything committed to Git, which makes `make rebuild` a lie.

---

## Tier 2 — Headscale (harder; read this before starting)

Headscale replaces Tailscale's hosted coordination server with your own.

**The catch nobody mentions up front:** a coordination server must be reachable
from wherever your clients are — including cellular. That means it needs a
public address, which is exactly what the rest of this design avoids.

The answer is **Cloudflare Tunnel**. `cloudflared` on the Pi dials out to
Cloudflare and they route `headscale.__DOMAIN__` to it. No inbound port, no
change to your router, and the zero-open-ports property survives.

Two things to know going in:

- Headscale's control plane is HTTPS and goes through the tunnel fine. **DERP
  relays** (NAT-traversal fallback) do not — leave Headscale configured to use
  Tailscale's public DERP map. You are self-hosting coordination, not relays.
- Verify WebSocket support end-to-end early. Map updates depend on a long-lived
  connection, and a tunnel misconfiguration shows up as clients that connect
  once and then silently stop seeing peer changes.

### Migration order matters

Do **not** tear down hosted Tailscale first. Stand Headscale up alongside it,
move one non-critical device, confirm it holds for a few days, then move the
homelab box last. Losing remote access to a headless machine is the one failure
that means physically walking to it.

See `headscale/config.yaml` for the settings that actually matter and
`docker-compose.yml` for the stack.
