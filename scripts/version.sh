#!/bin/sh
# One source of release truth: a vMAJOR.MINOR.PATCH Git tag.
set -eu

tag="${GITHUB_REF_NAME:-}"
if [ -z "$tag" ]; then
    tag="$(git describe --tags --exact-match 2>/dev/null || true)"
fi
version="${tag#v}"

valid_version() {
    printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

case "${1:-}" in
version)
    if [ -n "$tag" ]; then
        printf '%s\n' "$version"
    else
        printf '0.0.0\n'
    fi
    ;;
build)
    if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
        printf '%s\n' "$GITHUB_RUN_NUMBER"
    else
        git rev-list --count HEAD
    fi
    ;;
validate)
    valid_version "$version" || { echo "Release tags must be vMAJOR.MINOR.PATCH (got: ${tag:-none})" >&2; exit 1; }
    ;;
*)
    echo "usage: $0 {version|build|validate}" >&2
    exit 64
    ;;
esac
