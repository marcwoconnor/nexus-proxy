#!/bin/bash
# DMR Nexus Proxy Uninstaller for Pi-Star
# Removes the proxy and restores DMRGateway to its pre-Nexus config.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: Run as root (sudo)${NC}"
    exit 1
fi

echo -e "${CYAN}Removing DMR Nexus proxy...${NC}"

# Stop and disable service
systemctl stop nexus-proxy 2>/dev/null || true
systemctl disable nexus-proxy 2>/dev/null || true

# Remove files
rm -f /usr/local/bin/nexus-proxy
rm -f /etc/systemd/system/nexus-proxy.service
systemctl daemon-reload

echo -e "${GREEN}Service removed${NC}"

# Restore DMRGateway config if backup exists
DMRGW_CONFIG="/etc/dmrgateway"
if [[ -f "${DMRGW_CONFIG}.pre-nexus.bak" ]]; then
    cp "${DMRGW_CONFIG}.pre-nexus.bak" "$DMRGW_CONFIG"
    echo -e "${GREEN}DMRGateway config restored from backup${NC}"
    if systemctl is-active --quiet dmrgateway 2>/dev/null; then
        systemctl restart dmrgateway
        echo -e "${GREEN}DMRGateway restarted${NC}"
    fi
fi

# Optionally remove config
read -p "Remove config (/etc/nexus-proxy.json)? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f /etc/nexus-proxy.json
    echo -e "${GREEN}Config removed${NC}"
fi

echo -e "${GREEN}DMR Nexus proxy uninstalled. Pi-Star restored to previous config.${NC}"
