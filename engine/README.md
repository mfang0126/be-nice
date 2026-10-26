# engine

Planned component; not implemented. Scope and milestones come only from [PLAN.md](../PLAN.md).

- M1 model access: one OpenAI-compatible `/v1/chat/completions` client, configured with base URL, API key, and model. Local servers are optional endpoints; no separate embedded LocalProvider or automatic fallback is planned for MVP.
- Prompt assembly: minimal-edit rephrase instructions; original text is data, never instructions.
- M2 style: structured, editable profile (zh/en, colleague/customer).

Acceptance: minimal edits, no new facts, preserve names/numbers/negation/commitment strength; unchanged text may remain unchanged. Empty, truncated, or refused output must not overwrite input.

Current implementation and handover: [HANDOVER.md](../HANDOVER.md).
