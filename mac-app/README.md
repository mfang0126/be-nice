# mac-app

For current progress and model/session handoff, start with [HANDOVER.md](../HANDOVER.md).

M0 provides a standalone Swift AX probe CLI plus the menu-bar permission shell. M1 adds native settings, OpenAI-compatible model access, a floating dot/global shortcut, and preview-first apply/product undo. App Sandbox is off. A model response is never applied without an explicit Apply action; unsupported apps and insecure targets are excluded by an allow-list.

- `Sources/axprobe` — M0 cross-app read/write probe (fixed test text, no LLM).
- `Sources/benice` — menu-bar shell, settings/Keychain, model client, trigger controller, preview UI, and safe write-back state machine.
- `WriteBack.swift` — preview/apply/undo transactions, target revalidation, bounded read-back, and possible-write recovery.
- `TriggerController.swift` — nonactivating NSPanel dot, PID-scoped AXObserver, and ⌃⌥⌘Space global shortcut (M1).

The package's macOS 13 deployment target is a build setting, not a tested support claim; the current runtime record covers macOS 26.6.2 only.

Build and check the M0 CLI from the repository root:

```sh
swift build --package-path mac-app
mac-app/.build/debug/axprobe selftest
mac-app/.build/debug/axprobe check
mac-app/.build/debug/axprobe target --app TextEdit --json
```

The default target command is read-only. For write tests, create a disposable plain-text field containing exactly `be-nice M0 fixture: hello world.`, focus it in the foreground app, then run:

```sh
mac-app/.build/debug/axprobe target --app TextEdit --allow-write --value-only --json
```

The CLI does not activate the target app. Launch the command from a background driver while the disposable field remains focused; switching to a terminal to run it makes the target fail the foreground check.

Write verification polls old values for up to a 500 ms observation window without repeating the write. An unchanged value at the deadline is FAIL/UNCONFIRMED, not proof of a permanent no-op; a late effect remains possible. Each AX read may additionally take its messaging timeout.

Exit 0 means the report completed, including blocked/skipped results; inspect each capability. Exit 1 means a setup/discovery error, 2 invalid arguments, and 4 a reported failure.

Known M0 limits: a partial/unrecognized write is left in place and reported FAIL; inspect the disposable field manually. If restoring the value causes the app to reset its selection, the probe may conservatively refuse selection restoration and report FAIL. Do not treat either outcome as a clean successful write. Terminal exclusion covers named bundles only, not every terminal app or embedded terminal. Global clipboard changes may come from another app. TextEdit and Notes passed their fixed-fixture whole-value and selected-text paths, restoration, and one externally driven native undo each. Electron 33.4.11 whole-value writes/restoration passed, but selected-text writes remained unconfirmed and AXValue was not restored by one native Cmd-Z in any of the three controls. Safari/Chrome whole-value writes passed; their selected-text writes remained unconfirmed. Safari contenteditable did not expose AXSelectedText. VS Code's whole-value and selected-text setters returned success without confirmed effect, so it is not currently a writable supported target. Slack was not found in the test environment. See PLAN.md for exact per-control limits.

Never use an existing document or message draft. A write test temporarily changes text and can affect the app's undo history even when the original value is restored. `undo` stays `SKIPPED` until separately exercised; successful AX restoration does not prove native Cmd-Z support. Position currently measures selection-range setting, not overlay geometry. Do not interpret a result from an application/window element as a text-control capability.

The standalone `swift mac-app/partial-selection-check.swift [TextEdit|Notes|Code]` checks the ASCII `hello` → `HELLO` replacement at UTF-16 range `(20,5)`. TextEdit requires the dedicated unsaved `Untitled 2`; Code requires the exact `be-nice-m0-vscode-fixture.txt` window and `/tmp/be-nice-m0-vscode-fixture.txt` document. Notes only checks the `All iCloud` window prefix plus exact fixture: the script cannot prove that the current note is disposable, so the operator must create and identify a dedicated note before running it. It leaves a verified replacement for an external Cmd-Z and does not automate undo. TextEdit and Notes passed the local replacement and independently read-back undo; VS Code's setter did not produce a confirmed replacement.

## Menu-bar shell

Build and self-check without launching the GUI:

```sh
swift build --package-path mac-app
mac-app/.build/debug/benice --selftest
```

`--selftest` exercises only the permission state machine (never-granted / granted / revoked / re-granted) and exits; it does not create an `NSApplication` or touch TCC, so it is safe on a locked desktop.

Development builds use one persistent local signing certificate, bundle ID `com.benice.menubar.development`, and installed path `~/Applications/be-nice Development.app`. Review the setup script before the one-time machine change:

```sh
sh mac-app/scripts/setup-dev-signing.sh --setup
sh mac-app/scripts/build-app.sh debug --install
open "$HOME/Applications/be-nice Development.app"
```

