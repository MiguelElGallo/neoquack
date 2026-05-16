#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. ./scripts/lib-cloud.sh

ensure_state_dir

object_env="$STATE_DIR/object-store.env"

if [ ! -f "$object_env" ]; then
  write_secret_env_file "$object_env" <<'EOF'
# NeoQuack local R2 object-store config.
# This file is ignored by git.
# Create the S3 API token from:
# https://dash.cloudflare.com/your-account-id/r2/api-tokens
# Or go to R2 Object Storage > Overview > Account Details > API Tokens > Manage.
# The bucket Settings > General page shows:
# https://your-account-id.r2.cloudflarestorage.com/neoquack-ducklake

NEOQUACK_OBJECT_STORE='r2'
NEOQUACK_R2_BUCKET='neoquack-ducklake'
NEOQUACK_DUCKLAKE_DATA_PATH='r2://neoquack-ducklake/data/'
NEOQUACK_R2_ACCOUNT_ID='replace-me-cloudflare-account-id'
NEOQUACK_R2_ACCESS_KEY_ID='replace-me-r2-access-key-id'
NEOQUACK_R2_SECRET_ACCESS_KEY='replace-me-r2-secret-access-key'
EOF
  die "Created ${object_env}. Fill in R2 values, then re-run the command."
fi

load_env_file "$object_env"

case "${NEOQUACK_OBJECT_STORE:-}" in
  r2)
    required_names="NEOQUACK_DUCKLAKE_DATA_PATH NEOQUACK_R2_ACCOUNT_ID NEOQUACK_R2_ACCESS_KEY_ID NEOQUACK_R2_SECRET_ACCESS_KEY"
    ;;
  s3|tigris)
    required_names="NEOQUACK_DUCKLAKE_DATA_PATH NEOQUACK_S3_ACCESS_KEY_ID NEOQUACK_S3_SECRET_ACCESS_KEY NEOQUACK_S3_ENDPOINT"
    ;;
  *)
    die "NEOQUACK_OBJECT_STORE must be r2, s3, or tigris in ${object_env}."
    ;;
esac

for name in $required_names; do
  eval "value=\${$name:-}"
  [ -n "$value" ] || die "Missing ${name} in ${object_env}."
  case "$value" in
    *'<'*'>'*|replace-me-*) die "Replace placeholder ${name} in ${object_env}." ;;
  esac
done

case "${NEOQUACK_DUCKLAKE_DATA_PATH:-}" in
  r2://*|s3://*) ;;
  *) die "NEOQUACK_DUCKLAKE_DATA_PATH must start with r2:// or s3://." ;;
esac

if [ "${NEOQUACK_OBJECT_STORE:-}" = "r2" ] && [ "${NEOQUACK_SKIP_R2_BUCKET_CHECK:-0}" != "1" ]; then
  bucket="${NEOQUACK_R2_BUCKET:-$(r2_bucket_from_data_path "$NEOQUACK_DUCKLAKE_DATA_PATH")}"
  verify_r2_bucket "$NEOQUACK_R2_ACCOUNT_ID" "$bucket"
fi

info "Object-store env is complete."
