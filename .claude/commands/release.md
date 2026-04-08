# Release

Release a new version of claudeship. The user must supply an explicit semver version as `$ARGUMENTS`.

## Steps

### 1. Validate version argument

If `$ARGUMENTS` is empty or does not match `X.Y.Z` format, tell the user: "Usage: `/release <version>` (e.g. `/release 0.0.4`)" and stop.

Set `VERSION` to the provided argument (strip any leading `v` if present).

### 2. Check current state

Run `bash scripts/bump-version.sh --check` to show current versions and detect drift. If there is drift, warn the user and ask whether to proceed.

Run `git status --short` to check for uncommitted changes. If there are uncommitted changes, warn the user: "There are uncommitted changes. Please commit or stash them before releasing." and stop.

### 3. Run tests

Run the test suite:

```bash
cd plugins/claudeship && uv run pytest
cd plugins/claudeship && uv run ruff check
```

If any tests or lint checks fail, report the failures and stop. Do not proceed with a broken release.

### 4. Bump versions

Run `bash scripts/bump-version.sh $VERSION` to bump all declared files.

### 5. Ask for confirmation

Show the user a summary of what will happen:

- Version: `$VERSION`
- Files changed (show the `git diff --stat` output)
- Commit message: `release v$VERSION`
- Tag: `v$VERSION`
- Push: commit + tag to origin (triggers CI to build notifier + update cask)

Ask: **"Ready to commit, tag, and push v$VERSION?"** Wait for explicit confirmation before proceeding. If the user declines, run `git checkout -- .` to revert the version bumps and stop.

### 6. Commit, tag, and push

```bash
git add -A
git commit -m "release v$VERSION"
git tag "v$VERSION"
git push && git push --tags
```

Report success with the version and a note that CI will handle the notifier build and cask update.
