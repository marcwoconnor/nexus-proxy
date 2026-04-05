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
BINARY_URL="https://github.com/marcwoconnor/nexus-proxy/releases/download/v${NEXUS_VERSION}/nexus-proxy-linux-arm"
CONFIG_PATH="/etc/nexus-proxy.json"
SERVICE_PATH="/etc/systemd/system/nexus-proxy.service"
BINARY_PATH="/usr/local/bin/nexus-proxy"
DMRGW_CONFIG="/etc/dmrgateway"
PISTAR_DASH="/var/www/dashboard"
THEME_URL="https://raw.githubusercontent.com/marcwoconnor/Pi-Star_DV_Dash/nexus-theme/css/nexus-theme.css"
CONFIG_PAGE_URL="https://raw.githubusercontent.com/marcwoconnor/nexus-proxy/main/pistar/configure_nexus.php"

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
    x86_64)  BINARY_URL="https://github.com/marcwoconnor/nexus-proxy/releases/download/v${NEXUS_VERSION}/nexus-proxy-linux-amd64" ;;
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

# Install Pi-Star dashboard integration (dark theme + Nexus config page)
if [[ -d "$PISTAR_DASH" ]]; then
    echo ""
    echo -e "${CYAN}Installing Pi-Star dashboard integration...${NC}"

    # Download dark theme CSS
    if [[ -d "$PISTAR_DASH/css" ]]; then
        curl -sL -o "$PISTAR_DASH/css/nexus-theme.css" "$THEME_URL" 2>/dev/null
        if [[ -s "$PISTAR_DASH/css/nexus-theme.css" ]]; then
            echo -e "${GREEN}Dark theme installed: $PISTAR_DASH/css/nexus-theme.css${NC}"
        else
            echo -e "${YELLOW}Could not download dark theme (non-critical)${NC}"
        fi
    fi

    # Inject theme CSS link into main pages if not already present
    THEME_LINK='<link rel="stylesheet" type="text/css" href="/css/nexus-theme.css" />'
    for phpfile in "$PISTAR_DASH/index.php" "$PISTAR_DASH/admin/configure.php" \
                   "$PISTAR_DASH/admin/sysinfo.php" "$PISTAR_DASH/admin/power.php" \
                   "$PISTAR_DASH/admin/update.php" "$PISTAR_DASH/admin/live_modem_log.php"; do
        if [[ -f "$phpfile" ]] && ! grep -q "nexus-theme.css" "$phpfile"; then
            # Insert theme link after the last existing CSS link
            sed -i "/<\/head>/i\\    $THEME_LINK" "$phpfile"
        fi
    done

    # Inject into expert editor pages (different relative path)
    THEME_LINK_EXPERT='<link rel="stylesheet" type="text/css" href="../css/nexus-theme.css" />'
    for phpfile in "$PISTAR_DASH"/admin/expert/*.php; do
        if [[ -f "$phpfile" ]] && ! grep -q "nexus-theme.css" "$phpfile"; then
            sed -i "/<\/head>/i\\    $THEME_LINK_EXPERT" "$phpfile"
        fi
    done
    echo -e "${GREEN}Theme applied to Pi-Star dashboard pages${NC}"

    # Download Nexus config page
    if [[ -d "$PISTAR_DASH/admin" ]]; then
        curl -sL -o "$PISTAR_DASH/admin/configure_nexus.php" "$CONFIG_PAGE_URL" 2>/dev/null
        if [[ -s "$PISTAR_DASH/admin/configure_nexus.php" ]]; then
            chown www-data:www-data "$PISTAR_DASH/admin/configure_nexus.php" 2>/dev/null || true
            echo -e "${GREEN}Nexus config page installed: /admin/configure_nexus.php${NC}"
        else
            echo -e "${YELLOW}Could not download config page (non-critical)${NC}"
        fi
    fi

    # Add Nexus link to Pi-Star admin menu if not already present
    MENU_FILE="$PISTAR_DASH/admin/expert/header-menu.inc"
    if [[ -f "$MENU_FILE" ]] && ! grep -q "configure_nexus" "$MENU_FILE"; then
        # Insert a Nexus menu item before the closing </ul> or </nav>
        sed -i '/<\/ul>/i\            <li><a href="/admin/configure_nexus.php">DMR Nexus</a></li>' "$MENU_FILE" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}Added 'DMR Nexus' to admin navigation menu${NC}"
        fi
    fi

    echo -e "${GREEN}Dashboard integration complete${NC}"
else
    echo -e "${YELLOW}Pi-Star dashboard not found at $PISTAR_DASH — skipping UI install${NC}"
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
