#!/bin/sh

if [ "${NEOQUACK_CLOUD_LIB_LOADED:-0}" = "1" ]; then
  return 0
fi
NEOQUACK_CLOUD_LIB_LOADED=1

STATE_DIR="${NEOQUACK_STATE_DIR:-.neoquack}"
PYTHON_BIN="${PYTHON_BIN:-python3.13}"

info() {
  printf '%s\n' "$*"
}

warn() {
  printf '%s\n' "$*" >&2
}

die() {
  warn "$*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
}

load_env_file() {
  file="$1"
  if [ -f "$file" ]; then
    # shellcheck disable=SC1090
    . "$file"
  fi
}

write_secret_env_file() {
  file="$1"
  tmp="${file}.tmp"
  umask 077
  cat > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

random_token() {
  bytes="${1:-64}"
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$bytes"
}

shell_quote() {
  "$PYTHON_BIN" -c '
import shlex
import sys

print(shlex.quote(sys.stdin.read()))
'
}

fastapi_cli() {
  uv run --python 3.13 fastapi "$@"
}

fastapi_python() {
  uv run --python 3.13 python "$@"
}

neonctl_cli() {
  npx neonctl "$@"
}

wrangler_cli() {
  npx wrangler "$@"
}

ensure_fastapi_login() {
  require_cmd uv
  if ! fastapi_cli cloud whoami >/dev/null 2>&1; then
    info "Logging in to FastAPI Cloud..."
    fastapi_cli login
  fi
}

ensure_neon_login() {
  require_cmd npx
  if ! neonctl_cli me >/dev/null 2>&1; then
    info "Logging in to Neon..."
    neonctl_cli auth
  fi
}

ensure_wrangler_login() {
  require_cmd npx
  if ! wrangler_cli whoami --json 2>/dev/null | "$PYTHON_BIN" -c '
import json
import sys

payload = json.load(sys.stdin)
raise SystemExit(0 if payload.get("loggedIn") else 1)
'; then
    info "Logging in to Cloudflare with Wrangler..."
    wrangler_cli login
  fi
}

json_get_single_org_id() {
  "$PYTHON_BIN" -c '
import json
import sys

orgs = json.load(sys.stdin)
if len(orgs) == 1:
    print(orgs[0]["id"])
'
}

json_get_first_project_id_by_name() {
  name="$1"
  "$PYTHON_BIN" -c '
import json
import sys

name = sys.argv[1]
for project in json.load(sys.stdin):
    if project.get("name") == name:
        print(project["id"])
        break
' "$name"
}

json_get_project_id_from_create() {
  "$PYTHON_BIN" -c '
import json
import sys

print(json.load(sys.stdin)["project"]["id"])
'
}

json_has_name() {
  name="$1"
  "$PYTHON_BIN" -c '
import json
import sys

name = sys.argv[1]
items = json.load(sys.stdin)
raise SystemExit(0 if any(item.get("name") == name for item in items) else 1)
' "$name"
}

json_database_owner_matches() {
  database_name="$1"
  owner_name="$2"
  "$PYTHON_BIN" -c '
import json
import sys

database_name = sys.argv[1]
owner_name = sys.argv[2]
for database in json.load(sys.stdin):
    if database.get("name") != database_name:
        continue
    owner = database.get("owner_name") or database.get("owner")
    if isinstance(owner, dict):
        owner = owner.get("name")
    raise SystemExit(0 if owner == owner_name else 1)
raise SystemExit(1)
' "$database_name" "$owner_name"
}

json_get_single_cloudflare_account_id() {
  "$PYTHON_BIN" -c '
import json
import sys

payload = json.load(sys.stdin)
ids = []
for account in payload.get("accounts", []):
    if isinstance(account, dict) and account.get("id"):
        ids.append(account["id"])
if len(ids) == 1:
    print(ids[0])
'
}

r2_bucket_from_data_path() {
  "$PYTHON_BIN" -c '
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1])
print(parsed.netloc if parsed.scheme == "r2" else "")
' "$1"
}

verify_r2_bucket() {
  account_id="$1"
  bucket="$2"
  [ -n "$account_id" ] || die "Cloudflare account id is required for R2 verification."
  [ -n "$bucket" ] || die "R2 bucket name is required for R2 verification."
  ensure_wrangler_login
  info "Verifying Cloudflare R2 bucket ${bucket} in account ${account_id}..."
  if ! CLOUDFLARE_ACCOUNT_ID="$account_id" wrangler_cli r2 bucket list 2>/dev/null \
    | awk -F: '/^name:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }' \
    | grep -Fx "$bucket" >/dev/null; then
    die "R2 bucket ${bucket} was not found in Cloudflare account ${account_id}."
  fi
}

get_neon_project_id_from_file() {
  if [ -f .neon ]; then
    "$PYTHON_BIN" -c '
import json
with open(".neon", "r", encoding="utf-8") as handle:
    print(json.load(handle).get("projectId", ""))
'
  fi
}
