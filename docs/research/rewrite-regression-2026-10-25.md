# Rewrite regression — 2026-10-25

Deterministic checks only. No source edits. No network, no real Keychain, no live AX, no GUI automation. Two standalone probe scripts were typechecked, not run.

Workspace: `/Users/mingfang/orca/workspaces/be-nice/be-nice-m0-axprobe`
Branch: `mfang0126/be-nice-m0-axprobe`

## Result

All checks pass except one pre-existing compile warning and one Swift 6 language-mode limitation in the two standalone probe scripts. No test failures.

## 1. Build

```sh
swift package --package-path mac-app clean
swift build --package-path mac-app
```

`rc=0`, `Build complete! (7.18 sec.)`. Two warnings, both the same message in a pre-existing file:

```
mac-app/Sources/axprobe/SelfCheck.swift:133:15: warning: will never be executed
```

Line 133 is `print("SELFTEST FAILED (\(failures) assertion(s))")`. Compiler artifact of the `expect(false, …)` else-branch at `SelfCheck.swift:125-127`; not a test failure, not fixed here.

## 2. Self-checks

```sh
mac-app/.build/debug/axprobe selftest     # rc=0, "SELFTEST PASS"
mac-app/.build/debug/benice --selftest    # rc=0, 8 PASS lines, 0 FAIL
```

`benice --selftest` exercises the permission state machine only (never-granted / granted / revoked / re-granted / persisted-grant cases). No `NSApplication`, no TCC.

## 3. swiftc test binaries

`RewriteOptions.swift` was added to every command that compiles `ModelClient.swift`, per the dispatch instruction. All binaries compiled `rc=0` and ran `rc=0`.

```sh
R=mac-app/Sources/benice

# ModelClient
swiftc -swift-version 6 $R/ModelClient.swift $R/RewriteOptions.swift \
  mac-app/ModelClientTests.swift -o /tmp/benice-model-tests
# Settings
swiftc -swift-version 6 -parse-as-library $R/CredentialStore.swift $R/ModelClient.swift \
  $R/RewriteOptions.swift $R/SettingsWindow.swift mac-app/SettingsTests.swift \
  -o /tmp/benice-settings-tests
# WriteBack
swiftc -swift-version 6 -parse-as-library $R/WriteBack.swift $R/ModelClient.swift \
  $R/RewriteOptions.swift mac-app/WriteBackTests.swift -o /tmp/benice-writeback-tests
# Trigger (no ModelClient)
swiftc -swift-version 6 -parse-as-library $R/TriggerController.swift \
  mac-app/TriggerTests.swift -o /tmp/benice-trigger-tests
# StyleProfile (no ModelClient)
swiftc -swift-version 6 $R/StyleProfile.swift mac-app/StyleProfileTests.swift \
  -o /tmp/benice-style-profile-tests
# StyleExtraction
swiftc -swift-version 6 $R/ModelClient.swift $R/RewriteOptions.swift $R/StyleProfile.swift \
  $R/StyleExtraction.swift mac-app/StyleExtractionTests.swift -o /tmp/benice-style-extraction-tests
# StyleWindow
swiftc -swift-version 6 -parse-as-library $R/ModelClient.swift $R/RewriteOptions.swift \
  $R/StyleProfile.swift $R/StyleExtraction.swift $R/StyleWindow.swift \
  mac-app/StyleWindowTests.swift -o /tmp/benice-style-window-tests
# Preview (no ModelClient)
swiftc -swift-version 6 $R/PreviewWindowController.swift mac-app/PreviewTests.swift \
  -o /tmp/benice-preview-tests
# RewriteOptions
swiftc -swift-version 6 -parse-as-library $R/RewriteOptions.swift \
  mac-app/RewriteOptionsTests.swift -o /tmp/benice-rewrite-options-tests
# RewriteWindow (added after coordinator follow-up "UI tests ready")
swiftc -swift-version 6 -parse-as-library $R/RewriteOptions.swift \
  $R/RewriteWindowController.swift mac-app/RewriteWindowTests.swift \
  -o /tmp/benice-rewrite-window-tests
```

Runs:

| Test | rc | Output |
|---|---|---|
| ModelClient | 0 | `SELFTEST PASS` |
| Settings | 0 | `SELFTEST PASS` |
| WriteBack | 0 | `WriteBackTests PASS` |
| Trigger | 0 | `SELFTEST PASS` |
| StyleProfile | 0 | `StyleProfileTests PASS` |
| StyleExtraction | 0 | `StyleExtractionTests PASS` |
| StyleWindow | 0 | `StyleWindowTests PASS` |
| Preview | 0 | `PreviewTests PASS` |
| RewriteOptions | 0 | `RewriteOptionsTests PASS (valid styles, deduplication, preservation, 29 rejection cases)` |
| RewriteWindow | 0 | `RewriteWindowTests PASS` (`Frame actual == expected: (-1200.0, 0.0, 1200.0, 800.0)`) |

`RewriteOptionsTests` asserts on `assert(...)`, so it must stay a debug build; it was not compiled with `-O`.