Setup creates an RSA key and self-signed code-signing certificate under `~/Library/Application Support/be-nice/dev-signing` (directory 700, files 600), imports the key as non-extractable into the login keychain with access limited to `/usr/bin/codesign`, and adds **current-user, code-signing-only** certificate trust. The temporary private-key file is unencrypted: no custom key password is needed; macOS may still request keychain or trust authorization. Setup deletes that file only after finding the valid identity and successfully signing and verifying a disposable executable. Thereafter the private key persists only in the login keychain; keep the certificate file persistent, and rerunning setup with that valid identity needs no PEM key. Losing the keychain identity requires deliberate recovery or a new identity and Accessibility grant; there is no portable private-key backup. Failed setup retains any private-key material for manual inspection, never automatically regenerates an established identity, and refuses automatic re-import of an incomplete setup. No administrator privileges, broad key ACL, keychain search-list changes, TCC database edits/reset, or SIP changes are used.

`sh mac-app/scripts/build-app.sh debug` builds without installation. `release-local` builds an optimized app with the **same local development identity**, not a distribution release; bare `release` is rejected. Developer ID signing/notarization is not configured. Both modes fail before compilation when the pinned certificate or valid signing identity is unavailable, with no ad-hoc fallback. Quit the installed app before `--install`; an existing destination must have the development bundle ID, and its previous bundle is retained in a printed backup path until you remove it after validation.

The build verifies its signature and writes `mac-app/.build/development-designated-requirement.txt`. For acceptance, save this record, change/rebuild the executable, install again, and compare the two records. They must pin the same bundle identifier and certificate leaf hash. Grant Accessibility to the installed app once, then confirm the **running app's** permission state after each rebuild; an unchanged designated requirement alone does not prove TCC retention. The initial transition from the old bundle ID/ad-hoc identity can require a fresh grant. Do not launch the `.build` copy for this check.

Unified unattended checks:

```sh
sh mac-app/scripts/check-dev.sh            # build + permission selftest + signing/diagnostic regressions
sh mac-app/scripts/check-dev.sh --runtime  # also inspect the installed running app
python3 -I mac-app/scripts/debug-status.py # runtime metadata only
```

Exit codes: `0` passed; `1` deterministic failure or unavailable/stale runtime metadata; `2` runtime blocked by missing Accessibility; `64` invalid runner arguments. These commands do not install, change permissions, access real credentials, or perform AX writes. This is a development preflight, not the complete product test suite or live Apply/Undo acceptance. Runtime status requires a fresh record matching the installed development app PID and executable path.

Safe signing-script checks (no certificates, keychain changes, builds, or installation):

```sh
python3 -I mac-app/scripts/check-signing.py
```

Local reference: `man security` documents `import -x -T`, `add-trusted-cert -r trustRoot -p codeSign` (default user domain), and `find-identity -v -p codesigning`; `man codesign` documents certificate-hash identity selection and explicit designated requirements. Certificate import, actual signing, installation and identical designated requirements across changed-source rebuilds passed on 2026-10-25. Accessibility retention across rebuilds remains unverified because the new development identity has not yet received its first grant.

Menu contents: permission status (Granted / Not granted / Revoked), `Request Accessibility Access…` (system prompt via `AXIsProcessTrustedWithOptions`), `Open Accessibility Settings…`, `Check Again`, shortcut availability, `Settings…`, and Quit. The state is rechecked asynchronously every 2 s and when the app becomes active. Losing access after it was granted shows `Accessibility: Revoked — re-enable in System Settings` plus a warning-triangle status icon; the "granted once" fact is persisted in `UserDefaults` so revocation stays visible after relaunch. Polling exists because macOS has no TCC-change notification for Accessibility.

Integration notes: running the raw SwiftPM executable (`swift run benice`) works for logic checks but TCC attributes it differently than the installed bundle, so grant permission against the installed development `.app`. `Support/Info.plist` is intentionally outside the SwiftPM target path; the builder sets development metadata only in its staged copy.

## Model client checks

`Sources/benice/ModelClient.swift` implements the single OpenAI-compatible `/v1/chat/completions` protocol; `CredentialStore.swift` stores the API key as a Keychain generic password. The M1 optimizer flow uses them through Settings and preview/apply/undo. Run deterministic client tests without network or real Keychain access:

```sh
swiftc -swift-version 6 mac-app/Sources/benice/ModelClient.swift mac-app/Sources/benice/RewriteOptions.swift \
  mac-app/ModelClientTests.swift -o /tmp/benice-model-tests
/tmp/benice-model-tests
```

Remote HTTP and malformed base URLs are rejected; plaintext HTTP is limited to loopback. Tests use stubbed URL loading and do not need a real API key.

## M2 single-style and suggestion-card checks

M2 deliberately uses **one shared style guide**, not separate language/audience profiles. Settings opens a compact Personal Style window: paste transient samples, explicitly Extract, review one editable field, then Save. Raw samples are never persisted. The same `ModelClient` completion path handles extraction and optimization; the privacy disclosure refreshes from the current endpoint immediately before extraction. A nonblank guide is a separate user message below the fixed system rules and before the untouched original text. Guides are limited to 4,000 characters and delimiter injection is rejected at extraction and Save; blank or invalid saves preserve the saved guide and samples.

