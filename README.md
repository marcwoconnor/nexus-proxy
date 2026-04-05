# DMR Nexus Proxy

Cluster-aware proxy for Pi-Star and MMDVM hotspots connecting to a [DMR Nexus](https://github.com/marcwoconnor) network. Runs alongside your existing Pi-Star setup as a lightweight sidecar — Pi-Star stays 100% stock.

## What It Does

DMR Nexus is a distributed DMR network with multiple servers across geographic regions. This proxy sits between your hotspot software (MMDVMHost/DMRGateway) and the Nexus cluster, giving your hotspot capabilities that the standard HomeBrew protocol can't provide:

- **Automatic server discovery** — finds all available Nexus servers via DNS, no manual IP configuration
- **Instant failover** — if your server goes down or starts draining, the proxy switches to another node in under 2 seconds (vs. 60+ seconds with standard HomeBrew timeout)
- **Cluster topology awareness** — the server pushes live health data (load, latency, draining status) so the proxy always knows the best node to connect to
- **Token-based authentication** — stateless HMAC-SHA256 tokens that work on any server in the cluster, no session affinity required

```
┌──────────────┐     HomeBrew      ┌──────────────┐      NXCP       ┌─────────────────┐
│  MMDVMHost   │◄────────────────►│  nexus-proxy  │◄──────────────►│  Nexus Cluster   │
│  (Pi-Star)   │   localhost:62031 │  (this app)   │  DNS discovery  │  (7 nodes)       │
└──────────────┘                   └──────────────┘                  └─────────────────┘
```

Your radio talks to MMDVMHost. MMDVMHost talks to DMRGateway. DMRGateway talks to the proxy on localhost. The proxy talks to the Nexus cluster using the NXCP protocol. Everything between your radio and the proxy is unchanged — standard Pi-Star.

## Quick Install (Pi-Star)

```bash
curl -sL https://github.com/marcwoconnor/nexus-proxy/releases/download/v1.0.0/install.sh | sudo bash
```

The installer will:
1. Detect your Pi's architecture (armv6/v7/arm64)
2. Download the correct binary (~2.4MB)
3. Ask for your **callsign**, **DMR radio ID**, and **network passphrase**
4. Configure DMRGateway to route through the proxy
5. Start the service

That's it. Three questions and you're on the air with full cluster awareness.

### What You Need

- A Pi-Star hotspot (any Pi model) with MMDVMHost + DMRGateway running
- A DMR radio ID from [RadioID.net](https://radioid.net)
- A network passphrase from your DMR Nexus network administrator

## How It Works

### DNS Discovery

On startup, the proxy resolves DNS SRV records to find available servers:

```
_nexus._udp.nexus.techsnet.net → 7 servers with priority and weight
```

No hardcoded IP addresses. If the network adds or removes nodes, DNS is updated centrally — your proxy picks up the changes automatically on the next resolve cycle (every 30 minutes).

### NXCP Protocol

The proxy speaks NXCP (Nexus Client Protocol) to the cluster — a purpose-built protocol for cluster-native clients:

1. **AUTH** — sends your radio ID + hashed passphrase, receives a signed token valid on any server
2. **SUBS** — declares which talkgroups you want (server filters traffic, saves bandwidth)
3. **PING/PONG** — keepalive with cluster health piggybacked (peer status, token refresh)
4. **TOPO** — server pushes live cluster topology whenever it changes
5. **DATA** — DMR voice packets with token validation

### Failover

Three-tier failover, from best to worst:

| Tier | Condition | When Used |
|------|-----------|-----------|
| 1 | Alive + not draining | Normal operation — pick the healthiest server |
| 2 | Alive + draining | Server is shutting down gracefully — still works temporarily |
| 3 | Any known server | All health data may be stale — try anything |

**Proactive failover:** When a server starts draining (graceful shutdown), it tells the proxy immediately via topology push. The proxy switches before the server goes down — zero interruption.

**Missed-ping failover:** If a server stops responding to pings (crash, network partition), the proxy detects it within 15 seconds (3 missed pings x 5 second interval) and fails over.

## Manual Install

If you prefer not to use the one-liner:

### 1. Download the binary

| Architecture | Devices | Binary |
|-------------|---------|--------|
| ARMv6 | Pi Zero, Pi 1 | `nexus-proxy-linux-armv6` |
| ARMv7 | Pi 3, Pi 4 (32-bit) | `nexus-proxy-linux-armv7` |
| ARM64 | Pi 4, Pi 5 (64-bit) | `nexus-proxy-linux-arm64` |
| x86-64 | PC / testing | `nexus-proxy-linux-amd64` |

```bash
# Example for Pi 4 (32-bit):
sudo curl -L -o /usr/local/bin/nexus-proxy \
  https://github.com/marcwoconnor/nexus-proxy/releases/download/v1.0.0/nexus-proxy-linux-armv7
sudo chmod +x /usr/local/bin/nexus-proxy
```

### 2. Create the config

```bash
sudo tee /etc/nexus-proxy.json <<'EOF'
{
  "local": {
    "address": "127.0.0.1",
    "port": 62031,
    "passphrase": "passw0rd",
    "repeater_id": YOUR_RADIO_ID
  },
  "cluster": {
    "discovery": "nexus.techsnet.net",
    "passphrase": "YOUR_NETWORK_PASSPHRASE",
    "ping_interval": 5,
    "ping_timeout": 3
  },
  "subscription": {
    "slot1": null,
    "slot2": null
  },
  "log_level": "info"
}
EOF
```

Replace `YOUR_RADIO_ID` with your DMR ID and `YOUR_NETWORK_PASSPHRASE` with the passphrase from your network admin.

### 3. Install the service

```bash
sudo tee /etc/systemd/system/nexus-proxy.service <<'EOF'
[Unit]
Description=DMR Nexus Cluster Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nexus-proxy /etc/nexus-proxy.json
Restart=always
RestartSec=5
User=mmdvm
Group=mmdvm

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable nexus-proxy
sudo systemctl start nexus-proxy
```

### 4. Point DMRGateway at the proxy

In your DMRGateway config (`/etc/dmrgateway`), set DMR Network 1 to:

```ini
[DMR Network 1]
Address=127.0.0.1
Port=62031
Password=passw0rd
Name=DMR Nexus
```

Restart DMRGateway:

```bash
sudo systemctl restart dmrgateway
```

## Configuration Reference

### Discovery Mode (recommended)

```json
{
  "cluster": {
    "discovery": "nexus.techsnet.net",
    "discovery_interval": 30,
    "passphrase": "network-passphrase"
  }
}
```

The proxy resolves `_nexus._udp.nexus.techsnet.net` SRV records to find servers. Re-resolves every `discovery_interval` minutes to pick up changes. Once connected, live topology push from the server handles failover — DNS is just the bootstrap.

### Manual Mode (advanced)

```json
{
  "cluster": {
    "servers": [
      {"address": "10.0.0.1", "port": 62031},
      {"address": "10.0.0.2", "port": 62031}
    ],
    "passphrase": "network-passphrase"
  }
}
```

Specify servers directly. Discovery and manual mode are mutually exclusive.

### Talkgroup Subscriptions

```json
{
  "subscription": {
    "slot1": [8, 9, 3120],
    "slot2": [3100, 9998]
  }
}
```

Set to `null` for both slots to receive all talkgroups your repeater config allows. Specific TG lists reduce bandwidth by telling the server to only send traffic you care about.

### Log Levels

Set `"log_level"` to `"debug"`, `"info"`, `"warn"`, or `"error"`. Debug shows every packet and topology update — useful for troubleshooting, noisy in production.

## Managing the Service

```bash
# View logs
journalctl -u nexus-proxy -f

# Restart
sudo systemctl restart nexus-proxy

# Stop
sudo systemctl stop nexus-proxy

# Check status
sudo systemctl status nexus-proxy
```

## Uninstall

```bash
curl -sL https://github.com/marcwoconnor/nexus-proxy/releases/download/v1.0.0/uninstall.sh | sudo bash
```

This stops the service, removes the binary, and restores your DMRGateway config from the backup created during install.

## Building from Source

```bash
# Native build
go build -o nexus-proxy .

# Cross-compile for Pi
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -o nexus-proxy-linux-armv7 -ldflags="-s -w" .

# Run tests
go test ./... -v
```

Requires Go 1.21+. No external dependencies — standard library only.

## License

GPL v2 — same as the HBlink foundation this project builds on.
