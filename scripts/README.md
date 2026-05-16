# Scripts

Run the full FastAPI Cloud + Neon + R2 flow:

```sh
./scripts/deploy-fastapi-cloud.sh
```

The command is designed to be re-run.

## Wrapper

| Script | Purpose |
| --- | --- |
| `deploy-fastapi-cloud.sh` | Runs Neon setup, object-store setup, FastAPI Cloud env setup, deployment, and optional validation |

## Phases

The wrapper delegates to these phases:

| Phase | Script | Inputs | Output |
| --- | --- | --- | --- |
| Neon catalog | `setup-neon.sh` | Neon login, optional `NEON_PROJECT_NAME`, `NEON_DATABASE_NAME`, `NEON_ROLE_NAME`, `NEON_REGION_ID`, `NEON_CU` overrides | `.neoquack/neon.env` |
| Object store | `setup-r2.sh` | Wrangler login, optional `NEOQUACK_R2_ACCOUNT_ID` / `CLOUDFLARE_ACCOUNT_ID` | R2 bucket plus `.neoquack/object-store.env` |
| Object-store validation | `setup-object-store-env.sh` | R2/S3 keys in `.neoquack/object-store.env` | validated local storage env |
| FastAPI Cloud env | `setup-fastapi-cloud-env.sh` | FastAPI Cloud login and local `.neoquack/*.env` files | FastAPI Cloud env vars/secrets plus `.neoquack/fastapi-cloud.env` |
| Deploy | `uv run --python 3.13 fastapi deploy` | all prior phases | live FastAPI Cloud app |
| Public validation | `validate-fastapi-cloud.sh` | `QUACK_HTTP_URL` or `FASTAPI_CLOUD_URL` | full Quack/DuckLake validation if routing affinity exists |
| Local single-runtime validation | `validate-local.sh` | local `.neoquack/*.env` files | full Quack/DuckLake validation on `127.0.0.1` |

The first run may stop at the object-store phase after writing `.neoquack/object-store.env`. Fill in `NEOQUACK_R2_ACCESS_KEY_ID` and `NEOQUACK_R2_SECRET_ACCESS_KEY`, then rerun the same command.

`setup-fastapi-cloud-env.sh` validates object-store placeholders before publishing and updates existing FastAPI Cloud env vars in place when the secret/plain classification already matches.

R2 S3 credentials are created in the Cloudflare dashboard:

```text
R2 Object Storage > Overview > Account Details > API Tokens > Manage
```

The bucket Settings > General page shows the S3 API endpoint:

```text
https://your-account-id.r2.cloudflarestorage.com/neoquack-ducklake
```

Local secret state is stored under `.neoquack/` and ignored by git.
