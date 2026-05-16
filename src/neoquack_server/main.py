from __future__ import annotations

import json
import logging
import os
import signal
import threading
import time
from dataclasses import dataclass, field
from typing import NoReturn
from urllib.parse import parse_qsl, unquote, urlparse

import duckdb
from psycopg.conninfo import make_conninfo


LOG_LEVEL = os.getenv("NEOQUACK_LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s %(levelname)s %(message)s")
LOGGER = logging.getLogger("neoquack")

READY = threading.Event()
STOP = threading.Event()
STARTUP_ERROR: str | None = None
UNSUPPORTED_DUCKLAKE_CONNINFO_PARAMS = {"channel_binding"}


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def optional_secret_field(value: str | None, keyword: str) -> str:
    if not value:
        return ""
    return f",\n            {keyword} {sql_string(value)}"


def sanitized_startup_error(exc: Exception) -> str:
    return type(exc).__name__


def reset_runtime_state() -> None:
    global STARTUP_ERROR

    READY.clear()
    STOP.clear()
    STARTUP_ERROR = None


@dataclass(frozen=True)
class PostgresConfig:
    host: str
    database: str
    user: str
    password: str
    port: str = "5432"
    sslmode: str = "require"
    extra_conninfo: dict[str, str] = field(default_factory=dict)

    def conninfo(self) -> str:
        return make_conninfo(
            "",
            dbname=self.database,
            host=self.host,
            port=self.port,
            user=self.user,
            sslmode=self.sslmode,
            **self.extra_conninfo,
        )


def postgres_config_from_env() -> PostgresConfig:
    database_url = os.getenv("NEOQUACK_DATABASE_URL") or os.getenv("DATABASE_URL")
    if not database_url:
        raise RuntimeError("Missing required environment variable: DATABASE_URL")

    parsed = urlparse(database_url)
    if parsed.scheme not in {"postgres", "postgresql"}:
        raise RuntimeError("DATABASE_URL must use postgres:// or postgresql://")
    if not parsed.hostname or not parsed.username or not parsed.path.strip("/"):
        raise RuntimeError("DATABASE_URL must include host, user, and database")

    query = dict(parse_qsl(parsed.query, keep_blank_values=True))
    sslmode = os.getenv("NEOQUACK_PG_SSLMODE", query.pop("sslmode", "require"))
    extra_conninfo = {
        key: value
        for key, value in query.items()
        if key not in UNSUPPORTED_DUCKLAKE_CONNINFO_PARAMS
    }
    return PostgresConfig(
        host=parsed.hostname,
        port=str(parsed.port or 5432),
        database=unquote(parsed.path.lstrip("/")),
        user=unquote(parsed.username),
        password=unquote(parsed.password or ""),
        sslmode=sslmode,
        extra_conninfo=extra_conninfo,
    )


def object_store_provider() -> str:
    configured = os.getenv("NEOQUACK_OBJECT_STORE")
    if configured:
        return configured.lower()
    if os.getenv("NEOQUACK_R2_ACCOUNT_ID"):
        return "r2"
    if os.getenv("NEOQUACK_S3_ENDPOINT"):
        return "s3"
    return "r2"


def install_and_load_extensions(con: duckdb.DuckDBPyConnection) -> None:
    force_install = os.getenv("NEOQUACK_FORCE_INSTALL_EXTENSIONS", "0") == "1"
    install = "FORCE INSTALL" if force_install else "INSTALL"
    quack_repository = os.getenv("NEOQUACK_QUACK_EXTENSION_REPOSITORY", "core_nightly")
    extensions = [
        ("httpfs", None),
        ("postgres", None),
        ("ducklake", None),
        ("quack", quack_repository),
    ]
    for extension, repository in extensions:
        if repository:
            con.execute(f"{install} {extension} FROM {repository}")
        else:
            con.execute(f"{install} {extension}")
        con.execute(f"LOAD {extension}")

    for name, loaded, installed, version, mode, source in con.execute(
        """
        SELECT extension_name, loaded, installed, extension_version, install_mode, installed_from
        FROM duckdb_extensions()
        WHERE extension_name IN ('httpfs', 'postgres', 'ducklake', 'quack')
        ORDER BY extension_name
        """
    ).fetchall():
        LOGGER.info(
            "DuckDB extension %s loaded=%s installed=%s version=%s mode=%s source=%s",
            name,
            loaded,
            installed,
            version,
            mode,
            source,
        )


