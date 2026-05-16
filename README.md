# NeoQuack

Run DuckDB as a remote Quack server on FastAPI Cloud.

Use DuckLake for storage:

- Neon Postgres stores the DuckLake catalog.
- Cloudflare R2 stores the DuckLake Parquet files.

## One Command

Before you run it, make sure these tools are available and logged in where needed:

- Python 3.13
- `uv`
- `npx`
- `duckdb` CLI v1.5.2
- `curl`
- FastAPI Cloud login
- Neon login
- Cloudflare Wrangler login

```sh
./scripts/deploy-fastapi-cloud.sh
```

That command creates or reuses the Neon catalog, confirms the R2 bucket in the configured Cloudflare account, sets FastAPI Cloud secrets, and deploys the app.

On a fresh setup, the first run can stop after creating `.neoquack/object-store.env`. Fill in the R2 S3 key fields, then rerun the same command. If Wrangler can see more than one Cloudflare account, set `NEOQUACK_R2_ACCOUNT_ID` or `CLOUDFLARE_ACCOUNT_ID` before running it.

## Current Status

| Check | Status |
| --- | --- |
| FastAPI Cloud deployment | running |
| Local Neon/R2/DuckLake/Quack proof | passing with `./scripts/validate-local.sh` |
| Public Quack production readiness | blocked until `./scripts/validate-fastapi-cloud.sh` passes against `QUACK_HTTP_URL` |
| Known blocker | FastAPI Cloud currently routes the public URL across multiple runtime replicas |

`./scripts/validate-local.sh` proves the same Neon/R2/runtime configuration on one local instance, but it does not clear the public-routing blocker.

## R2 Keys

Put the R2 values in:

```text
.neoquack/object-store.env
```

The setup script creates that file with `0600` permissions and keeps it ignored by git.

Create the Cloudflare S3 API token from:

```text
R2 Object Storage > Overview > Account Details > API Tokens > Manage
```

The bucket Settings > General page shows the S3 API endpoint, for example:

```text
https://your-account-id.r2.cloudflarestorage.com/neoquack-ducklake
```

## Validate

To validate during deployment, set the app URL first:

```sh
export QUACK_HTTP_URL=https://your-app.fastapicloud.dev
./scripts/deploy-fastapi-cloud.sh
```

Use the URL printed by `fastapi deploy` or the app domain shown in the FastAPI Cloud dashboard.

To validate after deployment:

```sh
export QUACK_HTTP_URL=https://your-app.fastapicloud.dev
./scripts/validate-fastapi-cloud.sh
```

Quack requires sticky routing or a single FastAPI Cloud runtime instance. The validator checks this before running Quack queries and stops with a clear message if FastAPI Cloud routes requests across multiple instances.

That routing failure means the public FastAPI Cloud URL is not production-safe for Quack yet. It does not mean Neon, R2, DuckLake, or the local Quack runtime failed.

To validate the same Neon and R2 setup through a single local runtime:

```sh
./scripts/validate-local.sh
```

The current FastAPI Cloud CLI/API surface does not expose a scriptable replica-count or sticky-routing setting. If public validation stops at the routing check, configure single-instance or sticky routing in FastAPI Cloud if that control becomes available for the app/account, then rerun the public validator.

## Documentation

See [FastAPI Cloud, Neon, and R2](docs/fastapi-cloud.md).

See [FastAPI Cloud routing issue handoff](docs/fastapi-cloud-routing-issue.md).

See [scripts](scripts/README.md).

## Local Checks

```sh
./scripts/check.sh
```
