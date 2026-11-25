from __future__ import annotations

import logging
import os
import threading
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import urlparse

from fastapi import FastAPI, Request, Response
from starlette.background import BackgroundTask
from starlette.responses import JSONResponse, RedirectResponse, StreamingResponse
import httpx

from mallard_cloud.app import create_app as create_mallard
from neoquack_server import main as runtime


RUNTIME_THREAD: threading.Thread | None = None
QUACK_CLIENT: httpx.AsyncClient | None = None
LOGGER = logging.getLogger("neoquack.proxy")
INSTANCE_ID = os.getenv("NEOQUACK_INSTANCE_ID", uuid.uuid4().hex[:12])

HOP_BY_HOP_HEADERS = {
    "connection",
    "host",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


def quack_base_url() -> str:
    listen_uri = os.getenv("NEOQUACK_LISTEN_URI", "quack:127.0.0.1:9494")
    if listen_uri.startswith("quack://"):
        parsed = urlparse(listen_uri)
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or 9494
        if host == "0.0.0.0":
            host = "127.0.0.1"
        if ":" in host and not host.startswith("["):
            host = f"[{host}]"
        return f"http://{host}:{port}"

    host_port = listen_uri.removeprefix("quack:")
    if host_port.startswith("0.0.0.0:"):
        host_port = "127.0.0.1:" + host_port.rsplit(":", 1)[1]
    if ":" not in host_port:
        host_port = f"{host_port}:9494"
    return f"http://{host_port}"


def filtered_headers(headers: dict[str, str]) -> dict[str, str]:
    return {
        key: value
        for key, value in headers.items()
        if key.lower() not in HOP_BY_HOP_HEADERS
    }


def env_float(name: str, default: float) -> float:
    value = os.getenv(name)
    if not value:
        return default
    try:
        return float(value)
    except ValueError:
        LOGGER.warning("invalid %s=%r; using %s", name, value, default)
        return default


def env_int(name: str, default: int) -> int:
    value = os.getenv(name)
    if not value:
        return default
    try:
        return int(value)
    except ValueError:
        LOGGER.warning("invalid %s=%r; using %s", name, value, default)
        return default


def quack_proxy_connection_limit(name: str) -> int:
    configured = env_int(name, 1)
    if configured != 1:
        LOGGER.warning(
            "%s=%s ignored; Quack proxy requires one upstream connection "
            "until it is quack_connection_id aware",
            name,
            configured,
        )
    return 1


def startup_payload() -> dict[str, object]:
    return {
        "ready": runtime.READY.is_set(),
        "startup_error": runtime.STARTUP_ERROR,
        "instance_id": INSTANCE_ID,
    }


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    global QUACK_CLIENT, RUNTIME_THREAD

    QUACK_CLIENT = httpx.AsyncClient(
        timeout=httpx.Timeout(
            connect=env_float("NEOQUACK_PROXY_CONNECT_TIMEOUT", 10.0),
            read=env_float("NEOQUACK_PROXY_READ_TIMEOUT", 300.0),
            write=env_float("NEOQUACK_PROXY_WRITE_TIMEOUT", 300.0),
            pool=env_float("NEOQUACK_PROXY_POOL_TIMEOUT", 30.0),
        ),
        limits=httpx.Limits(
            max_connections=quack_proxy_connection_limit(
                "NEOQUACK_PROXY_MAX_CONNECTIONS"
            ),
            max_keepalive_connections=quack_proxy_connection_limit(
                "NEOQUACK_PROXY_MAX_KEEPALIVE_CONNECTIONS",
            ),
        ),
    )
    RUNTIME_THREAD = threading.Thread(
        target=runtime.run,
        kwargs={"install_signal_handlers": False},
        name="neoquack-runtime",
        daemon=True,
    )
    RUNTIME_THREAD.start()
    try:
        yield
    finally:
        runtime.STOP.set()
        if RUNTIME_THREAD:
            RUNTIME_THREAD.join(timeout=20)
        if QUACK_CLIENT:
            await QUACK_CLIENT.aclose()
            QUACK_CLIENT = None


app = FastAPI(lifespan=lifespan)


@app.get("/mallard", include_in_schema=False)
async def mallard_directory() -> RedirectResponse:
    return RedirectResponse("/mallard/", status_code=307)


# Reserve this prefix before the Quack protocol's catch-all proxy.
app.mount("/mallard", create_mallard(), name="mallard")


@app.get("/")
@app.get("/healthz")
def healthz() -> dict[str, object]:
    return startup_payload()


@app.get("/readyz")
def readyz() -> Response:
    status_code = 200 if runtime.READY.is_set() else 503
    return JSONResponse(startup_payload(), status_code=status_code)


@app.api_route(
    "/",
    operation_id="proxy_quack__put",
    methods=["DELETE", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"],
)
@app.api_route(
    "/{path:path}",
    operation_id="proxy_quack__path__put",
    methods=["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"],
)
async def proxy_quack(request: Request, path: str = "") -> Response:
    if not runtime.READY.is_set():
        return JSONResponse(startup_payload(), status_code=503)
    if QUACK_CLIENT is None:
        return JSONResponse(
            {
                "ready": False,
                "startup_error": "Quack proxy client is not initialized",
            },
            status_code=503,
        )

    target_url = httpx.URL(
        f"{quack_base_url()}/{path}",
        query=request.url.query.encode("utf-8"),
    )
    proxy_request = QUACK_CLIENT.build_request(
        request.method,
        target_url,
        headers=filtered_headers(dict(request.headers)),
        content=request.stream(),
    )
    try:
        LOGGER.info(
            "proxying Quack request instance=%s method=%s path=/%s",
            INSTANCE_ID,
            request.method,
            path,
        )
        proxy_response = await QUACK_CLIENT.send(proxy_request, stream=True)
    except httpx.HTTPError as exc:
        LOGGER.warning(
            "Quack upstream request failed method=%s path=/%s upstream=%s error=%s",
            request.method,
            path,
            target_url,
            type(exc).__name__,
            exc_info=True,
        )
        return JSONResponse(
            {
                "ready": False,
                "startup_error": "Quack upstream request failed",
                "upstream_error_type": type(exc).__name__,
            },
            status_code=502,
        )

    return StreamingResponse(
        proxy_response.aiter_raw(),
        status_code=proxy_response.status_code,
        headers=filtered_headers(dict(proxy_response.headers)),
        background=BackgroundTask(proxy_response.aclose),
    )
