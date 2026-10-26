# be-nice

> Turns your raw thoughts into messages that make people feel valued. Because someone has to.

A macOS menu-bar app that rewrites the Slack draft you just typed into one to three complete versions (concise, friendly, gentle). You pick one, edit it if you like, confirm, and it replaces your draft. Undo is one visible button away. Nothing is sent for you.

**Status:** in development. The rewrite UI and safe write-back core exist; Slack support is still being verified and is not usable yet. See [STATUS.md](STATUS.md).

- Model access: any OpenAI-compatible endpoint (base URL, API key, model). Local servers work; a remote endpoint receives your draft.
- macOS only. Personal style learning, other apps and Windows are deferred.

Developers and agents: start with [AGENTS.md](AGENTS.md).

## License

TBD (leaning MIT). No model weights are bundled or downloaded.
