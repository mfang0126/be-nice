# be-nice

> Turns your raw thoughts into messages that make people feel valued. Because someone has to.

A local-first macOS text optimizer. Type anywhere — Slack, iMessage, a browser box, anywhere — hit a shortcut (or click the little dot), and your sentence comes back clear, readable, and sounding like you. Not like a corporate memo written by a robot who read one too many LinkedIn posts.

**Why?** Because "per my last email" was never going to make anyone happy.

## What it does

- **Rephrase, don't rewrite.** Fix grammar, make it readable, keep the meaning. Minimal edits, no new facts, no motivational speech at the end.
- **Sounds like you.** Learns your style from your own Slack messages (you paste them in, we don't scrape anything) and keeps your voice.
- **Local-first.** Your messages stay on your machine. Runs a small local model (Qwen3-1.7B class) by default. Bring your own API key if you want.
- **Gets out of the way.** One button, one shortcut, one settings screen. That's it.

## Status

Early. Very early. Check [PLAN.md](./PLAN.md) for where we are.

## Architecture

```
be-nice/
├── engine/          # Core: prompt assembly + model providers (local / remote)
├── adapters/slack/  # Style learning from Slack (manual paste first)
├── mac-app/         # Swift menu bar app (Accessibility read/write + floating dot)
└── docs/research/   # Design reviews, model research, evidence
```

The engine is the product. The Mac app is one shell over it. More shells (Windows, VS Code, browser extension) can come later — the engine is designed to be reused.

## License

TBD (leaning MIT for code; model weights are bundled/downloaded separately under their own licenses — see `docs/research/`).
