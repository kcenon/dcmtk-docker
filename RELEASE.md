# Release Process

This project uses a three-tier branch model and cuts versioned releases on
`main`. The procedure below keeps `VERSION`, `CHANGELOG.md`, and the git tag in
sync on every release so a downstream consumer pinning a version gets exactly
what the changelog describes.

## Branch model

- **feature branches** (`feat/issue-NN-*`, `fix/issue-NN-*`) — one per issue,
  branched from `develop`.
- **develop** — integration branch; feature branches squash-merge here after CI
  passes.
- **main** — the published default branch; carries tagged releases only.
  Protected; never pushed to directly.

## Cutting a release (`develop` → `main`)

1. Ensure `develop` is green and the issues for the release milestone are closed.
2. **Bump the version**: set `VERSION` to the new `X.Y.Z` (SemVer — MINOR for
   new features, PATCH for fixes).
3. **Roll the changelog**: in `CHANGELOG.md`, rename `## [Unreleased]` to
   `## [X.Y.Z] - YYYY-MM-DD`, add a fresh empty `## [Unreleased]` above it, and
   refresh the compare links at the bottom of the file.
4. Commit the bump on `develop` (e.g. `chore(release): X.Y.Z`).
5. **Promote to `main`**: open a PR from `develop` to `main` (or fast-forward),
   preserving the squash-linear history, and merge it.
6. **Tag** the release commit with an annotated tag:
   ```bash
   git checkout main && git pull
   git tag -a vX.Y.Z -m "Release X.Y.Z"
   git push origin vX.Y.Z
   ```
   `git describe` and downstream pins now resolve to `vX.Y.Z`.

## Invariants

- `main` is protected and must remain so; releases reach it only through a
  reviewed promotion, never a direct push.
- Every release commit on `main` carries `LICENSE`, `VERSION`, and `CHANGELOG.md`
  in sync.
- Squash-merge only; the history stays linear.
- Commit messages, issues, and PRs are in English (documents may be Korean); no
  AI attribution.

> **Protection status:** `main` is protected (enabled 2026-05-31, issue #82).
> A pull request is required before merging (0 required approvals, so a solo
> maintainer is not locked out), force-pushes and branch deletion are forbidden,
> and the full CI matrix is required and must be up to date before merge
> (`strict`): the twelve isolation/aggregator/security checks that the
> `develop`→`main` promotion runs (see #81). Protection is intentionally not
> enforced against admins (`enforce_admins: false`, mirroring `develop`), so the
> owner retains an emergency-merge path. Inspect the live rules with
> `gh api repos/kcenon/dcmtk-docker/branches/main/protection`.

## Verifying after a release

```bash
git show main:VERSION          # the new X.Y.Z
git describe --tags            # vX.Y.Z
git show main:LICENSE | head   # present
```
