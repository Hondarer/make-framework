#!/usr/bin/env bash
set -eu

toolchain="${1:-}"
if [ "$#" -lt 2 ]; then
    echo "ERROR: Usage: $0 <c_cpp|dotnet> <command> [args...]" >&2
    exit 1
fi
shift

case "$toolchain" in
    c_cpp|dotnet)
        ;;
    *)
        echo "ERROR: Unsupported COVERITY_TOOLCHAIN: $toolchain" >&2
        exit 1
        ;;
esac

if [ -z "${COVERITY_HOME:-}" ]; then
    echo "ERROR: COVERITY_HOME is required." >&2
    exit 1
fi

cov_build="${COVERITY_HOME%/}/bin/cov-build"
if [ ! -x "$cov_build" ]; then
    echo "ERROR: cov-build was not found or is not executable: $cov_build" >&2
    exit 1
fi

workspace_dir="${WORKSPACE_DIR:-}"
if [ -z "$workspace_dir" ]; then
    script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
    workspace_dir="$(CDPATH= cd -- "$script_dir/../../.." && pwd)"
fi

idir="$workspace_dir/app/idir"
mkdir -p "$idir"

exec "$cov_build" --append-log --dir "$idir" "$@"
