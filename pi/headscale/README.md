# Headscale — Tier 2

## First run

```bash
docker compose up -d headscale cloudflared
docker exec headscale headscale users create kayaan
docker exec headscale headscale preauthkeys create --user kayaan --reusable --expiration 24h
```

On a client:

```bash
sudo tailscale up --login-server https://headscale.__DOMAIN__ --authkey <key>
```

## Cloudflare Tunnel

Zero Trust dashboard → Networks → Tunnels → Create. Add a public hostname:

| Field | Value |
|---|---|
| Subdomain | `headscale` |
| Domain | `__DOMAIN__` |
| Service | `http://headscale:8080` |

Put the tunnel token in `pi/.env` as `CLOUDFLARE_TUNNEL_TOKEN=`. That file is
gitignored — the token is a credential that grants access to your Cloudflare
account's tunnel.

## Verify before trusting it

```bash
# control plane reachable from OFF your network (phone hotspot)
curl -sS https://headscale.__DOMAIN__/health

# websockets survive the tunnel - clients keep seeing peer changes
docker exec headscale headscale nodes list
```

The websocket check is the one people skip. A tunnel that proxies HTTP but
mishandles upgrades produces clients that register successfully and then
silently stop receiving map updates — new devices never appear, routes never
propagate, and nothing logs an error.

## Migration order

1. Stand Headscale up **alongside** hosted Tailscale. Do not tear anything down.
2. Move one laptop. Live on it for several days.
3. Move phones and anything else portable.
4. Move the homelab box **last**, and only from a session where you also have
   physical or LAN access as a fallback.

Losing remote access to a headless box is the single failure in this whole
project that cannot be fixed remotely.

## When to give up and go back

Headscale is a volunteer-run reimplementation. If you find yourself debugging
map-update propagation instead of learning infrastructure, hosted Tailscale is
free for 100 devices and there is no shame in it. The resume value is in having
understood the coordination-server role, which you get either way.
