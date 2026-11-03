#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX=${PROXY_CLIENT_PREFIX:-$HOME/.local}
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/proxy-server"
CONFIG_DIR=${PROXY_CLIENT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/proxy-server}
CONFIG_FILE="$CONFIG_DIR/tunnel.env"
SOURCE_CONFIG=${PROXY_CLIENT_ENV:-$PROJECT_DIR/.env.tunnel}

# Resolve relative installation paths before embedding them in launchers.
mkdir -p -- "$BIN_DIR" "$LIB_DIR/lib" "$CONFIG_DIR"
BIN_DIR="$(cd -- "$BIN_DIR" && pwd)"
LIB_DIR="$(cd -- "$LIB_DIR" && pwd)"
CONFIG_DIR="$(cd -- "$CONFIG_DIR" && pwd)"
CONFIG_FILE="$CONFIG_DIR/tunnel.env"

for script in with-proxy.sh tunnel.sh lib/client.sh; do
    bash -n "$PROJECT_DIR/scripts/$script"
done

install -m 0644 "$PROJECT_DIR/scripts/with-proxy.sh" "$LIB_DIR/with-proxy.sh"
install -m 0644 "$PROJECT_DIR/scripts/tunnel.sh" "$LIB_DIR/tunnel.sh"
install -m 0644 "$PROJECT_DIR/scripts/lib/client.sh" "$LIB_DIR/lib/client.sh"

if [[ -e "$CONFIG_FILE" ]]; then
    echo "Preserved settings: $CONFIG_FILE"
elif [[ -f "$SOURCE_CONFIG" ]]; then
    install -m 0600 "$SOURCE_CONFIG" "$CONFIG_FILE"
    echo "Copied client settings to: $CONFIG_FILE"
elif [[ -n "${PROXY_CLIENT_ENV:-}" ]]; then
    echo "Client settings not found: $SOURCE_CONFIG" >&2
    exit 2
else
    install -m 0600 "$PROJECT_DIR/deploy/tunnel.env.example" "$CONFIG_FILE"
    echo "Created settings: $CONFIG_FILE (set VPS_HOST and SSH_KEY as needed)"
fi

write_launcher() {
    local name="$1" script="$2"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
        printf 'default_config=%q\n' "$CONFIG_FILE"
        printf '%s\n' 'export PROXY_CLIENT_ENV="${PROXY_CLIENT_ENV:-$default_config}"'
        printf 'exec bash %q "$@"\n' "$LIB_DIR/$script"
    } > "$BIN_DIR/$name"
    chmod 0755 "$BIN_DIR/$name"
}

write_launcher with-proxy with-proxy.sh
write_launcher proxy-tunnel tunnel.sh
echo "Installed commands: $BIN_DIR/with-proxy and $BIN_DIR/proxy-tunnel"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo "Add this line to your shell startup file, then open a new terminal:"
        printf 'export PATH=%q:"$PATH"\n' "$BIN_DIR"
        ;;
esac
