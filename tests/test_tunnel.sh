#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
cleanup() {
    rm -f -- "$TEST_DIR/bin/ssh" "$TEST_DIR/bin/curl" \
        "$TEST_DIR/client.env" "$TEST_DIR/master" "$TEST_DIR/ssh.log" \
        "$TEST_DIR/forward" "$TEST_DIR/stdout" "$TEST_DIR/stderr" \
        "$TEST_DIR/application-started"
    if [[ -d "$TEST_DIR/tunnels" ]]; then rmdir -- "$TEST_DIR/tunnels"; fi
    rmdir -- "$TEST_DIR/bin" "$TEST_DIR"
}
trap cleanup EXIT

mkdir "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
action=start
while (( $# )); do
    case "$1" in
        -O) action="$2"; shift 2 ;;
        -L) printf '%s\n' "$2" > "$TEST_FORWARD"; shift 2 ;;
        *) shift ;;
    esac
done
case "$action" in
    check) [[ -f "$TEST_MASTER" ]] ;;
    exit)
        echo stop >> "$TEST_SSH_LOG"
        rm -f -- "$TEST_MASTER"
        ;;
    start)
        echo start >> "$TEST_SSH_LOG"
        if [[ "${TEST_SSH_FAIL:-0}" != 0 ]]; then
            echo "Simulated SSH connection failure" >&2
            exit "$TEST_SSH_FAIL"
        fi
        touch "$TEST_MASTER"
        ;;
esac
SH
cat > "$TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ "${TEST_CURL_FAIL:-0}" == 1 ]]; then exit 28; fi
if [[ "${TEST_EXTERNAL_PROXY:-0}" == 1 || -f "$TEST_MASTER" ]]; then exit 0; fi
exit 7
SH
chmod +x "$TEST_DIR/bin/ssh" "$TEST_DIR/bin/curl"
export PATH="$TEST_DIR/bin:$PATH"
export TEST_MASTER="$TEST_DIR/master" TEST_SSH_LOG="$TEST_DIR/ssh.log"
export TEST_FORWARD="$TEST_DIR/forward" TEST_MARKER="$TEST_DIR/application-started"
export PROXY_CLIENT_ENV="$TEST_DIR/client.env" TUNNEL_STATE_DIR="$TEST_DIR/tunnels"
export VPS_HOST=test.invalid VPS_USER=test VPS_PORT=22 SSH_KEY=''
export TUNNEL_HOST=127.0.0.1 TUNNEL_PORT=18181
export VPS_PROXY_BIND_HOST=127.0.0.1 VPS_PROXY_BIND_PORT=18181
export PROXY_CHECK_URL=https://example.com/ TUNNEL_AUTO_START=auto
unset PROXY_URL TEST_SSH_FAIL TEST_CURL_FAIL TEST_EXTERNAL_PROXY
touch "$PROXY_CLIENT_ENV"

expect_exit() {
    local expected="$1"
    shift
    local actual=0
    "$@" > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr" || actual="$?"
    if [[ "$actual" -ne "$expected" ]]; then
        cat "$TEST_DIR/stderr" >&2
        echo "Expected exit $expected, got $actual" >&2
        exit 1
    fi
}

expect_exit 1 bash "$PROJECT_DIR/scripts/tunnel.sh" status
expect_exit 0 bash "$PROJECT_DIR/scripts/tunnel.sh" start
[[ "$(cat "$TEST_DIR/stdout")" == http://127.0.0.1:18181 ]]
[[ "$(cat "$TEST_FORWARD")" == 127.0.0.1:18181:127.0.0.1:18181 ]]
expect_exit 0 bash "$PROJECT_DIR/scripts/tunnel.sh" start
[[ "$(grep -c '^start$' "$TEST_SSH_LOG")" -eq 1 ]]
expect_exit 0 bash "$PROJECT_DIR/scripts/tunnel.sh" status
grep -q 'running (managed)' "$TEST_DIR/stdout"

# Failed health checks must not replace or close a pre-existing managed tunnel.
export TEST_CURL_FAIL=1
expect_exit 1 bash "$PROJECT_DIR/scripts/tunnel.sh" status
expect_exit 28 bash "$PROJECT_DIR/scripts/tunnel.sh" start
[[ -f "$TEST_MASTER" ]]
unset TEST_CURL_FAIL
expect_exit 0 bash "$PROJECT_DIR/scripts/tunnel.sh" stop
[[ ! -e "$TEST_MASTER" ]]
expect_exit 0 bash "$PROJECT_DIR/scripts/tunnel.sh" stop

# A newly opened connection is closed when HTTPS cannot pass through it.
export TEST_CURL_FAIL=1
expect_exit 1 bash "$PROJECT_DIR/scripts/tunnel.sh" start
[[ ! -e "$TEST_MASTER" ]]
unset TEST_CURL_FAIL

# SSH failures propagate through the application launcher without running it.
export TEST_SSH_FAIL=255
expect_exit 255 bash "$PROJECT_DIR/scripts/with-proxy.sh" bash -c 'touch "$TEST_MARKER"'
[[ ! -e "$TEST_MARKER" && ! -e "$TEST_MASTER" ]]
unset TEST_SSH_FAIL

# Existing external proxies are reused; stop must leave them alone.
export TEST_EXTERNAL_PROXY=1
starts_before="$(grep -c '^start$' "$TEST_SSH_LOG")"
expect_exit 0 bash "$PROJECT_DIR/scripts/tunnel.sh" start
[[ "$(grep -c '^start$' "$TEST_SSH_LOG")" == "$starts_before" ]]
expect_exit 0 bash "$PROJECT_DIR/scripts/tunnel.sh" status
grep -q 'running (external proxy)' "$TEST_DIR/stdout"
expect_exit 0 bash "$PROJECT_DIR/scripts/tunnel.sh" stop
expect_exit 0 bash "$PROJECT_DIR/scripts/tunnel.sh" status
unset TEST_EXTERNAL_PROXY

# Both scripts must read the same settings even when launched outside the repo.
cat > "$PROXY_CLIENT_ENV" <<'ENV'
TUNNEL_PORT=19192
VPS_PROXY_BIND_PORT=19193
ENV
(
    cd "$TEST_DIR"
    expect_exit 0 bash "$PROJECT_DIR/scripts/with-proxy.sh" bash -c '
        [[ "$HTTPS_PROXY" == http://127.0.0.1:19192 ]] || exit 91
        touch "$TEST_MARKER"
    '
)
[[ -f "$TEST_MARKER" ]]
[[ "$(cat "$TEST_FORWARD")" == 127.0.0.1:19192:127.0.0.1:19193 ]]
expect_exit 0 bash "$PROJECT_DIR/scripts/tunnel.sh" stop

printf 'TUNNEL_PORT=0\n' > "$PROXY_CLIENT_ENV"
expect_exit 2 bash "$PROJECT_DIR/scripts/tunnel.sh" start
[[ ! -e "$TEST_MASTER" ]]

echo "Passed: tunnel lifecycle, reuse, HTTPS/SSH failures, configuration and launcher."
