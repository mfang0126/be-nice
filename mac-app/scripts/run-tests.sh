#!/bin/sh
# Runs every deterministic selftest: no GUI, network, real Keychain or live AX writes.
set -eu
cd "$(dirname "$0")/../.."
S=mac-app/Sources/benice
T=mac-app
OUT=$(mktemp -d "${TMPDIR:-/tmp}/benice-tests.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
fail=0

# run <name> [-lib] <sources...>; -lib adds -parse-as-library
run() {
    name=$1; shift
    flags=""
    if [ "$1" = -lib ]; then flags=-parse-as-library; shift; fi
    if swiftc -swift-version 6 $flags "$@" -o "$OUT/$name" && "$OUT/$name" >"$OUT/$name.log" 2>&1; then
        echo "PASS $name"
    else
        echo "FAIL $name"; cat "$OUT/$name.log" 2>/dev/null || true; fail=1
    fi
}

swift build --package-path mac-app
mac-app/.build/debug/benice --selftest >/dev/null && echo "PASS benice-selftest" || { echo "FAIL benice-selftest"; fail=1; }

run model $S/ModelClient.swift $S/RewriteOptions.swift $T/ModelClientTests.swift
run rewrite-options -lib $S/ModelClient.swift $S/RewriteOptions.swift $T/RewriteOptionsTests.swift
run rewrite-window -lib $S/ModelClient.swift $S/RewriteOptions.swift $S/RewriteWindowController.swift $T/RewriteWindowTests.swift
run rewrite-copy-only -lib $S/ModelClient.swift $S/RewriteOptions.swift $S/RewriteWindowController.swift $T/RewriteCopyOnlyTests.swift
run writeback -lib $S/WriteBack.swift $S/ModelClient.swift $S/RewriteOptions.swift $T/WriteBackTests.swift
run trigger -lib $S/TriggerController.swift $T/TriggerTests.swift
run settings -lib $S/CredentialStore.swift $S/ModelClient.swift $S/RewriteOptions.swift $S/SettingsWindow.swift $T/SettingsTests.swift
run slack-diagnostic $S/SlackDiagnostic.swift $T/SlackDiagnosticTests.swift
run style-profile $S/StyleProfile.swift $T/StyleProfileTests.swift
run style-extraction $S/ModelClient.swift $S/RewriteOptions.swift $S/StyleProfile.swift $S/StyleExtraction.swift $T/StyleExtractionTests.swift
run style-window -lib $S/ModelClient.swift $S/RewriteOptions.swift $S/StyleProfile.swift $S/StyleExtraction.swift $S/StyleWindow.swift $T/StyleWindowTests.swift

for py in $T/OptimizerControllerTests.py $T/DiagnosticPublicationTests.py; do
    python3 -I "$py" >/dev/null 2>&1 && echo "PASS $(basename "$py")" || { echo "FAIL $(basename "$py")"; fail=1; }
done

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED" >&2; exit 1; }
