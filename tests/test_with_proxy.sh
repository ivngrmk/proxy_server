#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
cleanup() {
    rm -f -- "$TEST_DIR/bin/curl" "$TEST_DIR/stdout" "$TEST_DIR/stderr" \
        "$TEST_DIR/application-started" "$TEST_DIR/client.env"
    rmdir -- "$TEST_DIR/bin" "$TEST_DIR"
}
trap cleanup EXIT

# Simulate curl failures without making internet requests.
mkdir "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
exit "${TEST_CURL_EXIT:-0}"
SH
chmod +x "$TEST_DIR/bin/curl"
export PATH="$TEST_DIR/bin:$PATH"
export PROXY_URL=http://127.0.0.1:19191
export PROXY_CHECK_URL=https://example.com/
export PROXY_CLIENT_ENV="$TEST_DIR/client.env"
touch "$PROXY_CLIENT_ENV"
export TUNNEL_AUTO_START=0
export NO_PROXY='*' no_proxy='*'
unset PROXY_NO_PROXY

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

# Check environment inheritance, argument boundaries, stdout and exit status.
expect_exit 7 bash "$PROJECT_DIR/scripts/with-proxy.sh" bash -c '
    for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
        [[ "${!name}" == "http://127.0.0.1:19191" ]] || exit 91
    done
    [[ "$NO_PROXY" == "localhost,127.0.0.1,::1" ]] || exit 92
    [[ "$no_proxy" == "$NO_PROXY" ]] || exit 93
    [[ "$#" -eq 2 && "$1" == "argument with spaces" && "$2" == "literal *" ]] || exit 94
    echo application-output
    exit 7
' -- 'argument with spaces' 'literal *'
[[ "$(cat "$TEST_DIR/stdout")" == application-output ]]

# A failed HTTPS check must prevent the application from starting.
export TEST_MARKER="$TEST_DIR/application-started"
export TEST_CURL_EXIT=28
expect_exit 28 bash "$PROJECT_DIR/scripts/with-proxy.sh" bash -c 'touch "$TEST_MARKER"'
[[ ! -e "$TEST_MARKER" ]]
unset TEST_CURL_EXIT

expect_exit 2 bash "$PROJECT_DIR/scripts/with-proxy.sh"
expect_exit 127 bash "$PROJECT_DIR/scripts/with-proxy.sh" missing-proxy-test-command

export PROXY_CHECK_URL=http://example.com/
expect_exit 2 bash "$PROJECT_DIR/scripts/with-proxy.sh" bash -c 'touch "$TEST_MARKER"'
[[ ! -e "$TEST_MARKER" ]]

echo "Passed: environment, arguments, exit status, HTTPS failure and invalid inputs."
