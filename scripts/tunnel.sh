#!/usr/bin/env bash
set -euo pipefail

case "${1:-status}" in
    start|status|stop) ACTION=${1:-status} ;;
    *) echo "Usage: proxy-tunnel {start|status|stop}" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/client.sh
source "$SCRIPT_DIR/lib/client.sh"
load_client_config

if [[ -z "${VPS_HOST:-}" || "$VPS_HOST" == your-vps-host ]]; then
    echo "Set VPS_HOST in the client settings; see deploy/tunnel.env.example." >&2
    exit 2
fi
if ! command -v ssh >/dev/null 2>&1; then
    echo "OpenSSH is required to manage the tunnel." >&2
    exit 127
fi
if [[ "$ACTION" != stop ]]; then
    validate_proxy_check
fi

VPS_USER=${VPS_USER:-root}
VPS_PORT=${VPS_PORT:-22}
SSH_KEY=${SSH_KEY:-}
for value in "$VPS_PORT" "$TUNNEL_PORT" "$VPS_PROXY_BIND_PORT"; do
    if [[ ! "$value" =~ ^[0-9]{1,5}$ ]] || (( 10#$value < 1 || 10#$value > 65535 )); then
        echo "Invalid port: $value (expected 1..65535)" >&2
        exit 2
    fi
done

STATE_DIR=${TUNNEL_STATE_DIR:-$HOME/.cache/proxy-server/tunnels}
# Include both ends of the forwarding in the control socket identity.
read -r control_id _ < <(
    printf '%s\n' "${HOSTNAME:-localhost}" "$VPS_HOST" "$VPS_USER" "$VPS_PORT" "$SSH_KEY" \
        "$TUNNEL_HOST" "$TUNNEL_PORT" "$VPS_PROXY_BIND_HOST" "$VPS_PROXY_BIND_PORT" | cksum
)
CONTROL_PATH="$STATE_DIR/tunnel-$control_id.sock"
if (( ${#CONTROL_PATH} > 100 )); then
    echo "Control socket path is too long; set a shorter TUNNEL_STATE_DIR." >&2
    exit 2
fi

SSH_BASE=(
    ssh -p "$VPS_PORT" -l "$VPS_USER"
    -o BatchMode=yes
    -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT:-5}"
    -o ConnectionAttempts=1
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -S "$CONTROL_PATH"
)
if [[ -n "$SSH_KEY" ]]; then
    SSH_BASE+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
fi

master_running() {
    "${SSH_BASE[@]}" -O check "$VPS_HOST" >/dev/null 2>&1
}

start_tunnel() {
    if master_running; then
        check_proxy "$TUNNEL_PROXY_URL"
        printf '%s\n' "$TUNNEL_PROXY_URL"
        return
    fi

    # A tunnel created manually can already be serving this port.
    # A failed preliminary probe is expected when no local listener exists.
    if check_proxy "$TUNNEL_PROXY_URL" 2>/dev/null; then
        echo "Using an existing proxy; it is not managed by this script." >&2
        printf '%s\n' "$TUNNEL_PROXY_URL"
        return
    fi

    umask 077
    mkdir -p -- "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    if [[ -S "$CONTROL_PATH" ]]; then
        # No live master answered above; discard a socket left after a crash.
        rm -f -- "$CONTROL_PATH"
    elif [[ -e "$CONTROL_PATH" || -L "$CONTROL_PATH" ]]; then
        echo "Unexpected file at the control socket path: $CONTROL_PATH" >&2
        return 1
    fi
    local bind_host="$TUNNEL_HOST" remote_host="$VPS_PROXY_BIND_HOST"
    if [[ "$bind_host" == *:* ]]; then bind_host="[$bind_host]"; fi
    if [[ "$remote_host" == *:* ]]; then remote_host="[$remote_host]"; fi
    echo "Opening SSH tunnel to $VPS_HOST..." >&2
    "${SSH_BASE[@]}" -M -n -f -N \
        -o ControlPersist=no -o ExitOnForwardFailure=yes \
        -L "$bind_host:$TUNNEL_PORT:$remote_host:$VPS_PROXY_BIND_PORT" "$VPS_HOST"

    if ! check_proxy "$TUNNEL_PROXY_URL"; then
        echo "HTTPS check failed; closing the newly created tunnel." >&2
        "${SSH_BASE[@]}" -O exit "$VPS_HOST"
        return 1
    fi
    printf '%s\n' "$TUNNEL_PROXY_URL"
}

case "$ACTION" in
    start)
        start_tunnel
        ;;
    status)
        if master_running; then
            if check_proxy "$TUNNEL_PROXY_URL"; then
                echo "running (managed): $TUNNEL_PROXY_URL"
            else
                echo "unhealthy (managed): $TUNNEL_PROXY_URL"
                exit 1
            fi
        elif check_proxy "$TUNNEL_PROXY_URL" 2>/dev/null; then
            echo "running (external proxy): $TUNNEL_PROXY_URL"
        else
            echo "stopped or proxy unavailable: $TUNNEL_PROXY_URL"
            exit 1
        fi
        ;;
    stop)
        if master_running; then
            "${SSH_BASE[@]}" -O exit "$VPS_HOST"
            echo "Managed tunnel stopped."
        else
            echo "No managed tunnel to stop. Any external proxy is left running."
        fi
        ;;
esac
