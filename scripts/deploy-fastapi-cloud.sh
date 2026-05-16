#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. ./scripts/lib-cloud.sh

info "Step 1/5: Neon catalog"
./scripts/setup-neon.sh

info "Step 2/5: R2/object-store configuration"
if [ -f "$STATE_DIR/object-store.env" ]; then
  ./scripts/setup-object-store-env.sh
else
  ./scripts/setup-r2.sh
fi

info "Step 3/5: FastAPI Cloud environment"
./scripts/setup-fastapi-cloud-env.sh

info "Step 4/5: FastAPI Cloud deployment"
fastapi_cli deploy

info "Step 5/5: optional validation"
load_env_file "$STATE_DIR/fastapi-cloud.env"
load_env_file "$STATE_DIR/object-store.env"

if [ -n "${QUACK_HTTP_URL:-${FASTAPI_CLOUD_URL:-}}" ]; then
  ./scripts/validate-fastapi-cloud.sh
else
  info "Set QUACK_HTTP_URL=https://your-app.fastapicloud.dev and run ./scripts/validate-fastapi-cloud.sh for live validation."
fi

info "NeoQuack deployment flow completed."
