# FastAPI Cloud Routing Issue Handoff

## Suggested Issue Title

Support sticky routing or single-runtime placement for stateful HTTP protocols such as DuckDB Quack

## Suggested Opening

We have a FastAPI Cloud app that deploys successfully and serves `/readyz`, but it cannot reliably expose DuckDB Quack over the public FastAPI Cloud URL because requests are routed across multiple runtime replicas. Quack keeps server-side `quack_connection_id` state, so follow-up requests for one client session must reach the same runtime process. We need either sticky routing/session affinity or a single-runtime placement option for this app.

## Summary

NeoQuack deploys successfully to FastAPI Cloud and starts the DuckDB + DuckLake + Quack runtime.

The public Quack protocol path is blocked because FastAPI Cloud routes requests for one app URL across multiple runtime replicas. DuckDB Quack keeps `quack_connection_id` state in the server-side runtime process, so follow-up requests must reach the same runtime instance.

## App

- App URL: `https://neoquack.fastapicloud.dev`
- Runtime: FastAPI Cloud app running DuckDB `1.5.2`
- DuckDB extensions: `ducklake`, `httpfs`, `postgres`, `quack`
- Catalog: Neon Postgres
- Object store: Cloudflare R2

## Reproduce

From the NeoQuack repo:

```sh
export QUACK_HTTP_URL=https://neoquack.fastapicloud.dev
./scripts/validate-fastapi-cloud.sh
```

The validator first samples `/healthz` before running stateful Quack traffic.

Current observed failure:

```text
FastAPI Cloud routed health checks to multiple runtime instances: <instance-a>, <instance-b>
Quack requires sticky routing or a single FastAPI Cloud runtime instance because quack_connection_id state is kept server-side.
```

Manual proof:

```sh
i=0
while [ "$i" -lt 12 ]; do
  curl --silent --show-error https://neoquack.fastapicloud.dev/healthz
  printf '\n'
  i=$((i + 1))
  sleep 1
done
```

The responses alternate between multiple non-secret `instance_id` values from the app.

FastAPI Cloud logs also expose different `replica` labels for the same public app URL.

## Expected Behavior

FastAPI Cloud should provide one of these controls for this app:

- single-runtime placement
- sticky routing or session affinity that keeps a client Quack protocol session on the same runtime replica

With that in place, this command should pass:

```sh
QUACK_HTTP_URL=https://neoquack.fastapicloud.dev ./scripts/validate-fastapi-cloud.sh
```

## Actual Behavior

The app deploys and `/readyz` returns ready, but public Quack validation fails before it runs Quack queries because the public URL reaches multiple runtime replicas.

Small `quack_query()` calls can sometimes succeed, but larger results still fail with `Invalid connection id` because result fetching can require follow-up requests that route to a different runtime replica.

## Why This Is Not App-Level Fixable

Each FastAPI Cloud runtime replica starts its own local DuckDB process and local Quack listener.

The app proxy keeps a persistent upstream HTTP client inside one replica, which preserves affinity from that replica to its local Quack listener. It cannot force the next public request to land on the same FastAPI Cloud replica after the platform load balancer has already selected a replica.

Neon and R2 share DuckLake metadata and data files correctly. They do not share Quack HTTP connection state.

Leader election inside the app would still need either a stable address for the elected leader or platform routing support. Without that, a non-leader replica cannot forward Quack protocol requests to the correct runtime process.

## Current Validation Evidence

This passes and proves the same Neon/R2/DuckLake/Quack runtime configuration on one runtime instance:

```sh
./scripts/validate-local.sh
```

Coverage includes:

- authenticated Quack attach
- wrong-token rejection
- transaction rollback and commit behavior
- two concurrent large fetches
- 10,000-row result fetch
- DuckLake writes through Neon and R2
- DuckLake catalog data path drift check
- direct R2 Parquet reads for fresh DuckLake files
- FastAPI Cloud log scan for literal secret values
- cleanup of validation artifacts

This does not clear the public FastAPI Cloud routing blocker. Public production readiness requires `./scripts/validate-fastapi-cloud.sh` to pass against `QUACK_HTTP_URL`.

## References

- FastAPI Cloud deployment docs: https://fastapicloud.com/docs/builds-and-deployments/how-it-works/
- FastAPI Cloud metrics/replicas docs: https://fastapicloud.com/docs/monitoring-and-performance/metrics/
- DuckDB Quack overview: https://duckdb.org/docs/current/quack/overview
- DuckDB Quack reverse proxy guidance: https://duckdb.org/docs/current/quack/setup/reverse_proxy
