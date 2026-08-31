#!/usr/bin/env sh
#
# Fails when DocC reported anything while building the documentation.
#
# DocC has no --warnings-as-errors, and `xcodebuild docbuild` exits 0 with a broken symbol link:
# it renders the link as plain text and ships a subtly wrong page. The diagnostics file written
# beside the archive is the only place the problem is recorded.
#
# Usage: check-docs-diagnostics.sh <derived-data-path>

set -eu

derived=${1:-}

if [ -z "$derived" ]; then
    echo "usage: $0 <derived-data-path>" >&2
    exit 2
fi

python3 - "$derived" <<'PY'
import json
import pathlib
import sys

derived = pathlib.Path(sys.argv[1])

if not derived.is_dir():
    sys.exit(f"No such derived data directory: {derived}")

files = sorted(derived.rglob("*-diagnostics.json"))

if not files:
    sys.exit(f"No DocC diagnostics file under {derived}. Did the documentation build run?")

total = 0

for path in files:
    diagnostics = json.loads(path.read_text()).get("diagnostics", [])
    for entry in diagnostics:
        total += 1
        source = entry.get("source", "")
        line = entry.get("range", {}).get("start", {}).get("line", "")
        where = f"{source}:{line}: " if source else ""
        print(f"{where}{entry.get('severity', 'warning')}: {entry.get('summary', '')}")

if total:
    sys.exit(
        f"\n{total} documentation diagnostic(s). Documentation is generated from these comments, "
        "so a broken link is a broken page."
    )

print(f"Documentation built with no diagnostics ({len(files)} target(s) checked).")
PY
