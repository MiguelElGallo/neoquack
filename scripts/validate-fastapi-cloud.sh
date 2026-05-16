#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. ./scripts/lib-cloud.sh

load_env_file "$STATE_DIR/fastapi-cloud.env"
load_env_file "$STATE_DIR/neon.env"
load_env_file "$STATE_DIR/object-store.env"

command -v duckdb >/dev/null 2>&1 || { printf 'duckdb CLI is required.\n' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { printf 'curl is required.\n' >&2; exit 1; }

wait_for_ready() {
  url="$1"
  timeout_seconds="$2"
  start_time="$(date +%s)"
  while :; do
    body="$(curl --silent --show-error "$url/readyz" 2>&1 || true)"
    if printf '%s' "$body" | grep '"ready":true\|"ready": true' >/dev/null; then
      return 0
    fi
    now="$(date +%s)"
    if [ "$((now - start_time))" -ge "$timeout_seconds" ]; then
      printf 'Timed out waiting for /readyz. Last response:\n%s\n' "$body" >&2
      return 1
    fi
    sleep 5
  done
}

check_instance_affinity() {
  url="$1"
  samples_file="$2"
  : > "$samples_file"
  i=0
  while [ "$i" -lt 10 ]; do
    response="$(curl --silent --show-error --write-out '\n%{http_code}' "$url/healthz" 2>&1 || true)"
    status="$(printf '%s\n' "$response" | tail -n 1)"
    body="$(printf '%s\n' "$response" | sed '$d')"
    printf '%s\t%s\n' "$status" "$body" >> "$samples_file"
    i=$((i + 1))
    sleep 1
  done
  "$PYTHON_BIN" - "$samples_file" <<'PY'
import json
import sys

path = sys.argv[1]
instance_ids = set()
with open(path, "r", encoding="utf-8") as handle:
    for line_number, line in enumerate(handle, start=1):
        line = line.rstrip("\n")
        if not line:
            continue
        status, _, body = line.partition("\t")
        if status != "200":
            print(
                f"Health sample {line_number} returned HTTP {status}: "
                + body[:300],
                file=sys.stderr,
            )
            raise SystemExit(1)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError as exc:
            print(
                f"Health sample {line_number} was not JSON: {exc}: "
                + body[:300],
                file=sys.stderr,
            )
            raise SystemExit(1) from exc
        instance_id = payload.get("instance_id")
        if instance_id:
            instance_ids.add(instance_id)

if len(instance_ids) > 1:
    print(
        "FastAPI Cloud routed health checks to multiple runtime instances: "
        + ", ".join(sorted(instance_ids)),
        file=sys.stderr,
    )
    print(
        "Quack requires sticky routing or a single FastAPI Cloud runtime "
        "instance because quack_connection_id state is kept server-side.",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

sql_quote() {
  printf "%s" "$1" | sed "s/'/''/g"
}

url_password() {
  NEOQUACK_URL_TO_PARSE="$1" "$PYTHON_BIN" - <<'PY'
import os
from urllib.parse import unquote, urlparse

value = os.getenv("NEOQUACK_URL_TO_PARSE", "")
if not value:
    raise SystemExit(0)
password = urlparse(value).password
if password:
    print(unquote(password))
PY
}

write_object_store_secret_sql() {
  sql_file="$1"
  case "${NEOQUACK_OBJECT_STORE:-r2}" in
    r2)
      key_id="${NEOQUACK_R2_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
      secret="${NEOQUACK_R2_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
      [ -n "${NEOQUACK_R2_ACCOUNT_ID:-}" ] && [ -n "$key_id" ] && [ -n "$secret" ] || return 1
      cat >> "$sql_file" <<SQL
CREATE OR REPLACE SECRET neoquack_storage (
    TYPE r2,
    KEY_ID '$(sql_quote "$key_id")',
    SECRET '$(sql_quote "$secret")',
    ACCOUNT_ID '$(sql_quote "$NEOQUACK_R2_ACCOUNT_ID")'
);
SQL
      ;;
    s3|tigris)
      key_id="${NEOQUACK_S3_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
      secret="${NEOQUACK_S3_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
      [ -n "$key_id" ] && [ -n "$secret" ] || return 1
      endpoint_clause=""
      url_style_clause=""
      if [ -n "${NEOQUACK_S3_ENDPOINT:-}" ]; then
        endpoint_clause=", ENDPOINT '$(sql_quote "$NEOQUACK_S3_ENDPOINT")'"
      fi
      if [ -n "${NEOQUACK_S3_URL_STYLE:-}" ]; then
        url_style_clause=", URL_STYLE '$(sql_quote "$NEOQUACK_S3_URL_STYLE")'"
      fi
      cat >> "$sql_file" <<SQL
CREATE OR REPLACE SECRET neoquack_storage (
    TYPE s3,
    PROVIDER config,
    KEY_ID '$(sql_quote "$key_id")',
    SECRET '$(sql_quote "$secret")',
    REGION '$(sql_quote "${NEOQUACK_S3_REGION:-auto}")'${endpoint_clause}${url_style_clause}
);
SQL
      ;;
    *)
      return 1
      ;;
  esac
}

