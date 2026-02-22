# bin/ — Agent Guidelines

Scope: shell CLI and operational scripts under `bin/`.

## Focus areas

- CLI entrypoint (`baudbot`) and runtime helpers
- deploy/update/rollback flows
- security audit and firewall scripts
- install/uninstall operational scripts
- CI infrastructure (`bin/ci/`)
- JS tooling: `broker-register.mjs`, `scan-extensions.mjs` (and their tests)
- systemd unit files: `baudbot.service`, `baudbot-firewall.service`

## Rules

- Keep CLIs thin; move reusable logic into `bin/lib/*.sh`.
- Reuse shared helpers (`shell-common.sh`, `paths-common.sh`, `release-common.sh`, etc.) instead of duplicating constants or logging/error patterns.
- Prefer portable shell patterns; distro-specific branches are acceptable when reliability improves.
- Any security-relevant shell change must include/adjust tests.

## Critical files

Treat as security-critical:
- `baudbot-safe-bash` — runtime command-blocking wrapper
- `harden-permissions.sh` — filesystem permission lockdown
- `setup-firewall.sh` — network egress lockdown
- `security-audit.sh` — security posture audit
- `scan-extensions.mjs` — static analysis scanner for extensions
- `redact-logs.sh` — secret redaction from session logs

## Notes

- Shared helpers in `bin/lib/` have co-located test files (e.g. `deploy-common.test.sh`, `json-common.test.sh`). Update tests when changing helpers.
- For JS files in `bin/`, also run `npm run lint:js` and `npm run test:js`.

## Validation

Run before finishing shell work:

```bash
npm run lint:shell
npm run test:shell
```

For security-sensitive updates, also run:

```bash
bin/security-audit.sh --deep
```