`RewriteWindowTests` was initially out of scope (UI worker owned it). A coordinator status message (`msg_fb338d89f2c0`, "UI tests ready") arrived during the run and said to add it now; it is included above and passes. It creates `NSApplication.shared` and an off-screen window at `x=-1200`, which is an AppKit self-check, not GUI automation.

## 4. Standalone probes — typecheck only, not run

Both are script-mode files (`swift mac-app/<file>.swift`), so the meaningful check is the default/Swift 5 language mode.

```sh
swiftc -typecheck mac-app/electron-native-undo-check.swift   # rc=0
swiftc -typecheck mac-app/partial-selection-check.swift      # rc=0
```

Under Swift 6 language mode both fail, and this is a pre-existing limitation, not a regression from this task:

```sh
swiftc -typecheck -swift-version 6 mac-app/electron-native-undo-check.swift   # rc=1, 6 errors
swiftc -typecheck -swift-version 6 mac-app/partial-selection-check.swift      # rc=1, 8 errors
```

Representative error:

```
mac-app/partial-selection-check.swift:70:33: error: main actor-isolated let 'field'
  can not be referenced from a nonisolated context
    note: add '@MainActor' to make global function 'gate' part of global actor 'MainActor'
```

Cause: top-level code in a script is implicitly `@MainActor`, but the helper functions `gate(_:)` and `attribute(_:_:)` are nonisolated, so they cannot read the top-level `field`/`root`/`app` globals. The scripts were never written for Swift 6 strict concurrency. Fix would be `@MainActor` on those helpers (or a `@MainActor` top-level wrapper). Not fixed — out of scope for this dispatch.

## 5. Data-file parsing

All 11 `docs/research/m0-*.json` files parse as strict JSON (`python3 -I -c 'import json; json.load(...)'`, `rc=0` each):

```
m0-chrome-2026-10-24.json          m0-notes-2026-10-24.json
m0-electron-fixtures-2026-10-24.json  m0-runtime-2026-10-23.json
m0-electron-selection-2026-10-24.json m0-safari-2026-10-24.json
m0-electron-undo-2026-10-24.json   m0-textedit-undo-2026-10-23.json
m0-electron-value-2026-10-24.json  m0-textedit-value-2026-10-23.json
m0-vscode-2026-10-24.json
```

`mac-app/Support/Info.plist`:

```sh
plutil -lint mac-app/Support/Info.plist   # "OK", rc=0
python3 -I -c 'import plistlib; plistlib.load(...)'   # rc=0
```

## 6. Whitespace

```sh
git diff --check   # rc=0, no output
```

Diff at check time: 8 files changed, 262 insertions(+), 42 deletions(-) (README/PLAN doc edits only, no Swift source changes).

## Failures to report

1. `mac-app/Sources/axprobe/SelfCheck.swift:133:15` — `warning: will never be executed` on the `SELFTEST FAILED` print. Pre-existing, cosmetic.
2. Both standalone probe scripts fail `swiftc -typecheck -swift-version 6` (6 and 8 actor-isolation errors). Pre-existing; the documented `swift <file>.swift` invocation typechecks and runs clean.

No test, build, parse, or whitespace check failed in the regression batch above.

## Coordinator follow-up, 13:20 AEDT

- Native fixed-text UI harness: screenshot confirmed full-width alternatives; click opened editor; edited two-line text survived Back → Return; visible Close exited normally (exit 0). No AX target writes in this harness.
- Added focused Cancel+Return and 640×480 button bounds tests. Initial style alignment assertion failed because NSTextField frame includes a 2-point alignment inset; corrected to compare alignment edges. Added explicit content trailing margin. `RewriteWindowTests PASS` after correction.
- `WriteBackTests PASS` after prepared-target revalidation and edited replacement assertions. Integrated `swift build --package-path mac-app` passed.
- Edge entry implementation and its independent static review completed; TriggerTests passed. Independent review found focused option Return opening the previously selected option; fixed by invoking the focused button action, with exact regression `RewriteWindowTests PASS`. Final debug bundle rebuilt and signature verified at 13:22.
- Debug app assembled and `codesign --verify --deep --strict` passed. Relaunched process reported `Accessibility: Revoked — re-enable in System Settings`; live Apply/Undo is blocked pending user reauthorization. Existing endpoint/model and Keychain were not replaced.
- Opened a new dedicated TextEdit fixture; it subsequently changed externally, so do not reset, delete, or submit its current content. Create a fresh fixture for resumed testing.
- VoiceOver, IME, real multi-display/Space behavior and the 13-path live matrix remain unverified for the new flow.

## Unattended regression, 20:41 AEDT

User is away; no system authorization or GUI interaction requested. Latest `debug-status.py` returned exit 2 with fresh runtime `accessibilityTrusted: false` for the installed `com.benice.menubar.development` process. Real AX write tests remain blocked, not failed.

Passed again against current sources: SwiftPM build, permission state selftest (8 cases), signing script checks (7 preflight cases, malformed certificate, 5 isolated lifecycle cases plus rerun), WriteBackTests, ModelClientTests, TriggerTests, RewriteOptionsTests (29 rejection cases), and `git diff --check`. These checks use no real document writes, remote model requests or user credential changes. Earlier native UI evidence remains separate from these deterministic checks.