local_version="$(duckdb -csv -c 'SELECT version();' | tail -n 1)"
if [ "$local_version" != "v1.5.2" ]; then
  printf 'Local duckdb CLI must be v1.5.2 for Quack beta validation. Found %s.\n' "$local_version" >&2
  exit 1
fi

QUACK_HTTP_URL="${QUACK_HTTP_URL:-${FASTAPI_CLOUD_URL:-}}"
[ -n "$QUACK_HTTP_URL" ] || { printf 'Set QUACK_HTTP_URL or FASTAPI_CLOUD_URL.\n' >&2; exit 1; }
QUACK_HTTP_URL="${QUACK_HTTP_URL%/}"
QUACK_HOST="$("$PYTHON_BIN" -c '
from urllib.parse import urlparse
import sys

url = sys.argv[1]
parsed = urlparse(url)
if not parsed.scheme:
    parsed = urlparse("https://" + url)
host = parsed.hostname or parsed.path.split("/", 1)[0]
port = parsed.port
if port is None:
    port = 443 if parsed.scheme == "https" else 80
if ":" in host and not host.startswith("["):
    host = f"[{host}]"
print(f"{host}:{port}")
' "$QUACK_HTTP_URL")"
QUACK_URI="${QUACK_URI:-quack:${QUACK_HOST}}"
QUACK_TOKEN="${NEOQUACK_QUACK_TOKEN:-${QUACK_TOKEN:-}}"
[ -n "$QUACK_TOKEN" ] || { printf 'Set NEOQUACK_QUACK_TOKEN or QUACK_TOKEN.\n' >&2; exit 1; }

printf 'Checking FastAPI Cloud health endpoint...\n'
curl --fail --silent --show-error "$QUACK_HTTP_URL/healthz" >/dev/null
wait_for_ready "$QUACK_HTTP_URL" 300

umask 077
good_sql="$(mktemp "${TMPDIR:-/tmp}/neoquack-good.XXXXXX")"
bad_sql="$(mktemp "${TMPDIR:-/tmp}/neoquack-bad.XXXXXX")"
parallel_sql="$(mktemp "${TMPDIR:-/tmp}/neoquack-parallel.XXXXXX")"
post_redeploy_sql="$(mktemp "${TMPDIR:-/tmp}/neoquack-post.XXXXXX")"
cleanup_sql="$(mktemp "${TMPDIR:-/tmp}/neoquack-cleanup.XXXXXX")"
file_list="$(mktemp "${TMPDIR:-/tmp}/neoquack-files.XXXXXX")"
data_path_file="$(mktemp "${TMPDIR:-/tmp}/neoquack-data-path.XXXXXX")"
object_sql="$(mktemp "${TMPDIR:-/tmp}/neoquack-object.XXXXXX")"
object_check_sql="$(mktemp "${TMPDIR:-/tmp}/neoquack-object-check.XXXXXX")"
logs_file="$(mktemp "${TMPDIR:-/tmp}/neoquack-logs.XXXXXX")"
affinity_file="$(mktemp "${TMPDIR:-/tmp}/neoquack-affinity.XXXXXX")"
wrong_token_log="$(mktemp "${TMPDIR:-/tmp}/neoquack-wrong-token.XXXXXX")"
parallel_log_a="$(mktemp "${TMPDIR:-/tmp}/neoquack-parallel-a.XXXXXX")"
parallel_log_b="$(mktemp "${TMPDIR:-/tmp}/neoquack-parallel-b.XXXXXX")"
trap 'rm -f "$good_sql" "$bad_sql" "$parallel_sql" "$post_redeploy_sql" "$cleanup_sql" "$file_list" "$data_path_file" "$object_sql" "$object_check_sql" "$logs_file" "$affinity_file" "$wrong_token_log" "$parallel_log_a" "$parallel_log_b"' EXIT

