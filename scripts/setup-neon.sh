#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. ./scripts/lib-cloud.sh

NEON_PROJECT_NAME="${NEON_PROJECT_NAME:-neoquack}"
NEON_DATABASE_NAME="${NEON_DATABASE_NAME:-ducklake_metadata}"
NEON_ROLE_NAME="${NEON_ROLE_NAME:-ducklake_app}"
NEON_REGION_ID="${NEON_REGION_ID:-aws-eu-central-1}"
NEON_CU="${NEON_CU:-0.25-2}"

require_cmd "$PYTHON_BIN"
ensure_state_dir
ensure_neon_login

project_id="${NEON_PROJECT_ID:-}"
if [ -z "$project_id" ]; then
  project_id="$(get_neon_project_id_from_file || true)"
fi

if [ -z "$project_id" ]; then
  org_id="${NEON_ORG_ID:-}"
  if [ -z "$org_id" ]; then
    org_id="$(neonctl_cli orgs list --output json | json_get_single_org_id)"
  fi
  [ -n "$org_id" ] || die "Set NEON_ORG_ID when your Neon account has more than one organization."

  info "Looking for Neon project ${NEON_PROJECT_NAME}..."
  project_id="$(neonctl_cli projects list --org-id "$org_id" --output json | json_get_first_project_id_by_name "$NEON_PROJECT_NAME")"
  if [ -z "$project_id" ]; then
    info "Creating Neon project ${NEON_PROJECT_NAME}..."
    project_id="$(
      neonctl_cli projects create \
        --org-id "$org_id" \
        --name "$NEON_PROJECT_NAME" \
        --database "$NEON_DATABASE_NAME" \
        --role "$NEON_ROLE_NAME" \
        --region-id "$NEON_REGION_ID" \
        --cu "$NEON_CU" \
        --set-context \
        --output json | json_get_project_id_from_create
    )"
  else
    info "Reusing Neon project ${project_id}."
  fi
fi

[ -n "$project_id" ] || die "Could not resolve a Neon project id."

roles_json="$(neonctl_cli roles list --project-id "$project_id" --output json)"
if ! printf '%s' "$roles_json" | json_has_name "$NEON_ROLE_NAME"; then
  info "Creating Neon role ${NEON_ROLE_NAME}..."
  neonctl_cli roles create --project-id "$project_id" --name "$NEON_ROLE_NAME" --output json >/dev/null
else
  info "Neon role ${NEON_ROLE_NAME} already exists."
fi

databases_json="$(neonctl_cli databases list --project-id "$project_id" --output json)"
if ! printf '%s' "$databases_json" | json_has_name "$NEON_DATABASE_NAME"; then
  info "Creating Neon database ${NEON_DATABASE_NAME}..."
  neonctl_cli databases create \
    --project-id "$project_id" \
    --name "$NEON_DATABASE_NAME" \
    --owner-name "$NEON_ROLE_NAME" \
    --output json >/dev/null
  databases_json="$(neonctl_cli databases list --project-id "$project_id" --output json)"
else
  info "Neon database ${NEON_DATABASE_NAME} already exists."
fi

if ! printf '%s' "$databases_json" | json_database_owner_matches "$NEON_DATABASE_NAME" "$NEON_ROLE_NAME"; then
  die "Neon database ${NEON_DATABASE_NAME} is not owned by role ${NEON_ROLE_NAME}. Change the owner in Neon or use another NEON_DATABASE_NAME."
fi

database_url="$(
  neonctl_cli connection-string \
    --project-id "$project_id" \
    --database-name "$NEON_DATABASE_NAME" \
    --role-name "$NEON_ROLE_NAME" \
    --ssl require
)"

write_secret_env_file .neon <<EOF
{
  "projectId": "$project_id"
}
EOF

quoted_project_id="$(printf '%s' "$project_id" | shell_quote)"
quoted_project_name="$(printf '%s' "$NEON_PROJECT_NAME" | shell_quote)"
quoted_database_name="$(printf '%s' "$NEON_DATABASE_NAME" | shell_quote)"
quoted_role_name="$(printf '%s' "$NEON_ROLE_NAME" | shell_quote)"
quoted_region_id="$(printf '%s' "$NEON_REGION_ID" | shell_quote)"
quoted_database_url="$(printf '%s' "$database_url" | shell_quote)"

write_secret_env_file "$STATE_DIR/neon.env" <<EOF
NEON_PROJECT_ID=$quoted_project_id
NEON_PROJECT_NAME=$quoted_project_name
NEON_DATABASE_NAME=$quoted_database_name
NEON_ROLE_NAME=$quoted_role_name
NEON_REGION_ID=$quoted_region_id
DATABASE_URL=$quoted_database_url
EOF

if [ "${NEOQUACK_SKIP_NEON_SMOKE:-0}" != "1" ]; then
  info "Checking Neon connection..."
  DATABASE_URL="$database_url" uv run --python 3.13 python - <<'PY'
import os
import psycopg

with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
    with conn.cursor() as cur:
        cur.execute("select current_database(), current_user")
        database, user = cur.fetchone()

print(f"Neon connection ok: database={database} user={user}")
PY
fi

info "Neon ready: project=${project_id} database=${NEON_DATABASE_NAME} role=${NEON_ROLE_NAME}"
