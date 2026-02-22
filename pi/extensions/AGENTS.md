# pi/extensions/ — Agent Guidelines

Scope: extension code under `pi/extensions/`.

## Focus areas

- Tool extensions and runtime behaviors
- Session-control and orchestration helpers
- Safety/policy logic and stateful agent features

## Rules

- Keep extension behavior deterministic and testable.
- Avoid module-scope side effects for security-sensitive code.
- Preserve compatibility with deployed runtime assumptions (`~/.pi/agent/...`).
- If changing extension behavior, update related skill/docs references where relevant.

## Subdirectory extensions

Some extensions have their own package scope:
- `kernel/` — on-kernel cloud browser execution (has own `package.json`)
- `agentmail/` — email integration (has own `package.json`)
- `email-monitor/` — email monitoring

## Critical files

Treat these as security-critical and require strong justification + tests:
- `tool-guard.ts`
- `tool-guard.test.mjs`

## Validation

```bash
npm run lint:js
npm run test:js
```
