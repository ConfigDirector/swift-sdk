#!/usr/bin/env sh
#
# Fails unless the release tag matches the version the SDK reports at runtime.
#
# Usage: check-release-version.sh v1.2.3

set -eu

constants=Sources/ConfigDirector/Internal/Constants.swift
tag=${1:-}

if [ -z "$tag" ]; then
    echo "usage: $0 <tag>" >&2
    exit 2
fi

case "$tag" in
    v*) version=${tag#v} ;;
    *)
        echo "Release tag '$tag' does not start with 'v'." >&2
        exit 1
        ;;
esac

if [ ! -f "$constants" ]; then
    echo "Cannot find $constants. Run this from the repository root." >&2
    exit 1
fi

declared=$(sed -n 's/^[[:space:]]*static let sdkVersion = "\([^"]*\)".*$/\1/p' "$constants")

if [ -z "$declared" ]; then
    echo "Could not read sdkVersion from $constants." >&2
    exit 1
fi

if [ "$declared" != "$version" ]; then
    echo "Release tag and SDK version disagree:" >&2
    echo "  the tag $tag asks for version $version" >&2
    echo "  Constants.sdkVersion is $declared" >&2
    echo >&2
    echo "The SDK sends Constants.sdkVersion to the server with every telemetry batch, so a" >&2
    echo "release tagged one version while reporting another cannot be attributed. Update" >&2
    echo "$constants to $version, commit, and move the tag." >&2
    exit 1
fi

echo "Release version $version matches Constants.sdkVersion."
