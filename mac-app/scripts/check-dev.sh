#!/bin/sh
# Deterministic checks by default; --runtime also reads live permission metadata.
set -eu
case "$#:${1:-}" in
    0:|1:--runtime) ;;
    *) echo "usage: $0 [--runtime]" >&2; exit 64 ;;
esac
cd "$(dirname "$0")/.."
# Normalize deterministic failures so exit 2 is reserved for blocked permission.
if swift build && .build/debug/benice --selftest &&
    python3 scripts/check-signing.py && python3 scripts/check-debug-status.py; then
    echo "PASS: deterministic development checks"
else
    echo "FAIL: deterministic development checks" >&2
    exit 1
fi
if [ "${1:-}" = --runtime ]; then
    status=0
    python3 scripts/debug-status.py || status=$?
    case "$status" in
        0) echo "PASS: running development app has Accessibility permission" ;;
        2) echo "BLOCKED: running development app lacks Accessibility permission" >&2 ;;
        *) echo "UNAVAILABLE: live development app permission status" >&2 ;;
    esac
    exit "$status"
fi
