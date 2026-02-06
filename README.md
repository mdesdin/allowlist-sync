# Allowlist Sync: DNS + CrowdSec + Traefik + Cloudflare synchronizers

This toolkit contains **three Bash scripts** that share a **common library** to keep allowlists and trusted IP ranges in sync:

1) **CrowdSec allowlist sync**: DNS A/AAAA → CrowdSec allowlist  
2) **Traefik allowlist sync**: DNS A/AAAA → YAML “managed blocks” inside Traefik container files  
3) **Cloudflare IP sync**: Cloudflare published CIDRs → YAML “managed blocks” inside Traefik container files (weekly by default)

The Traefik and Cloudflare scripts only edit **explicitly marked managed blocks**, so updates are deterministic and safe.

---

## Layout

Recommended install location:

```text
/opt/allowlist-sync/
├── lib/
│   └── common.sh
├── crowdsec-allowlist-sync.sh
├── traefik-allowlist-sync.sh
└── cloudflare-ip-sync.sh
```

---

## Requirements

### Common
- bash
- python3
- dig
- awk
- curl

### CrowdSec sync
- docker
- CrowdSec container running with `cscli` available inside

### Traefik/Cloudflare sync
- docker
- Traefik container running and containing your YAML files

---

## Shared configuration

Create `/etc/default/allowlist-sync`:

```bash
# ----------------------------
# Discord (optional)
# ----------------------------
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/REDACTED"
DISCORD_USERNAME="Allowlist Sync Bot"
DISCORD_AVATAR_URL=""
DISCORD_NOTIFY_ON_ERROR=1
DISCORD_DEBUG=0

# ----------------------------
# Containers
# ----------------------------
CSCLI_CONTAINER="crowdsec"
TRAEFIK_CONTAINER="traefik"

# Optional: force docker exec user inside Traefik container (e.g. root)
# TRAEFIK_EXEC_USER="0"
TRAEFIK_EXEC_USER=""

# ----------------------------
# Traefik files live INSIDE the Traefik container
# Space-separated list of file paths inside the container
# ----------------------------
TRAEFIK_FILES="/etc/traefik.d/http.internalonly.yaml /etc/traefik.d/http.crowdsec.yaml"

# Optional: restart Traefik container after updates (default off; config dir often watched)
TRAEFIK_RESTART=0

# Optional overrides if needed:
# DIG=/usr/bin/dig
# JQ=/usr/bin/jq
# AWK=/usr/bin/awk
# PYTHON3=/usr/bin/python3
# CURL=/usr/bin/curl
````

Lock it down:

```bash
sudo chown root:root /etc/default/allowlist-sync
sudo chmod 0600 /etc/default/allowlist-sync
```

---

## Managed blocks (YAML markers)

### Why managed blocks?

Managed blocks make updates deterministic and safe:

* Scripts only touch content you explicitly mark
* No fragile “replace next line” heuristics
* Works with multiple lists per file and varying indentation

### A) Domain managed block (Traefik allowlists)

Add this in your Traefik YAML file(s) wherever you want the domain’s IPs/prefixes to appear:

```yaml
    # BEGIN managed: host.domain.tld
    - 203.0.113.25
    - 2001:0002::/48
    # END managed: host.domain.tld
```

The Traefik script replaces the lines inside the block with the DNS-derived entries.

### B) Cloudflare managed blocks (trusted IPs)

Add these blocks where your Cloudflare IP ranges belong:

```yaml
    # https://www.cloudflare.com/ips/
    # BEGIN managed cloudflare ipv4
    - 173.245.48.0/20
    # END managed cloudflare ipv4
    # BEGIN managed cloudflare ipv6
    - 2400:cb00::/32
    # END managed cloudflare ipv6
