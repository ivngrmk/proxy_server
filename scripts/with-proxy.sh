#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
    echo "Usage: with-proxy COMMAND [ARG ...]" >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/client.sh
source "$SCRIPT_DIR/lib/client.sh"
load_client_config

if ! command -v "$1" >/dev/null 2>&1; then
    echo "Command not found: $1. Activate its environment first." >&2
    exit 127
fi

case "$TUNNEL_AUTO_START" in
    auto)
        if [[ -n "${VPS_HOST:-}" && "$PROXY_URL" == "$TUNNEL_PROXY_URL" ]]; then
            TUNNEL_AUTO_START=1
        else
            TUNNEL_AUTO_START=0
        fi
        ;;
    0|1) ;;
    *) echo "TUNNEL_AUTO_START must be auto, 0 or 1." >&2; exit 2 ;;
esac

if [[ "$TUNNEL_AUTO_START" == 1 ]]; then
    if [[ "$PROXY_URL" != "$TUNNEL_PROXY_URL" ]]; then
        echo "PROXY_URL must match the local tunnel, or set TUNNEL_AUTO_START=0." >&2
        exit 2
    fi
    bash "$SCRIPT_DIR/tunnel.sh" start >/dev/null
else
    check_proxy
fi

export HTTPS_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
export https_proxy="$PROXY_URL" http_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
export NO_PROXY="${PROXY_NO_PROXY:-localhost,127.0.0.1,::1}"
export no_proxy="$NO_PROXY"

echo "HTTPS check passed. Starting: $1" >&2
exec "$@"
