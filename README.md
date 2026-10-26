# be-nice

> Turns your raw thoughts into messages that make people feel valued. Because someone has to.

A local-first macOS text optimizer. Type anywhere — Slack, iMessage, a browser box, anywhere — hit a shortcut (or click the little dot), and your sentence comes back clear, readable, and sounding like you. Not like a corporate memo written by a robot who read one too many LinkedIn posts.

**Why?** Because "per my last email" was never going to make anyone happy.

## What it does

- **Rephrase, don't rewrite.** Fix grammar, make it readable, keep the meaning. Minimal edits, no new facts, no motivational speech at the end.
- **Sounds like you.** Learns your style from your own Slack messages (you paste them in, we don't scrape anything) and keeps your voice.
- **Choose your endpoint.** One OpenAI-compatible API client is implemented: base URL, API key, and model. Local servers are optional; a remote endpoint sends text to that service. Settings, preview, explicit Apply, and product Undo are connected in the macOS app.
- **Gets out of the way.** One button, one shortcut, one settings screen. That's it.

## Status

M0 has a Swift AX probe, a menu-bar Accessibility-onboarding shell, and runtime evidence for the available TextEdit, Notes, Safari, Chrome, Electron, VS Code, and Terminal targets. Slack was not found in the test environment. These are constrained fixture results, not broad app-support claims. M1 wires OpenAI-compatible settings and Keychain credentials, a floating dot and global shortcut, and preview-first apply/product undo. All currently supported M1 targets passed their real product loops with independent readback and exact restoration: TextEdit selection/whole value, Notes selection/whole value, and input/textarea/contenteditable whole-value paths in Safari, Chrome, and the dedicated Electron fixture; see `docs/research/m1-runtime-2026-10-24.md`.

M2 now has a single-style Extract/Edit/Save flow, a green-dot trigger, and a compact suggestion card below the input. Deterministic app flow and real DeepInfra synthetic requests passed, but the final blind comparison preferred generic rewriting in both cases on semantic/pragmatic fidelity: **M2 is functionally connected, not quality-validated**. The new card has not yet been rerun across the live AX matrix. See `docs/research/m2-runtime-2026-10-25.md`. Unicode/IME, full-screen/multi-display behavior, real third-party Electron apps, and M3 release hardening remain unvalidated or unimplemented. The features above describe the intended product, not unconditional support for every app.

Start a new session or switch models with [HANDOVER.md](./HANDOVER.md). [PLAN.md](./PLAN.md) is the only plan and contains the support matrix; [mac-app/README.md](./mac-app/README.md) contains reproduction commands.

## Architecture

```
be-nice/
├── engine/          # Planned: prompts + OpenAI-compatible API client
├── adapters/slack/  # Style learning from Slack (manual paste first)
├── mac-app/         # Swift menu bar app (Accessibility read/write + floating dot)
└── docs/research/   # Design reviews, model research, evidence
```

This is the intended layout, not a list of implemented modules. v1 targets macOS only; other shells are deferred. Follow PLAN.md for scope.

## License

TBD (leaning MIT for code). The MVP does not bundle or download model weights.
