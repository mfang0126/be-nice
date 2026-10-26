# mac-app

be-nice macOS menu-bar app (SwiftPM target `benice`, App Sandbox off). Project rules and current stage: [AGENTS.md](../AGENTS.md), [STATUS.md](../STATUS.md).

## Layout

- `Sources/benice/WriteBack.swift` — safe write-back core: target revalidation, one write, bounded independent readback, product Undo, possible-write recovery.
- `OptimizerController.swift` — main flow: capture → model request → Rewrite window → confirmed apply → Undo.
- `RewriteWindowController.swift` / `RewriteOptions.swift` — centered overlay with 1–3 complete rewrites, full-text edit, copy-only mode for stale or complex results.
- `TriggerController.swift` — PID-scoped AXObserver, focused-target capture, screen-edge Rewrite button, ⌃⌥⌘Space shortcut.
- `ModelClient.swift` / `CredentialStore.swift` / `SettingsWindow.swift` — one OpenAI-compatible `/v1/chat/completions` client; base URL and model in UserDefaults, API key in Keychain.
- `SlackDiagnostic.swift` — read-only, content-free Slack focus diagnostic. Slack is **not** in the write allowlist.
- `Style*.swift` — personal-style learning, deferred; compiled but not reachable from the UI.
- `Support/Info.plist` — bundle metadata, applied by `scripts/build-app.sh`.

## Checks (no GUI, network, real Keychain or AX writes)

```sh
sh mac-app/scripts/run-tests.sh            # build + every selftest (Swift and Python)
sh mac-app/scripts/check-dev.sh            # build + permission selftest + signing/status script checks
sh mac-app/scripts/check-dev.sh --runtime  # also reads the running dev app's real Accessibility state
```

`check-dev.sh` exit codes: `0` pass, `1` deterministic failure or stale/unavailable runtime metadata, `2` Accessibility not granted, `64` bad arguments. Passing checks is not product acceptance.

## Development build and signing

```sh
sh mac-app/scripts/setup-dev-signing.sh --setup     # one time; already done on this machine
sh mac-app/scripts/build-app.sh debug --install     # quit the running dev app first
open "$HOME/Applications/be-nice Development.app"
python3 -I mac-app/scripts/debug-status.py          # 0 granted, 2 not granted, 1 unknown
sh mac-app/scripts/configure-dev-model.sh           # dev model = Hermes DeepInfra DeepSeek (key from ~/.hermes/.env)
```

- Fixed identity: bundle ID `com.benice.menubar.development`, path `~/Applications/be-nice Development.app`, one persistent local certificate whose key lives only in the login keychain (codesign access, non-extractable). Never regenerate it: a new identity needs a new Accessibility grant.
- No ad-hoc fallback. `release-local` uses the same development identity; Developer ID signing and notarization are not configured.
- Each build writes `.build/development-designated-requirement.txt`. Identical requirements across rebuilds do not prove TCC retention; only the running app's reported state does. Grant Accessibility to the installed `.app`, not the `.build` copy or `swift run`.
- Never reset TCC, edit TCC.db, or fake permission in DEBUG.

## Slack diagnostic

```sh
python3 -I mac-app/scripts/slack-diagnostic.py
```

Requires the installed dev app running with Accessibility and Slack already frontmost (the diagnostic never activates Slack). It inspects only the focused element and a bounded ancestor chain, reports attribute names and settable flags, and never reads text or chat history. Its output is not write authorization: `contextIdentityVerified` stays false until conversation identity is proven (see STATUS).
