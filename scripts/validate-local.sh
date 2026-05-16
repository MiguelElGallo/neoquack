#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. ./scripts/lib-cloud.sh

port="${NEOQUACK_LOCAL_PORT:-8009}"
log_file="$(mktemp "${TMPDIR:-/tmp}/neoquack-local-server.XXXXXX")"
server_pid=""

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$log_file"
}
trap cleanup EXIT INT TERM

set -a
load_env_file "$STATE_DIR/neon.env"
load_env_file "$STATE_DIR/object-store.env"
[ -f "$STATE_DIR/fastapi-cloud.env" ] && load_env_file "$STATE_DIR/fastapi-cloud.env"
set +a

command -v curl >/dev/null 2>&1 || die "curl is required."
require_cmd uv

info "Starting local NeoQuack on 127.0.0.1:${port}..."
uv run --python 3.13 uvicorn main:app --host 127.0.0.1 --port "$port" >"$log_file" 2>&1 &
server_pid=$!

start_time="$(date +%s)"
while :; do
  if curl --fail --silent --show-error "http://127.0.0.1:${port}/readyz" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    printf 'Local NeoQuack exited before readiness. Last logs:\n' >&2
    tail -80 "$log_file" >&2
    exit 1
  fi
  now="$(date +%s)"
  if [ "$((now - start_time))" -ge "${NEOQUACK_LOCAL_READY_TIMEOUT:-120}" ]; then
    printf 'Timed out waiting for local NeoQuack readiness. Last logs:\n' >&2
    tail -80 "$log_file" >&2
    exit 1
  fi
  sleep 2
done

info "Local NeoQuack is ready at http://127.0.0.1:${port}."
QUACK_HTTP_URL="http://127.0.0.1:${port}" ./scripts/validate-fastapi-cloud.sh
