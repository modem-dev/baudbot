# Contributing to Baudbot

## Setup

```bash
git clone https://github.com/modem-dev/baudbot.git ~/baudbot
npm install
```

## Documentation map

- Product/team workflow overview: [README.md](README.md)
- Deep architecture and operations docs: [`docs/`](docs)
- Security model: [SECURITY.md](SECURITY.md)
- Configuration reference: [CONFIGURATION.md](CONFIGURATION.md)

## Running Tests

```bash
# All tests (10 suites)
bin/test.sh

# JS/TS only
bin/test.sh js

# Shell only
bin/test.sh shell

# Lint + typecheck
npm run lint && npm run typecheck
```

## Branches and PRs

- Don't commit directly to `main`. Open a PR from a feature branch.
- Branch names: `<your-gh-username>/<description>` (e.g. `youruser/fix-firewall-rules`)
- Commit messages: prefix with area. Examples: `security: add rate limiting`, `bridge: fix reconnect`, `docs: update README`
- One branch per change. Keep PRs focused.

## Code Conventions

- Scripts must work on both Ubuntu and Arch Linux. Use POSIX tools, `grep -E` (not `grep -P`), and avoid distro-specific package manager calls.
- Security functions must be pure, testable modules with no side effects or env vars at module scope.
- All security code needs tests before merging.
- New integrations get their own subdirectory (e.g. `discord-bridge/`).

## Security Changes

If your change touches security code (`tool-guard.ts`, `security.mjs`, firewall scripts, etc.):

1. Add or update tests.
2. Run `bin/security-audit.sh --deep` and confirm it passes.
3. Note the security implications in your PR description.

See [SECURITY.md](SECURITY.md) for the threat model and architecture.

## Reporting Bugs

Open a GitHub issue. Include:

- What you did
- What you expected
- What happened instead
- OS and version (Ubuntu/Arch/other)

## Security Vulnerabilities

Do **not** open a public issue for security vulnerabilities. See [SECURITY.md](SECURITY.md) for reporting instructions.