```

The Cloudflare script updates these blocks using:

* [https://www.cloudflare.com/ips-v4/](https://www.cloudflare.com/ips-v4/)
* [https://www.cloudflare.com/ips-v6/](https://www.cloudflare.com/ips-v6/)

If a file does not contain these markers, it is not modified.

---

## Script 1: CrowdSec allowlist sync

```
crowdsec-allowlist-sync.sh [--ipv6-prefix|--ipv6-host] [--ipv6-prefixlen N] <domain> <allowlist_name>
```

Examples:

Whitelist IPv4 + AAAA host IP(s):

```bash
/opt/allowlist-sync/crowdsec-allowlist-sync.sh host.domain.tld LocalIPs
```

Whitelist IPv4 + delegated IPv6 prefix (e.g. /56):

```bash
/opt/allowlist-sync/crowdsec-allowlist-sync.sh --ipv6-prefix --ipv6-prefixlen 56 host.domain.tld LocalIPs
```

Notes:

* Creates the allowlist if it does not exist.
* Adds missing entries and removes stale ones.

---

## Script 2: Traefik allowlist sync (container-aware)

```
traefik-allowlist-sync.sh [--ipv6-prefix|--ipv6-host] [--ipv6-prefixlen N] <domain>
```

This edits files **inside the Traefik container** listed in `TRAEFIK_FILES` and updates all occurrences of:

* `# BEGIN managed: <domain>`
* `# END managed: <domain>`

Example:

```bash
/opt/allowlist-sync/traefik-allowlist-sync.sh --ipv6-prefix host.domain.tld
```

Optional restart (usually not needed if Traefik watches the directory):

```bash
TRAEFIK_RESTART=1 /opt/allowlist-sync/traefik-allowlist-sync.sh --ipv6-prefix host.domain.tld
```

---

## Script 3: Cloudflare IP sync (container-aware)

```
cloudflare-ip-sync.sh
```

Updates the Cloudflare managed blocks in all target files (defaults to `TRAEFIK_FILES`).

Example:

```bash
/opt/allowlist-sync/cloudflare-ip-sync.sh
```

Optional restart:

```bash
TRAEFIK_RESTART=1 /opt/allowlist-sync/cloudflare-ip-sync.sh
```

---

## Scheduling with systemd

Recommended schedules:

* CrowdSec: every 15 minutes
* Traefik domain sync: every 15 minutes
* Cloudflare sync: weekly

### CrowdSec service/timer (15 minutes)

`/etc/systemd/system/allowlist-sync-crowdsec.service`

```ini
[Unit]
Description=CrowdSec allowlist sync
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/default/allowlist-sync
ExecStart=/usr/bin/flock -n /run/allowlist-sync-crowdsec.lock \
  /opt/allowlist-sync/crowdsec-allowlist-sync.sh --ipv6-prefix host.domain.tld LocalIPs
```

`/etc/systemd/system/allowlist-sync-crowdsec.timer`

```ini
[Unit]
Description=Run CrowdSec allowlist sync every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
```

### Traefik service/timer (15 minutes)

`/etc/systemd/system/allowlist-sync-traefik.service`

```ini
[Unit]
Description=Traefik allowlist sync
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/default/allowlist-sync
ExecStart=/usr/bin/flock -n /run/allowlist-sync-traefik.lock \
  /opt/allowlist-sync/traefik-allowlist-sync.sh --ipv6-prefix host.domain.tld
```

`/etc/systemd/system/allowlist-sync-traefik.timer`

```ini
[Unit]
Description=Run Traefik allowlist sync every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
```

### Cloudflare service/timer (weekly)

`/etc/systemd/system/allowlist-sync-cloudflare.service`

```ini
[Unit]
Description=Cloudflare IP sync
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/default/allowlist-sync
ExecStart=/usr/bin/flock -n /run/allowlist-sync-cloudflare.lock \
  /opt/allowlist-sync/cloudflare-ip-sync.sh
```

`/etc/systemd/system/allowlist-sync-cloudflare.timer`

```ini
[Unit]
Description=Run Cloudflare IP sync weekly

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now allowlist-sync-crowdsec.timer
sudo systemctl enable --now allowlist-sync-traefik.timer
sudo systemctl enable --now allowlist-sync-cloudflare.timer
```

Check:

```bash
systemctl list-timers --all | grep allowlist-sync
journalctl -u allowlist-sync-crowdsec.service -n 200 --no-pager
journalctl -u allowlist-sync-traefik.service -n 200 --no-pager
journalctl -u allowlist-sync-cloudflare.service -n 200 --no-pager
```

---

## Notes / troubleshooting

* If Traefik runs as a non-root user and cannot write the YAML files, set:

```bash
TRAEFIK_EXEC_USER="0"
```

* If you do not add managed markers, scripts `traefik-allowlist-sync.sh` and `cloudflare-ip-sync.sh` will not modify anything (by design).
* Treat Discord webhooks as secrets; keep them in `/etc/default/allowlist-sync` with 0600 permissions.
