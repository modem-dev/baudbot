# slack-bridge/ — Agent Guidelines

Scope: Slack bridge runtime and security modules under `slack-bridge/`.

## Focus areas

- inbound/outbound message handling
- broker pull-mode bridge behavior
- auth/rate-limit/content-security controls

## Rules

- Security behavior changes must be explicit, minimal, and test-backed.
- Do not reduce authentication, validation, or rate-limiting protections without clear rationale.
- Keep operational logging useful but avoid leaking sensitive values.

## Key files

- `broker-bridge.mjs` — main broker pull-mode bridge runtime (preferred)
- `bridge.mjs` — legacy Socket Mode bridge
- `security.mjs` — auth, rate-limiting, content security
- `crypto.mjs` — cryptographic canonicalization for broker signing

## Critical files

Treat as security-critical:
- `security.mjs`
- `security.test.mjs`
- `crypto.mjs`
- `crypto.test.mjs`

## Validation

```bash
npm run lint:js
npm test
```
