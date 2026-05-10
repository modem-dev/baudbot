# Releases

Baudbot uses semantic versioning with the root `package.json` as the canonical product version.

## Canonical version source

- `package.json.version` is the single source of truth for the Baudbot product version.
- Git tags use the form `vX.Y.Z`.
- Runtime metadata records both the semver version and the exact git SHA used to build the release snapshot.

## Semver policy

- **patch**: bug fixes, operational fixes, internal maintenance that changes shipped behavior in a backward-compatible way
- **minor**: new user-facing features, new capabilities, or notable backward-compatible behavior expansion
- **major**: intentional breaking changes

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

## Manual release workflow

Normal PR merges do **not** automatically publish a new version. To cut a release, run the **Release on main** GitHub Actions workflow manually.

Inputs:

- `bump`: `patch`, `minor`, or `major` — used when `exact_version` is empty
- `exact_version`: optional `X.Y.Z` or `vX.Y.Z` override
- `dry_run`: preview mode; when true, no commit, tag, or GitHub Release is created

When publishing, the workflow:

1. checks out `main`
2. computes the target version from `bump` or `exact_version`
3. updates `package.json` and `package-lock.json` when needed
4. commits `release: vX.Y.Z [skip release]` when the package version changed
5. tags `vX.Y.Z`
6. publishes a GitHub Release with merged PR notes since the previous tag

This keeps version timing human-controlled while still making the release mechanics repeatable.

## Operational visibility

User-facing version output should include semver first and SHA second when available, for example:

```text
baudbot 0.2.0 (1a2b3c4)
```

And status output should show the deployed semver plus SHA-backed provenance.
