#!/usr/bin/env bash
set -euo pipefail

SERVICE=proxy-server.service
UNIT_FILE=/etc/systemd/system/proxy-server.service

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo: sudo bash scripts/uninstall.sh" >&2
    exit 1
fi

if ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then
    echo "This uninstaller requires Linux running systemd." >&2
    exit 1
fi

if [[ -e "$UNIT_FILE" ]]; then
    systemctl disable --now "$SERVICE"
    rm -f -- "$UNIT_FILE"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
fi

rm -f -- /opt/proxy-server/proxy_server.py
if [[ -d /opt/proxy-server ]]; then
    rmdir -- /opt/proxy-server 2>/dev/null || true
fi

echo "Service removed. Settings and logs are preserved:"
echo "  /etc/proxy-server.env"
echo "  /var/lib/proxy-server/"
