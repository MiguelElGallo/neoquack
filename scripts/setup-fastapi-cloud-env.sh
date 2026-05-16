#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. ./scripts/lib-cloud.sh

ensure_state_dir
ensure_fastapi_login

load_env_file "$STATE_DIR/neon.env"
load_env_file "$STATE_DIR/object-store.env"
load_env_file "$STATE_DIR/fastapi-cloud.env"

if [ -z "${NEOQUACK_QUACK_TOKEN:-}" ]; then
  NEOQUACK_QUACK_TOKEN="$(random_token 64)"
fi
NEOQUACK_RUNTIME_PROVIDER="${NEOQUACK_RUNTIME_PROVIDER:-fastapi-cloud}"
if [ -z "${NEOQUACK_REGION:-}" ] || [ "$NEOQUACK_REGION" = "unknown" ]; then
  NEOQUACK_REGION="${NEON_REGION_ID:-unknown}"
fi
database_url="${DATABASE_URL:-${NEOQUACK_DATABASE_URL:-}}"

[ -n "$database_url" ] || die "Run ./scripts/setup-neon.sh first, or set DATABASE_URL."
[ -n "${NEOQUACK_OBJECT_STORE:-}" ] || die "Run ./scripts/setup-object-store-env.sh first."
[ -n "${NEOQUACK_DUCKLAKE_DATA_PATH:-}" ] || die "NEOQUACK_DUCKLAKE_DATA_PATH is required."

./scripts/setup-object-store-env.sh
load_env_file "$STATE_DIR/object-store.env"

warn "FastAPI Cloud env values are set through the FastAPI Cloud API from local ignored env files."

quoted_quack_token="$(printf '%s' "$NEOQUACK_QUACK_TOKEN" | shell_quote)"
quoted_runtime_provider="$(printf '%s' "$NEOQUACK_RUNTIME_PROVIDER" | shell_quote)"
quoted_region="$(printf '%s' "$NEOQUACK_REGION" | shell_quote)"

write_secret_env_file "$STATE_DIR/fastapi-cloud.env" <<EOF
NEOQUACK_QUACK_TOKEN=$quoted_quack_token
NEOQUACK_RUNTIME_PROVIDER=$quoted_runtime_provider
NEOQUACK_REGION=$quoted_region
EOF

if [ ! -d .fastapicloud ]; then
  info "No .fastapicloud link exists yet. Creating/linking a FastAPI Cloud app with a bootstrap deploy..."
  bootstrap_log="$(mktemp "${TMPDIR:-/tmp}/neoquack-fastapi-bootstrap.XXXXXX")"
  if ! fastapi_cli deploy --no-wait > "$bootstrap_log" 2>&1; then
    cat "$bootstrap_log" >&2
    rm -f "$bootstrap_log"
    die "FastAPI Cloud bootstrap deploy failed."
  fi
  rm -f "$bootstrap_log"
fi

if ! fastapi_cli cloud env list >/dev/null; then
  die "FastAPI Cloud app is not linked. Run 'uv run --python 3.13 fastapi deploy --no-wait' and re-run this script."
fi

set_cloud_env() {
  name="$1"
  value="$2"
  secret_flag="${3:-}"
  [ -n "$value" ] || return 0
  if [ "$secret_flag" = "--secret" ]; then
    info "Setting FastAPI Cloud secret ${name}..."
    printf '%s' "$value" | fastapi_python ./scripts/fastapi_cloud_env.py "$name" --secret
  else
    info "Setting FastAPI Cloud env ${name}..."
    printf '%s' "$value" | fastapi_python ./scripts/fastapi_cloud_env.py "$name"
  fi
}

unset_cloud_env() {
  name="$1"
  info "Deleting stale FastAPI Cloud env ${name} if present..."
  fastapi_python ./scripts/fastapi_cloud_env.py "$name" --delete
}

set_plain() {
  name="$1"
  value="$2"
  set_cloud_env "$name" "$value"
}

set_secret() {
  name="$1"
  value="$2"
  set_cloud_env "$name" "$value" --secret
}

set_secret DATABASE_URL "$database_url"
set_secret NEOQUACK_QUACK_TOKEN "$NEOQUACK_QUACK_TOKEN"
set_plain NEOQUACK_OBJECT_STORE "$NEOQUACK_OBJECT_STORE"
set_plain NEOQUACK_DUCKLAKE_DATA_PATH "$NEOQUACK_DUCKLAKE_DATA_PATH"
set_plain NEOQUACK_RUNTIME_PROVIDER "$NEOQUACK_RUNTIME_PROVIDER"
set_plain NEOQUACK_REGION "$NEOQUACK_REGION"

case "$NEOQUACK_OBJECT_STORE" in
  r2)
    set_plain NEOQUACK_R2_ACCOUNT_ID "${NEOQUACK_R2_ACCOUNT_ID:-}"
    set_secret NEOQUACK_R2_ACCESS_KEY_ID "${NEOQUACK_R2_ACCESS_KEY_ID:-}"
    set_secret NEOQUACK_R2_SECRET_ACCESS_KEY "${NEOQUACK_R2_SECRET_ACCESS_KEY:-}"
    unset_cloud_env NEOQUACK_S3_ACCESS_KEY_ID
    unset_cloud_env NEOQUACK_S3_SECRET_ACCESS_KEY
    unset_cloud_env NEOQUACK_S3_ENDPOINT
    unset_cloud_env NEOQUACK_S3_REGION
    unset_cloud_env NEOQUACK_S3_URL_STYLE
    ;;
  s3|tigris)
    set_secret NEOQUACK_S3_ACCESS_KEY_ID "${NEOQUACK_S3_ACCESS_KEY_ID:-}"
    set_secret NEOQUACK_S3_SECRET_ACCESS_KEY "${NEOQUACK_S3_SECRET_ACCESS_KEY:-}"
    set_plain NEOQUACK_S3_ENDPOINT "${NEOQUACK_S3_ENDPOINT:-}"
    set_plain NEOQUACK_S3_REGION "${NEOQUACK_S3_REGION:-auto}"
    set_plain NEOQUACK_S3_URL_STYLE "${NEOQUACK_S3_URL_STYLE:-path}"
    unset_cloud_env NEOQUACK_R2_ACCOUNT_ID
    unset_cloud_env NEOQUACK_R2_ACCESS_KEY_ID
    unset_cloud_env NEOQUACK_R2_SECRET_ACCESS_KEY
    ;;
esac

info "FastAPI Cloud environment is configured."
