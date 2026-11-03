#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
export PROXY_CLIENT_PREFIX="$TEST_DIR/prefix with spaces"
export PROXY_CLIENT_CONFIG_DIR="$TEST_DIR/config with spaces"
cleanup() {
    rm -f -- "$TEST_DIR/mock/curl" "$TEST_DIR/mock/ssh" "$TEST_DIR/source.env" \
        "$TEST_DIR/stdout" "$TEST_DIR/stderr" \
        "$PROXY_CLIENT_PREFIX/bin/with-proxy" "$PROXY_CLIENT_PREFIX/bin/proxy-tunnel" \
        "$PROXY_CLIENT_PREFIX/lib/proxy-server/with-proxy.sh" \
        "$PROXY_CLIENT_PREFIX/lib/proxy-server/tunnel.sh" \
        "$PROXY_CLIENT_PREFIX/lib/proxy-server/lib/client.sh" \
        "$PROXY_CLIENT_CONFIG_DIR/tunnel.env"
    rmdir -- "$PROXY_CLIENT_PREFIX/lib/proxy-server/lib" \
        "$PROXY_CLIENT_PREFIX/lib/proxy-server" "$PROXY_CLIENT_PREFIX/lib" \
        "$PROXY_CLIENT_PREFIX/bin" "$PROXY_CLIENT_PREFIX" \
        "$PROXY_CLIENT_CONFIG_DIR" "$TEST_DIR/mock" "$TEST_DIR"
}
trap cleanup EXIT

mkdir "$TEST_DIR/mock"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_DIR/mock/curl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$TEST_DIR/mock/ssh"
chmod +x "$TEST_DIR/mock/curl" "$TEST_DIR/mock/ssh"
export PATH="$PROXY_CLIENT_PREFIX/bin:$TEST_DIR/mock:$PATH"
export PROXY_CLIENT_ENV="$TEST_DIR/source.env"
cat > "$PROXY_CLIENT_ENV" <<'ENV'
VPS_HOST=test.invalid
PROXY_URL=http://127.0.0.1:19191
TUNNEL_PORT=19191
TUNNEL_AUTO_START=0
ENV
unset PROXY_URL VPS_HOST TUNNEL_AUTO_START

bash "$PROJECT_DIR/scripts/install-client.sh" > "$TEST_DIR/stdout"
cmp "$PROXY_CLIENT_ENV" "$PROXY_CLIENT_CONFIG_DIR/tunnel.env"
[[ -x "$PROXY_CLIENT_PREFIX/bin/with-proxy" && -x "$PROXY_CLIENT_PREFIX/bin/proxy-tunnel" ]]
unset PROXY_CLIENT_ENV

# Run the installed commands from outside the repository, including paths with spaces.
(
    cd "$TEST_DIR"
    actual=0
    with-proxy bash -c '
        [[ "$HTTPS_PROXY" == http://127.0.0.1:19191 ]] || exit 91
        [[ "$#" -eq 2 && "$1" == "argument with spaces" && "$2" == "literal *" ]] || exit 92
        echo installed-command-output
        exit 7
    ' -- 'argument with spaces' 'literal *' > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr" || actual="$?"
    [[ "$actual" -eq 7 ]]
    [[ "$(cat "$TEST_DIR/stdout")" == installed-command-output ]]
    proxy-tunnel status > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr"
    grep -q 'running (external proxy)' "$TEST_DIR/stdout"
)

# Reinstallation preserves edited settings and launches against that same config.
printf '%s\n' 'PROXY_URL=http://127.0.0.1:19999' 'TUNNEL_AUTO_START=0' \
    > "$PROXY_CLIENT_CONFIG_DIR/tunnel.env"
bash "$PROJECT_DIR/scripts/install-client.sh" > "$TEST_DIR/stdout"
with-proxy bash -c '[[ "$HTTPS_PROXY" == http://127.0.0.1:19999 ]]' \
    > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr"

# An explicit runtime configuration still overrides the installed default.
PROXY_CLIENT_ENV="$TEST_DIR/source.env" with-proxy bash -c \
    '[[ "$HTTPS_PROXY" == http://127.0.0.1:19191 ]]' \
    > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr"

echo "Passed: installed commands, paths with spaces, arguments, updates and config overrides."