def configure_r2_storage_secret(con: duckdb.DuckDBPyConnection) -> None:
    data_path = require_env("NEOQUACK_DUCKLAKE_DATA_PATH")
    account_id = require_env("NEOQUACK_R2_ACCOUNT_ID")
    key_id = os.getenv("NEOQUACK_R2_ACCESS_KEY_ID") or os.getenv("AWS_ACCESS_KEY_ID")
    secret = os.getenv("NEOQUACK_R2_SECRET_ACCESS_KEY") or os.getenv(
        "AWS_SECRET_ACCESS_KEY"
    )
    if not key_id or not secret:
        raise RuntimeError(
            "R2 storage requires NEOQUACK_R2_ACCESS_KEY_ID and "
            "NEOQUACK_R2_SECRET_ACCESS_KEY"
        )

    con.execute(
        f"""
        CREATE OR REPLACE SECRET neoquack_storage (
            TYPE r2,
            KEY_ID {sql_string(key_id)},
            SECRET {sql_string(secret)},
            ACCOUNT_ID {sql_string(account_id)},
            SCOPE {sql_string(os.getenv("NEOQUACK_OBJECT_STORE_SCOPE", data_path))}
        )
        """
    )


def configure_s3_storage_secret(con: duckdb.DuckDBPyConnection) -> None:
    data_path = require_env("NEOQUACK_DUCKLAKE_DATA_PATH")
    endpoint = os.getenv("NEOQUACK_S3_ENDPOINT")
    key_id = os.getenv("NEOQUACK_S3_ACCESS_KEY_ID") or os.getenv("AWS_ACCESS_KEY_ID")
    secret = os.getenv("NEOQUACK_S3_SECRET_ACCESS_KEY") or os.getenv(
        "AWS_SECRET_ACCESS_KEY"
    )
    if not key_id or not secret or not endpoint:
        raise RuntimeError(
            "S3-compatible storage requires NEOQUACK_S3_ACCESS_KEY_ID and "
            "NEOQUACK_S3_SECRET_ACCESS_KEY and NEOQUACK_S3_ENDPOINT"
        )

    con.execute(
        f"""
        CREATE OR REPLACE SECRET neoquack_storage (
            TYPE s3,
            PROVIDER config,
            KEY_ID {sql_string(key_id)},
            SECRET {sql_string(secret)},
            REGION {sql_string(os.getenv("NEOQUACK_S3_REGION", "auto"))}
            {optional_secret_field(endpoint, "ENDPOINT")}
            {optional_secret_field(os.getenv("NEOQUACK_S3_URL_STYLE"), "URL_STYLE")},
            SCOPE {sql_string(os.getenv("NEOQUACK_OBJECT_STORE_SCOPE", data_path))}
        )
        """
    )


def configure_storage_secret(con: duckdb.DuckDBPyConnection) -> None:
    provider = object_store_provider()
    if provider == "r2":
        configure_r2_storage_secret(con)
    elif provider in {"s3", "tigris"}:
        configure_s3_storage_secret(con)
    else:
        raise RuntimeError("NEOQUACK_OBJECT_STORE must be one of: r2, s3, tigris")


def attach_ducklake(con: duckdb.DuckDBPyConnection) -> None:
    pg = postgres_config_from_env()
    data_path = require_env("NEOQUACK_DUCKLAKE_DATA_PATH")
    automatic_migration = (
        "true"
        if os.getenv("NEOQUACK_DUCKLAKE_AUTOMATIC_MIGRATION", "0") == "1"
        else "false"
    )
    con.execute(
        f"""
        CREATE OR REPLACE SECRET neoquack_pg_catalog (
            TYPE postgres,
            HOST {sql_string(pg.host)},
            PORT {pg.port},
            DATABASE {sql_string(pg.database)},
            USER {sql_string(pg.user)},
            PASSWORD {sql_string(pg.password)}
        )
        """
    )
    con.execute(
        f"""
        ATTACH {sql_string("ducklake:postgres:" + pg.conninfo())} AS neoquack
        (
            DATA_PATH {sql_string(data_path)},
            META_SECRET 'neoquack_pg_catalog',
            AUTOMATIC_MIGRATION {automatic_migration},
            OVERRIDE_DATA_PATH false
        )
        """
    )
    con.execute("USE neoquack")


