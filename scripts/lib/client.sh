#!/usr/bin/env bash
# Shared settings and HTTPS check for client-side scripts.

load_client_config() {
    local project_dir config_file proxy_host
    project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
    config_file="${PROXY_CLIENT_ENV:-$project_dir/.env.tunnel}"
    if [[ -f "$config_file" ]]; then
        set -a
        # This is a user-owned Bash configuration file.
        # shellcheck disable=SC1090
        source "$config_file"
        set +a
    elif [[ -n "${PROXY_CLIENT_ENV:-}" ]]; then
        echo "Client settings not found: $config_file" >&2
        return 2
    fi

    TUNNEL_HOST=${TUNNEL_HOST:-127.0.0.1}
    TUNNEL_PORT=${TUNNEL_PORT:-18181}
    VPS_PROXY_BIND_HOST=${VPS_PROXY_BIND_HOST:-127.0.0.1}
    VPS_PROXY_BIND_PORT=${VPS_PROXY_BIND_PORT:-18181}
    proxy_host="$TUNNEL_HOST"
    if [[ "$proxy_host" == *:* ]]; then
        proxy_host="[$proxy_host]"
    fi
    TUNNEL_PROXY_URL="http://$proxy_host:$TUNNEL_PORT"
    PROXY_URL=${PROXY_URL:-$TUNNEL_PROXY_URL}
    PROXY_CHECK_URL=${PROXY_CHECK_URL:-https://example.com/}
    TUNNEL_AUTO_START=${TUNNEL_AUTO_START:-auto}
}

validate_proxy_check() {
    if [[ "$PROXY_CHECK_URL" != https://* ]]; then
        echo "PROXY_CHECK_URL must use HTTPS to test the CONNECT tunnel." >&2
        return 2
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is required to check the proxy." >&2
        return 127
    fi
}

check_proxy() {
    local url="${1:-$PROXY_URL}"
    validate_proxy_check || return "$?"
    echo "Checking HTTPS through the proxy..." >&2
    # -q ignores curlrc; an empty --noproxy forces the check through the proxy.
    curl -q --fail --silent --show-error \
        --connect-timeout "${PROXY_CONNECT_TIMEOUT:-5}" \
        --max-time "${PROXY_CHECK_TIMEOUT:-15}" \
        --noproxy '' --proxy "$url" \
        --output /dev/null "$PROXY_CHECK_URL"
}
