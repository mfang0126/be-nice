# engine

Core of be-nice: prompt assembly + model provider abstraction.

- `providers/` — LocalProvider (llama.cpp + GGUF), RemoteProvider (BYO API key). Local-first; never auto-fallback to remote.
- `prompt/` — style guide + minimal-edit rephrase instructions; original text is data, never instructions.
- `style/` — structured, editable style profile (zh/en, colleague/customer).

Acceptance: minimal edit, no new facts, preserve names/numbers/negation/commitment strength, return original when no change needed.