def initialize_demo_data(con: duckdb.DuckDBPyConnection) -> None:
    attempts = int(os.getenv("NEOQUACK_INIT_ATTEMPTS", "8"))
    for attempt in range(1, attempts + 1):
        try:
            con.execute("CREATE SCHEMA IF NOT EXISTS demo")
            con.execute(
                """
                CREATE TABLE IF NOT EXISTS demo.events (
                    event_id INTEGER,
                    event_name VARCHAR,
                    created_at TIMESTAMPTZ
                )
                """
            )
            con.execute(
                """
                INSERT INTO demo.events
                SELECT 1, 'quack-over-neon-r2', now()
                WHERE NOT EXISTS (
                    SELECT 1 FROM demo.events WHERE event_id = 1
                )
                """
            )
            return
        except Exception as exc:
            if attempt == attempts:
                raise
            delay = min(30, attempt * 5)
            LOGGER.warning(
                "demo data initialization failed (%s); retrying in %s seconds",
                exc,
                delay,
                exc_info=True,
            )
            time.sleep(delay)


def identify_node(con: duckdb.DuckDBPyConnection) -> None:
    meta = {
        "object_store": object_store_provider(),
        "ducklake_data_path_configured": bool(os.getenv("NEOQUACK_DUCKLAKE_DATA_PATH")),
        "object_store_scope_configured": bool(os.getenv("NEOQUACK_OBJECT_STORE_SCOPE")),
    }
    con.execute(
        f"""
        CALL quack_identify(
            name => {sql_string(os.getenv("NEOQUACK_NODE_NAME", "neoquack"))},
            provider => {sql_string(os.getenv("NEOQUACK_RUNTIME_PROVIDER", "fastapi-cloud"))},
            region => {sql_string(os.getenv("NEOQUACK_REGION", "unknown"))},
            meta => {sql_string(json.dumps(meta, sort_keys=True))}
        )
        """
    )


def serve_quack(con: duckdb.DuckDBPyConnection) -> None:
    token = require_env("NEOQUACK_QUACK_TOKEN")
    uri = os.getenv("NEOQUACK_LISTEN_URI", "quack:127.0.0.1:9494")
    allow_other_hostname = "true" if "0.0.0.0" in uri else "false"
    con.execute(
        f"""
        CALL quack_serve(
            {sql_string(uri)},
            token => {sql_string(token)},
            allow_other_hostname => {allow_other_hostname}
        )
        """
    ).fetchall()
    LOGGER.info("Quack server started on %s", uri)


def handle_signal(signum: int, _frame: object) -> None:
    LOGGER.info("received signal %s, shutting down", signum)
    STOP.set()


def run(*, install_signal_handlers: bool = True) -> None:
    global STARTUP_ERROR

    reset_runtime_state()
    if install_signal_handlers:
        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGINT, handle_signal)

    con = duckdb.connect(os.getenv("NEOQUACK_BOOTSTRAP_DB", ":memory:"))
    try:
        LOGGER.info("installing DuckDB extensions")
        install_and_load_extensions(con)
        LOGGER.info("configuring %s storage secret", object_store_provider())
        configure_storage_secret(con)
        LOGGER.info("attaching DuckLake")
        attach_ducklake(con)
        if os.getenv("NEOQUACK_INIT_DEMO_DATA", "0") == "1":
            LOGGER.info("initializing demo data")
            initialize_demo_data(con)
        LOGGER.info("identifying Quack node")
        identify_node(con)
        LOGGER.info("starting Quack")
        serve_quack(con)
        READY.set()
        LOGGER.info("NeoQuack is ready")

        while not STOP.is_set():
            time.sleep(1)
    except Exception as exc:
        STARTUP_ERROR = sanitized_startup_error(exc)
        if os.getenv("NEOQUACK_LOG_STARTUP_TRACEBACK", "0") == "1":
            LOGGER.exception("startup failed")
        else:
            LOGGER.error("startup failed: %s", STARTUP_ERROR)
        raise
    finally:
        READY.clear()
        listen_uri = os.getenv("NEOQUACK_LISTEN_URI", "quack:127.0.0.1:9494")
        try:
            con.execute(f"CALL quack_stop({sql_string(listen_uri)})")
        except Exception as exc:
            LOGGER.info("quack stop skipped: %s", exc)
        con.close()


def main() -> NoReturn:
    try:
        run()
    except Exception:
        if os.getenv("NEOQUACK_LOG_STARTUP_TRACEBACK", "0") == "1":
            LOGGER.exception("neoquack server failed")
        else:
            LOGGER.error("neoquack server failed")
        raise SystemExit(1)
    raise SystemExit(0)
