#!/bin/bash
# DMR Nexus Proxy Installer for Pi-Star
# Usage: curl -sL https://nexus.techsnet.net/install.sh | sudo bash
#    or: sudo bash install.sh
#
# This installs a lightweight proxy that gives your Pi-Star hotspot
# cluster-aware connectivity to the DMR Nexus network. Pi-Star stays
# 100% stock — we just add one small service alongside it.

set -euo pipefail

NEXUS_VERSION="1.0.0"
BINARY_URL="https://github.com/marcwoconnor/dmr-nexus/releases/download/proxy-v${NEXUS_VERSION}/nexus-proxy-linux-arm"
INSTALL_URL="https://nexus.techsnet.net/install.sh"
CONFIG_PATH="/etc/nexus-proxy.json"
SERVICE_PATH="/etc/systemd/system/nexus-proxy.service"
BINARY_PATH="/usr/local/bin/nexus-proxy"
DMRGW_CONFIG="/etc/dmrgateway"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║     DMR Nexus — Pi-Star Installer     ║"
echo "  ║         Cluster-Aware Hotspot         ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"

# Check we're running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root (sudo)${NC}"
    exit 1
fi

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
    armv6l)  BINARY_URL="${BINARY_URL}v6" ;;
    armv7l)  BINARY_URL="${BINARY_URL}v7" ;;
    aarch64) BINARY_URL="${BINARY_URL}64" ;;
    x86_64)  BINARY_URL="https://github.com/marcwoconnor/dmr-nexus/releases/download/proxy-v${NEXUS_VERSION}/nexus-proxy-linux-amd64" ;;
    *)
        echo -e "${RED}Unsupported architecture: $ARCH${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}Detected architecture: ${ARCH}${NC}"

# Check if Pi-Star is running
if ! systemctl is-active --quiet mmdvmhost 2>/dev/null && \
   ! systemctl is-active --quiet mmdvmhost.service 2>/dev/null; then
    echo -e "${YELLOW}Warning: MMDVMHost doesn't appear to be running.${NC}"
    echo -e "${YELLOW}This installer is designed for Pi-Star systems.${NC}"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Collect user info
echo ""
echo -e "${CYAN}=== Configuration ===${NC}"
echo ""

if [[ -f "$CONFIG_PATH" ]]; then
    echo -e "${YELLOW}Existing config found at $CONFIG_PATH${NC}"
    read -p "Overwrite configuration? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Keeping existing config."
        SKIP_CONFIG=true
    fi
fi

if [[ "${SKIP_CONFIG:-}" != "true" ]]; then
    read -p "Your callsign: " CALLSIGN
    read -p "Your DMR Radio ID: " RADIO_ID
    read -p "Network passphrase (from DMR Nexus admin): " PASSPHRASE

    # Validate radio ID is numeric
    if ! [[ "$RADIO_ID" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: Radio ID must be numeric${NC}"
        exit 1
    fi

    CALLSIGN=$(echo "$CALLSIGN" | tr '[:lower:]' '[:upper:]')

    echo ""
    echo -e "${GREEN}Callsign:  ${CALLSIGN}${NC}"
    echo -e "${GREEN}Radio ID:  ${RADIO_ID}${NC}"
    echo -e "${GREEN}Discovery: nexus.techsnet.net (automatic)${NC}"
    echo ""
    read -p "Correct? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Download binary
echo ""
echo -e "${CYAN}Downloading nexus-proxy...${NC}"
if command -v curl &>/dev/null; then
    curl -sL -o "$BINARY_PATH" "$BINARY_URL"
elif command -v wget &>/dev/null; then
    wget -q -O "$BINARY_PATH" "$BINARY_URL"
else
    echo -e "${RED}Error: curl or wget required${NC}"
    exit 1
fi
chmod +x "$BINARY_PATH"
echo -e "${GREEN}Installed: $BINARY_PATH${NC}"

# Write config
if [[ "${SKIP_CONFIG:-}" != "true" ]]; then
    cat > "$CONFIG_PATH" <<EOFCFG
{
  "local": {
    "address": "127.0.0.1",
    "port": 62031,
    "passphrase": "passw0rd",
    "repeater_id": ${RADIO_ID}
  },
  "cluster": {
    "discovery": "nexus.techsnet.net",
    "passphrase": "${PASSPHRASE}",
    "ping_interval": 5,
    "ping_timeout": 3
  },
  "subscription": {
    "slot1": null,
    "slot2": null
  },
  "log_level": "info"
}
EOFCFG
    chmod 640 "$CONFIG_PATH"
    echo -e "${GREEN}Config written: $CONFIG_PATH${NC}"
fi

# Install systemd service
cat > "$SERVICE_PATH" <<'EOFSVC'
[Unit]
Description=DMR Nexus Cluster Proxy
Documentation=https://github.com/marcwoconnor/dmr-nexus
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nexus-proxy /etc/nexus-proxy.json
Restart=always
RestartSec=5
User=mmdvm
Group=mmdvm
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nexus-proxy
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=/etc/nexus-proxy.json

[Install]
WantedBy=multi-user.target
EOFSVC

systemctl daemon-reload
echo -e "${GREEN}Service installed: nexus-proxy.service${NC}"

# Configure DMRGateway to use the local proxy
if [[ -f "$DMRGW_CONFIG" ]]; then
    echo ""
    echo -e "${CYAN}Configuring DMRGateway to use Nexus proxy...${NC}"

    # Backup current config
    cp "$DMRGW_CONFIG" "${DMRGW_CONFIG}.pre-nexus.bak"

    # Check if DMR Network 1 section exists and update it
    if grep -q "^\[DMR Network 1\]" "$DMRGW_CONFIG"; then
        # Update existing Network 1 to point at local proxy
        sed -i '/^\[DMR Network 1\]/,/^\[/{
            s/^Address=.*/Address=127.0.0.1/
            s/^Port=.*/Port=62031/
            s/^Password=.*/Password=passw0rd/
            s/^Name=.*/Name=DMR Nexus/
        }' "$DMRGW_CONFIG"
        echo -e "${GREEN}Updated DMR Network 1 → localhost:62031 (Nexus proxy)${NC}"
    else
        echo -e "${YELLOW}No [DMR Network 1] section found in $DMRGW_CONFIG${NC}"
        echo -e "${YELLOW}You may need to manually configure DMRGateway.${NC}"
    fi

    echo -e "${GREEN}Backup saved: ${DMRGW_CONFIG}.pre-nexus.bak${NC}"
fi

# Start services
echo ""
echo -e "${CYAN}Starting nexus-proxy...${NC}"
systemctl enable nexus-proxy
systemctl start nexus-proxy

# Restart DMRGateway to pick up new config
if systemctl is-active --quiet dmrgateway 2>/dev/null; then
    echo -e "${CYAN}Restarting DMRGateway...${NC}"
    systemctl restart dmrgateway
fi

# Check status
sleep 2
if systemctl is-active --quiet nexus-proxy; then
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   DMR Nexus proxy is running!         ║${NC}"
    echo -e "${GREEN}║                                       ║${NC}"
    echo -e "${GREEN}║   View logs: journalctl -u nexus-proxy -f${NC}"
    echo -e "${GREEN}║   Status:    systemctl status nexus-proxy${NC}"
    echo -e "${GREEN}║                                       ║${NC}"
    echo -e "${GREEN}║   73 de DMR Nexus!                    ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
else
    echo -e "${RED}Warning: nexus-proxy may not have started correctly.${NC}"
    echo -e "${RED}Check: journalctl -u nexus-proxy -n 20${NC}"
fi
