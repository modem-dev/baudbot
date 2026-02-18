# Persistent Memory

Baudbot uses file-based memory so context survives session restarts and knowledge compounds at the team level.

## Memory location

Memory files live in the deployed runtime under:

```text
~/.pi/agent/memory/
```

Typical files:

- `operational.md` — infra learnings and recurring fixes
- `repos.md` — per-repo build/CI quirks and notes
- `users.md` — collaboration preferences and communication style
- `incidents.md` — prior incidents, root cause, and resolution

## Why it matters

Persistent memory lets the system improve over time:

- fewer repeated mistakes
- faster triage for recurring failures
- better continuity across restarts or model/session swaps

## Operating rules

- Read memory on startup before executing new work.
- Append new learnings with dated entries.
- Keep entries concrete and action-oriented.
- Never store secrets, API keys, tokens, or private credentials.

## Entry format (example)

```markdown
## 2026-02-18
- Repo: myapp
- Finding: integration tests fail unless REDIS_URL is set explicitly in CI.
- Fix: export REDIS_URL=redis://127.0.0.1:6379 before running test:integration.
```

## What belongs in memory vs git docs

Use memory for:

- runtime observations
- team preferences
- temporary but useful operational context

Use repository docs/commits for:

- canonical architecture
- long-term implementation docs
- user-facing product behavior changes

## Maintenance

- prune stale or duplicated notes periodically
- keep headings consistent for scanability
- consolidate repeated points into single authoritative entries

For role behavior around memory usage, see [agents.md](agents.md).
