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
- **Never call `node`, `npm`, or other runtime binaries by bare name** in scripts that run as root or outside the agent user's shell. These binaries live in the agent's embedded runtime (`/home/baudbot_agent/opt/node/bin/`) and are not on root's PATH. Use `runtime-node.sh` helpers (e.g. `bb_resolve_runtime_node_bin`, `bb_resolve_runtime_node_bin_dir`) to resolve the full path, then invoke via a variable. Fall back to bare name only as a last resort.

  ```bash
  # ✅ Good: resolve then invoke
  source "$SCRIPT_DIR/lib/runtime-node.sh"
  node_bin_dir="$(bb_resolve_runtime_node_bin_dir "$agent_home")"
  "$node_bin_dir/npm" ci --omit=dev

  # ❌ Bad: bare name breaks when not on PATH
  npm ci --omit=dev
  ```

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
