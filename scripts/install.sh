#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE=proxy-server.service
APP_DIR=/opt/proxy-server
CONFIG_FILE=/etc/proxy-server.env
UNIT_FILE=/etc/systemd/system/proxy-server.service

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo: sudo bash scripts/install.sh" >&2
    exit 1
fi

if ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then
    echo "This installer requires Linux running systemd." >&2
    exit 1
fi

if [[ ! -x /usr/bin/python3 ]]; then
    echo "Install Python 3.9 or newer at /usr/bin/python3 first." >&2
    exit 1
fi

# Validate the interpreter and source before changing the installation.
/usr/bin/python3 - "$PROJECT_DIR/src/proxy_server.py" <<'PY'
import pathlib
import sys

if sys.version_info < (3, 9):
    raise SystemExit("Python 3.9 or newer is required.")
source = pathlib.Path(sys.argv[1])
compile(source.read_text(encoding="utf-8"), str(source), "exec")
PY

for source in "$PROJECT_DIR/deploy/systemd/$SERVICE" \
              "$PROJECT_DIR/deploy/proxy-server.env.example"; do
    if [[ ! -f "$source" ]]; then
        echo "Missing deployment file: $source" >&2
        exit 1
    fi
done

install -d -o root -g root -m 0755 "$APP_DIR"
install -o root -g root -m 0644 "$PROJECT_DIR/src/proxy_server.py" "$APP_DIR/proxy_server.py"
install -o root -g root -m 0644 "$PROJECT_DIR/deploy/systemd/$SERVICE" "$UNIT_FILE"

if [[ ! -e "$CONFIG_FILE" ]]; then
    install -o root -g root -m 0600 "$PROJECT_DIR/deploy/proxy-server.env.example" "$CONFIG_FILE"
    echo "Created settings: $CONFIG_FILE"
else
    echo "Preserved settings: $CONFIG_FILE"
fi

systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
systemctl --no-pager --full status "$SERVICE"
echo "Installed. Logs: sudo journalctl -u $SERVICE -f"
