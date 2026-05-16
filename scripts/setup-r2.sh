#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. ./scripts/lib-cloud.sh

ensure_state_dir
ensure_wrangler_login

object_env="$STATE_DIR/object-store.env"
if [ -f "$object_env" ]; then
  load_env_file "$object_env"
fi

bucket="${NEOQUACK_R2_BUCKET:-neoquack-ducklake}"
case "${NEOQUACK_R2_LOCATION:-}" in
  ""|weur|eeur|apac|wnam|enam|oc) ;;
  *) die "NEOQUACK_R2_LOCATION must be one of: weur, eeur, apac, wnam, enam, oc." ;;
esac

account_id="${NEOQUACK_R2_ACCOUNT_ID:-${CLOUDFLARE_ACCOUNT_ID:-}}"
case "$account_id" in
  *'<'*'>'*) account_id="" ;;
esac
if [ -z "$account_id" ]; then
  account_id="$(wrangler_cli whoami --json | json_get_single_cloudflare_account_id)"
fi
[ -n "$account_id" ] || die "Could not infer Cloudflare account id. Set NEOQUACK_R2_ACCOUNT_ID."

info "Ensuring Cloudflare R2 bucket ${bucket} exists..."
create_log="$(mktemp "${TMPDIR:-/tmp}/neoquack-r2-create.XXXXXX")"
trap 'rm -f "$create_log"' EXIT
if [ -n "${NEOQUACK_R2_LOCATION:-}" ]; then
  create_status=0
  CLOUDFLARE_ACCOUNT_ID="$account_id" wrangler_cli r2 bucket create "$bucket" --location "$NEOQUACK_R2_LOCATION" > "$create_log" 2>&1 || create_status=$?
else
  create_status=0
  CLOUDFLARE_ACCOUNT_ID="$account_id" wrangler_cli r2 bucket create "$bucket" > "$create_log" 2>&1 || create_status=$?
fi
if [ "$create_status" -ne 0 ]; then
  if CLOUDFLARE_ACCOUNT_ID="$account_id" wrangler_cli r2 bucket list 2>/dev/null \
    | awk -F: '/^name:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }' \
    | grep -Fx "$bucket" >/dev/null; then
    info "R2 bucket ${bucket} already exists."
  else
    cat "$create_log" >&2
    die "Could not create or confirm R2 bucket ${bucket}."
  fi
fi

access_key="${NEOQUACK_R2_ACCESS_KEY_ID:-replace-me-r2-access-key-id}"
secret_key="${NEOQUACK_R2_SECRET_ACCESS_KEY:-replace-me-r2-secret-access-key}"

quoted_object_store="$(printf '%s' r2 | shell_quote)"
quoted_bucket="$(printf '%s' "$bucket" | shell_quote)"
quoted_data_path="$(printf '%s' "r2://${bucket}/data/" | shell_quote)"
quoted_account_id="$(printf '%s' "$account_id" | shell_quote)"
quoted_access_key="$(printf '%s' "$access_key" | shell_quote)"
quoted_secret_key="$(printf '%s' "$secret_key" | shell_quote)"

write_secret_env_file "$object_env" <<EOF
# NeoQuack local R2 object-store config.
# This file is ignored by git.
# Open Cloudflare dashboard > R2 Object Storage > Overview > Account Details >
# API Tokens > Manage to create the S3 API token. Account-specific links are
# intentionally written only to this ignored local file:
# https://dash.cloudflare.com/${account_id}/r2/api-tokens
# The bucket Settings > General page shows this S3 API endpoint:
# https://${account_id}.r2.cloudflarestorage.com/${bucket}

NEOQUACK_OBJECT_STORE=$quoted_object_store
NEOQUACK_R2_BUCKET=$quoted_bucket
NEOQUACK_DUCKLAKE_DATA_PATH=$quoted_data_path
NEOQUACK_R2_ACCOUNT_ID=$quoted_account_id
NEOQUACK_R2_ACCESS_KEY_ID=$quoted_access_key
NEOQUACK_R2_SECRET_ACCESS_KEY=$quoted_secret_key
EOF

./scripts/setup-object-store-env.sh