The current Rewrite flow replaces the compact suggestion card with a screen-covering window: original text, 1–3 complete style alternatives, then an editable full-text confirmation. Closing and returning preserve the latest recovery transaction. The new window has passed deterministic AppKit checks and a fixed-text GUI smoke check; the complete cross-app Apply/Undo matrix must still be rerun for this flow. `PreviewTests` and the earlier card runtime results remain historical evidence.

The real app passed deterministic-stub Extract → edit → Save with independent preference readback and sample clearing. DeepInfra `deepseek-ai/DeepSeek-V4.1-Flash` also completed synthetic-only extraction and held-out generic/personalized rewrites; this sends those fixtures to the remote provider and uses no real Slack content. **The blind evaluation did not pass**: generic output won both final cases on semantic/pragmatic fidelity, so M2 is functionally connected but not quality-validated. See [M2 validation](../docs/research/m2-runtime-2026-10-25.md).

```sh
swiftc -swift-version 6 mac-app/Sources/benice/StyleProfile.swift \
  mac-app/StyleProfileTests.swift -o /tmp/benice-style-profile-tests
/tmp/benice-style-profile-tests

swiftc -swift-version 6 mac-app/Sources/benice/ModelClient.swift mac-app/Sources/benice/RewriteOptions.swift \
  mac-app/Sources/benice/StyleProfile.swift mac-app/Sources/benice/StyleExtraction.swift \
  mac-app/StyleExtractionTests.swift -o /tmp/benice-style-extraction-tests
/tmp/benice-style-extraction-tests

swiftc -swift-version 6 -parse-as-library mac-app/Sources/benice/ModelClient.swift mac-app/Sources/benice/RewriteOptions.swift \
  mac-app/Sources/benice/StyleProfile.swift mac-app/Sources/benice/StyleExtraction.swift \
  mac-app/Sources/benice/StyleWindow.swift mac-app/StyleWindowTests.swift \
  -o /tmp/benice-style-window-tests
/tmp/benice-style-window-tests

swiftc -swift-version 6 mac-app/Sources/benice/PreviewWindowController.swift \
  mac-app/PreviewTests.swift -o /tmp/benice-preview-tests
/tmp/benice-preview-tests
```

## M1 flow and checks

Settings persists only base URL/model in `UserDefaults`; the API key stays in Keychain and is never loaded into the settings field. The floating dot appears only for the current support policy: TextEdit/Notes text controls, or text controls inside a web area in Safari/Chrome/the dedicated Electron fixture. Browser address bars, VS Code, Terminal, Slack, unknown apps, secure fields, and Secure Input are excluded. The Electron fixture must also have the exact focused-window title `be-nice AX test target`; capture, Apply, and Undo enforce this before reading or writing. The global shortcut is ⌃⌥⌘Space; the menu reports registration failure instead of silently doing nothing.

A trigger captures the target, requests one suggestion, and shows a preview. Apply rechecks PID, bundle, element identity, original text and (for selection mode) selection, then reselects and verifies the captured range immediately before one write. Undo is a product write of the captured original, not synthesized Cmd-Z. Possible writes retain a recovery record; a third current value refuses undo rather than overwriting later edits. Closing or retriggering preserves the last Undo record; Apply/Undo-busy flows cannot be closed or superseded. Browser targets always use whole-value mode because SelectedText was not confirmed in M0. Real Electron apps other than the fixture remain unsupported.

```sh
swiftc -swift-version 6 -parse-as-library \
  mac-app/Sources/benice/WriteBack.swift mac-app/Sources/benice/ModelClient.swift mac-app/Sources/benice/RewriteOptions.swift \
  mac-app/WriteBackTests.swift -o /tmp/benice-writeback-tests
/tmp/benice-writeback-tests

swiftc -swift-version 6 -parse-as-library \
  mac-app/Sources/benice/TriggerController.swift mac-app/TriggerTests.swift \
  -o /tmp/benice-trigger-tests
/tmp/benice-trigger-tests

swiftc -swift-version 6 -parse-as-library \
  mac-app/Sources/benice/CredentialStore.swift mac-app/Sources/benice/ModelClient.swift mac-app/Sources/benice/RewriteOptions.swift \
  mac-app/Sources/benice/SettingsWindow.swift mac-app/SettingsTests.swift \
  -o /tmp/benice-settings-tests
/tmp/benice-settings-tests
```

These tests use fakes: no live AX writes, real Keychain, or network. Deterministic-stub runs passed TextEdit selection/whole-value, Notes selection/whole-value, and Safari/Chrome/dedicated-Electron input/textarea/contenteditable whole-value preview/apply/undo loops with independent readback and exact restoration; these runs verified the product flow, not model quality. See [M1 runtime validation](../docs/research/m1-runtime-2026-10-24.md). Fixed-fixture results do not cover Unicode/IME, full-screen/multi-display behavior, or real third-party Electron apps.

Runtime evidence: [M0 2026-10-23](../docs/research/m0-runtime-2026-10-23.md), [M0 2026-10-24](../docs/research/m0-runtime-2026-10-24.md), and [M1 2026-10-24](../docs/research/m1-runtime-2026-10-24.md). The support matrix in `PLAN.md` is the acceptance source; untested or environment-blocked entries are not support claims.
