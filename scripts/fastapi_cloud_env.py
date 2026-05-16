#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import httpx
from fastapi_cloud_cli.utils.api import APIClient


def app_id() -> str:
    config_path = Path(".fastapicloud/cloud.json")
    if not config_path.exists():
        raise SystemExit("FastAPI Cloud app is not linked.")
    return json.loads(config_path.read_text(encoding="utf-8"))["app_id"]


def existing_env(client: APIClient, app_id_value: str, name: str) -> dict | None:
    response = client.get(f"/apps/{app_id_value}/environment-variables/")
    response.raise_for_status()
    for item in response.json()["data"]:
        if item["name"] == name:
            return item
    return None


def set_env(name: str, value: str, *, is_secret: bool) -> None:
    app_id_value = app_id()
    with APIClient() as client:
        current = existing_env(client, app_id_value, name)
        if current is None:
            response = client.post(
                f"/apps/{app_id_value}/environment-variables/",
                json={"name": name, "value": value, "is_secret": is_secret},
            )
            response.raise_for_status()
            return

        current_is_secret = bool(current.get("is_secret"))
        if current_is_secret == is_secret:
            response = client.put(
                f"/apps/{app_id_value}/environment-variables/{name}",
                json={"value": value},
            )
            response.raise_for_status()
            return

        response = client.delete(f"/apps/{app_id_value}/environment-variables/{name}")
        response.raise_for_status()
        response = client.post(
            f"/apps/{app_id_value}/environment-variables/",
            json={"name": name, "value": value, "is_secret": is_secret},
        )
        response.raise_for_status()


def delete_env(name: str) -> None:
    app_id_value = app_id()
    with APIClient() as client:
        current = existing_env(client, app_id_value, name)
        if current is None:
            return
        response = client.delete(f"/apps/{app_id_value}/environment-variables/{name}")
        response.raise_for_status()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create or update one FastAPI Cloud environment variable."
    )
    parser.add_argument("name")
    parser.add_argument("--secret", action="store_true")
    parser.add_argument("--delete", action="store_true")
    args = parser.parse_args()

    value = "" if args.delete else sys.stdin.read()
    if not args.delete and value == "":
        raise SystemExit("Environment variable value must be provided on stdin.")
    for attempt in range(1, 4):
        try:
            if args.delete:
                delete_env(args.name)
            else:
                set_env(args.name, value, is_secret=args.secret)
            return
        except httpx.HTTPError as exc:
            if attempt == 3:
                raise SystemExit(
                    f"Could not update FastAPI Cloud env {args.name}: "
                    f"{type(exc).__name__}"
                ) from exc
            time.sleep(attempt * 2)


if __name__ == "__main__":
    main()
