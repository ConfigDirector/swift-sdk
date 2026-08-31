#!/usr/bin/env sh
#
# Prints the CHANGELOG.md section for a version, and fails when it has none.
#
# The release workflow uses this for the release notes, which is also what makes a missing entry
# stop a release: a version nobody wrote down is a version nobody can read the notes for.
#
# Usage: changelog-section.sh 1.2.3

set -eu

version=${1:-}

if [ -z "$version" ]; then
    echo "usage: $0 <version>" >&2
    exit 2
fi

python3 - "$version" <<'PY'
import pathlib
import sys

version = sys.argv[1]
path = pathlib.Path("CHANGELOG.md")

if not path.is_file():
    sys.exit(f"Cannot find {path}. Run this from the repository root.")

heading = f"## [{version}]"
lines = path.read_text().splitlines()
section = []
inside = False

for line in lines:
    if line.startswith("## "):
        if inside:
            break
        inside = line == heading or line.startswith(heading + " ")
        continue
    if inside:
        section.append(line)

if not inside and not section:
    sys.exit(
        f"CHANGELOG.md has no '{heading}' section.\n"
        f"Rename the '## [Unreleased]' heading to '## [{version}] - YYYY-MM-DD' and commit it "
        "before tagging."
    )

body = "\n".join(section).strip("\n")

if not body:
    sys.exit(f"The '{heading}' section in CHANGELOG.md is empty.")

print(body)
PY
