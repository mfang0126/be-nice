# Slack desktop MVP

Slack macOS desktop is the current MVP target. This directory does not yet contain an adapter; existing native integration lives under `mac-app/Sources` and remains gated pending capability evidence. [PLAN.md](../../PLAN.md) is the only execution plan; [HANDOVER.md](../../HANDOVER.md) records current progress.

On 2026-10-25 the installed Slack version is **4.52.182**, bundle ID `com.tinyspeck.slackmacgap`. Installation is not evidence of AX write support. S0 must verify a dedicated synthetic draft: capture, exact editor identity, focus restoration, one write, independent readback and exact recovery. Product support must not be enabled merely to run a probe.

No message sending, scraping, login or Slack API integration is required. Never use an existing draft as a fixture. Deliver the direct-message trial first: ordinary Chinese/English whole drafts must complete generation, editing, explicit replacement and Undo in real Slack without a terminal or manual copy/paste. Validate channel and thread composers afterward. Chinese IME, multiline text, mentions, links and lists require explicit evidence. If structured content cannot safely survive replacement, preserve the original and offer preview/copy with an explanation; this does not count as successful direct replacement. Stale results remain viewable/copyable but cannot replace a changed draft or conversation.

## Read-only diagnostic preparation

A content-free diagnostic is implemented in `SlackDiagnostic.swift` and invoked explicitly through the stable Development app using:

```sh
python3 -I mac-app/scripts/slack-diagnostic.py
```

The latest signed diagnostic build was installed at the fixed development path and launched at 21:34 on 2026-10-25; host Accessibility permission was false then. Recheck current status before use. The CLI requires fresh host status and actual Accessibility permission. Slack must already be foreground; the diagnostic never activates it. It examines only the focused element and a bounded ancestor chain, exports fixed metadata vocabularies and attribute settable flags, and never reads text values or enumerates chat history. `contextIdentityVerified` remains false: this survey is not write authorization or proof of channel/thread identity.

Pure checks:

```sh
swiftc -swift-version 6 mac-app/Sources/benice/SlackDiagnostic.swift mac-app/SlackDiagnosticTests.swift -o /tmp/benice-slack-diagnostic-tests
/tmp/benice-slack-diagnostic-tests
python3 -I mac-app/scripts/check-slack-diagnostic.py
```

Independent review identified partial request publication and main-thread AX blocking; both were fixed with atomic exclusive publication and detached AX collection. Live Slack inspection is still untested.

The first trial uses three built-in rewrite directions while preserving the original language and meaning. Personal-style learning is deferred from its main flow and acceptance. A foreground test period has been agreed in principle but has not been scheduled; do not activate Slack or enter test input until that period is explicitly handed over.