check_instance_affinity "$QUACK_HTTP_URL" "$affinity_file"

marker_id="$("$PYTHON_BIN" -c 'import time; print(time.time_ns())')"
marker_suffix="$("$PYTHON_BIN" -c 'import uuid; print(uuid.uuid4().hex)')"
marker_name="cloud-validate-${marker_suffix}"
marker_table="cloud_validation_markers"
validation_table="cloud_validation_${marker_suffix}"
rollback_table="txn_rollback_${marker_suffix}"
commit_table="txn_commit_${marker_suffix}"

cat > "$good_sql" <<SQL
.bail on
FORCE INSTALL quack FROM core_nightly;
LOAD quack;
ATTACH '$QUACK_URI' AS remote (TYPE quack, TOKEN '$(sql_quote "$QUACK_TOKEN")');
FROM remote.query('FROM whoami()');
SELECT version() AS local_duckdb_version;
SELECT * FROM remote.query('SELECT version() AS remote_duckdb_version');
FROM remote.query('CREATE SCHEMA IF NOT EXISTS neoquack.validation');
FROM remote.query('CREATE TABLE IF NOT EXISTS neoquack.validation.${marker_table} (
    marker_id BIGINT,
    marker_name VARCHAR,
    created_at TIMESTAMPTZ
)');
FROM remote.query('DELETE FROM neoquack.validation.${marker_table} WHERE marker_id = $marker_id AND marker_name = ''$marker_name''');
FROM remote.query('DROP TABLE IF EXISTS neoquack.validation.${validation_table}');
FROM remote.query('DROP TABLE IF EXISTS neoquack.validation.${rollback_table}');
FROM remote.query('DROP TABLE IF EXISTS neoquack.validation.${commit_table}');
FROM remote.query('CREATE TABLE neoquack.validation.${validation_table} AS
SELECT
    $marker_id::BIGINT + i::BIGINT AS event_id,
    ''quack-cloud-validation-'' || i::VARCHAR AS event_name,
    now() AS created_at
FROM range(1, 1001) AS t(i)');
FROM remote.query('INSERT INTO neoquack.validation.${marker_table} SELECT $marker_id, ''$marker_name'', now()');
SELECT * FROM remote.query('SELECT count(*) AS marker_count FROM neoquack.validation.${marker_table} WHERE marker_id = $marker_id AND marker_name = ''$marker_name''');
SELECT * FROM remote.query('SELECT count(*) AS validation_row_count FROM neoquack.validation.${validation_table}');
SELECT * FROM remote.query('BEGIN TRANSACTION');
SELECT * FROM remote.query('CREATE TABLE neoquack.validation.${rollback_table} AS SELECT 1 AS id');
SELECT * FROM remote.query('INSERT INTO neoquack.validation.${rollback_table} VALUES (2)');
SELECT * FROM remote.query('ROLLBACK');
SELECT * FROM remote.query('SELECT CASE WHEN count(*) = 0 THEN 1 ELSE CAST(''rollback table persisted'' AS INTEGER) END AS rollback_ok FROM information_schema.tables WHERE table_catalog = ''neoquack'' AND table_schema = ''validation'' AND table_name = ''${rollback_table}''');
SELECT * FROM remote.query('BEGIN TRANSACTION');
SELECT * FROM remote.query('CREATE TABLE neoquack.validation.${commit_table} AS SELECT 1 AS id');
SELECT * FROM remote.query('INSERT INTO neoquack.validation.${commit_table} VALUES (2)');
SELECT * FROM remote.query('COMMIT');
SELECT * FROM remote.query('SELECT CASE WHEN count(*) = 2 THEN 1 ELSE CAST(''committed transaction row count mismatch'' AS INTEGER) END AS txn_ok FROM neoquack.validation.${commit_table}');
SELECT count(*) AS large_fetch_count FROM remote.query('SELECT i FROM range(0, 10000) AS t(i)');
COPY (
  SELECT data_path
  FROM remote.query('SELECT data_path FROM ducklake_settings(''neoquack'')')
) TO '$data_path_file' (HEADER false);
SELECT count(*) AS validation_file_count
FROM remote.query('FROM ducklake_list_files(''neoquack'', ''${validation_table}'', schema => ''validation'')');
COPY (
  SELECT data_file
  FROM remote.query('FROM ducklake_list_files(''neoquack'', ''${validation_table}'', schema => ''validation'')')
) TO '$file_list' (HEADER false);
SQL

cat > "$bad_sql" <<SQL
.bail on
FORCE INSTALL quack FROM core_nightly;
LOAD quack;
ATTACH '$QUACK_URI' AS remote (TYPE quack, TOKEN 'wrong-token');
FROM remote.query('SELECT 1');
SQL

cat > "$parallel_sql" <<SQL
.bail on
FORCE INSTALL quack FROM core_nightly;
LOAD quack;
ATTACH '$QUACK_URI' AS remote (TYPE quack, TOKEN '$(sql_quote "$QUACK_TOKEN")');
SELECT count(*) FROM remote.query('SELECT i FROM range(0, 10000) AS t(i)');
SQL

printf 'Checking authenticated Quack attach and DuckLake query...\n'
duckdb < "$good_sql"

if [ -n "${NEOQUACK_DUCKLAKE_DATA_PATH:-}" ]; then
  persisted_data_path="$(sed 's/^"//;s/"$//' "$data_path_file" | sed -n '1p')"
  if [ -n "$persisted_data_path" ] && [ "$persisted_data_path" != "$NEOQUACK_DUCKLAKE_DATA_PATH" ]; then
    printf 'DuckLake catalog data path mismatch. Catalog has %s, env has %s.\n' "$persisted_data_path" "$NEOQUACK_DUCKLAKE_DATA_PATH" >&2
    exit 1
  fi
fi

printf 'Checking wrong-token rejection...\n'
if duckdb < "$bad_sql" >"$wrong_token_log" 2>&1; then
  printf 'Wrong-token attach unexpectedly succeeded.\n' >&2
  cat "$wrong_token_log" >&2
  exit 1
fi

printf 'Checking two concurrent Quack fetches through the proxy...\n'
duckdb < "$parallel_sql" >"$parallel_log_a" 2>&1 &
parallel_pid_a=$!
duckdb < "$parallel_sql" >"$parallel_log_b" 2>&1 &
parallel_pid_b=$!
parallel_status=0
wait "$parallel_pid_a" || parallel_status=$?
wait "$parallel_pid_b" || parallel_status=$?
if [ "$parallel_status" -ne 0 ]; then
  printf 'Concurrent Quack fetch validation failed.\n' >&2
  cat "$parallel_log_a" >&2
  cat "$parallel_log_b" >&2
  exit 1
fi

printf 'Checking DuckLake reported data files...\n'
validation_file_count=0
while IFS= read -r data_file; do
  data_file="$(printf '%s' "$data_file" | sed 's/^"//;s/"$//')"
  [ -n "$data_file" ] || continue
  validation_file_count=$((validation_file_count + 1))
done < "$file_list"
[ "$validation_file_count" -ge 1 ] || { printf 'DuckLake did not report validation data files.\n' >&2; exit 1; }

if write_object_store_secret_sql "$object_sql"; then
  printf 'Checking object-store reads for fresh DuckLake files...\n'
  {
    printf '.bail on\n'
    printf 'INSTALL httpfs; LOAD httpfs;\n'
    cat "$object_sql"
    while IFS= read -r data_file; do
      data_file="$(printf '%s' "$data_file" | sed 's/^"//;s/"$//')"
      [ -n "$data_file" ] || continue
      printf "SELECT count(*) FROM read_parquet('%s');\n" "$(sql_quote "$data_file")"
    done < "$file_list"
  } > "$object_check_sql"
  duckdb < "$object_check_sql" >/dev/null
fi

if [ -d .fastapicloud ]; then
  printf 'Scanning recent FastAPI Cloud logs for literal secret values...\n'
  if fastapi_cli cloud logs --no-follow --tail 200 > "$logs_file" 2>&1; then
    logs="$(cat "$logs_file")"
    database_url="${DATABASE_URL:-${NEOQUACK_DATABASE_URL:-}}"
    database_password="$(url_password "$database_url")"
    for secret_value in \
      "$QUACK_TOKEN" \
      "$database_url" \
      "$database_password" \
      "${NEOQUACK_R2_ACCESS_KEY_ID:-}" \
      "${NEOQUACK_R2_SECRET_ACCESS_KEY:-}" \
      "${NEOQUACK_S3_ACCESS_KEY_ID:-}" \
      "${NEOQUACK_S3_SECRET_ACCESS_KEY:-}" \
      "${AWS_ACCESS_KEY_ID:-}" \
      "${AWS_SECRET_ACCESS_KEY:-}"
    do
      if [ -n "$secret_value" ] && printf '%s' "$logs" | grep -F "$secret_value" >/dev/null; then
        printf 'A configured secret value appeared in logs.\n' >&2
        exit 1
      fi
    done
  else
    printf 'Could not retrieve FastAPI Cloud logs; skipped log secret scan.\n' >&2
  fi
fi

if [ "${NEOQUACK_VALIDATE_REDEPLOY:-0}" = "1" ]; then
  printf 'Redeploying and verifying rows persist...\n'
  fastapi_cli deploy
  wait_for_ready "$QUACK_HTTP_URL" 300
  check_instance_affinity "$QUACK_HTTP_URL" "$affinity_file"
fi

cat > "$post_redeploy_sql" <<SQL
.bail on
FORCE INSTALL quack FROM core_nightly;
LOAD quack;
ATTACH '$QUACK_URI' AS remote (TYPE quack, TOKEN '$(sql_quote "$QUACK_TOKEN")');
SELECT *
FROM remote.query('
    SELECT
        (SELECT count(*) FROM neoquack.validation.${marker_table} WHERE marker_id = $marker_id AND marker_name = ''$marker_name'') AS marker_count,
        (SELECT count(*) FROM neoquack.validation.${validation_table}) AS validation_row_count,
        (SELECT count(*) FROM ducklake_list_files(''neoquack'', ''${validation_table}'', schema => ''validation'')) AS validation_file_count
	');
SQL

post_counts="$(duckdb -csv < "$post_redeploy_sql" | tail -n 1)"
IFS=, read -r post_marker_count post_validation_rows post_validation_files <<EOF
$post_counts
EOF
[ "$post_marker_count" = "1" ] || { printf 'Validation marker did not persist.\n' >&2; exit 1; }
[ "$post_validation_rows" = "1000" ] || { printf 'Validation table did not persist.\n' >&2; exit 1; }
[ "${post_validation_files:-0}" != "0" ] || { printf 'Validation file metadata did not persist.\n' >&2; exit 1; }

if [ "${NEOQUACK_KEEP_VALIDATION_ARTIFACTS:-0}" != "1" ]; then
  cat > "$cleanup_sql" <<SQL
.bail on
FORCE INSTALL quack FROM core_nightly;
LOAD quack;
ATTACH '$QUACK_URI' AS remote (TYPE quack, TOKEN '$(sql_quote "$QUACK_TOKEN")');
FROM remote.query('DROP TABLE IF EXISTS neoquack.validation.${validation_table}');
FROM remote.query('DROP TABLE IF EXISTS neoquack.validation.${rollback_table}');
FROM remote.query('DROP TABLE IF EXISTS neoquack.validation.${commit_table}');
FROM remote.query('DELETE FROM neoquack.validation.${marker_table} WHERE marker_id = $marker_id AND marker_name = ''$marker_name''');
SQL
  printf 'Cleaning validation catalog artifacts...\n'
  duckdb < "$cleanup_sql" >/dev/null
fi

printf 'NeoQuack FastAPI Cloud validation passed.\n'
