#!/bin/sh
set -eu

PYTHON_BIN="${PYTHON_BIN:-python3.13}"

command -v "$PYTHON_BIN" >/dev/null 2>&1 || { printf '%s is required.\n' "$PYTHON_BIN" >&2; exit 1; }
command -v uv >/dev/null 2>&1 || { printf 'uv is required.\n' >&2; exit 1; }

sh -n scripts/*.sh
"$PYTHON_BIN" -m compileall -q src
uv run --python 3.13 python -c 'from neoquack_server.app import app; assert app'
"$PYTHON_BIN" - <<'PY'
from pathlib import Path
import re
import sys

failed = False
pattern = re.compile(r"\[[^\]]+\]\(([^)#][^)]*)\)")
for path in [Path("README.md"), *Path("docs").glob("*.md"), *Path("scripts").glob("*.md")]:
    if not path.exists():
        continue
    for target in pattern.findall(path.read_text(encoding="utf-8")):
        if "://" in target or target.startswith("#") or target.startswith("mailto:"):
            continue
        clean = target.split("#", 1)[0]
        if clean.startswith("/"):
            print(f"Absolute local markdown link in {path}: {target}", file=sys.stderr)
            failed = True
            continue
        if clean and not (path.parent / clean).resolve().exists():
            print(f"Broken local markdown link in {path}: {target}", file=sys.stderr)
            failed = True
raise SystemExit(1 if failed else 0)
PY

printf 'Checks passed.\n'
