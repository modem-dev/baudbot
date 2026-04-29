# Releases

Baudbot uses semantic versioning with the root `package.json` as the canonical product version.

## Canonical version source

- `package.json.version` is the single source of truth for the Baudbot product version.
- Git tags use the form `vX.Y.Z`.
- Runtime metadata records both the semver version and the exact git SHA used to build the release snapshot.

## Semver policy

- **patch**: bug fixes, operational fixes, internal maintenance that changes shipped behavior in a backward-compatible way
- **minor**: new user-facing features, new capabilities, or notable backward-compatible behavior expansion
- **major**: reserved for intentional breaking changes and handled manually

## Release model

Baudbot production releases remain git-free immutable snapshots under `/opt/baudbot/releases/<sha>`.

That SHA-based layout is preserved for:
- immutability
- fast rollback
- exact provenance

Human-facing tooling should prefer semver, while deployment internals continue to rely on SHAs.

Each release snapshot includes `baudbot-release.json` with:
- `version`
- `tag`
- `sha`
- `short`
- `branch`
- `source_repo`
- `built_at`
- `built_by`

The deployed runtime mirrors this in `~/.pi/agent/baudbot-version.json`.

## Automation

The `release-on-main` workflow:
- inspects merged PRs since the last release tag
- decides `none`, `patch`, or `minor`
- bumps `package.json.version`
- updates `package-lock.json`
- creates a release commit
- creates tag `vX.Y.Z`
- publishes a GitHub Release

Major version bumps are manual-only.

## Operational visibility

User-facing version output should include semver first and SHA second when available, for example:

```text
baudbot 0.2.0 (1a2b3c4)
```

And status output should show the deployed semver plus SHA-backed provenance.
