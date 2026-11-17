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
   new features, PATCH for fixes), and point the README status line's release
   link at `vX.Y.Z` (`scripts/readme_lint.py` fails while they differ).
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
7. **Re-create `develop` from `main`**: the squash merge in step 5 gives
   `main` a commit that `develop` does not have. If `develop` keeps its old
   history, the next promotion pull request conflicts wherever a later change
   edits lines that this release changed (#130 met 27 conflicting files).
   Right after the tag, before anything else merges into `develop`, point
   `develop` at the new `main` commit:
   ```bash
   git fetch origin
   git diff --quiet origin/main origin/develop   # must exit 0
   git push --force-with-lease=develop:<old develop SHA> origin \
       origin/main:refs/heads/develop
   ```
   If `git diff` reports a difference, do not push: a change reached
   `develop` after the promotion and would be lost. The `develop` protection
   forbids force pushes, so only an admin can run the push (`enforce_admins`
   is false). Record the old `develop` SHA in the promotion pull request;
   after the push it is the only reference to the old history. Rebase open
   pull requests against `develop` onto the new branch. The push run of Test
   Isolation runs every suite, because its base is no longer in the fetched
   history (#134).

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
> maintainer is not locked out), and force-pushes and branch deletion are
> forbidden. Protection is intentionally not enforced against admins
> (`enforce_admins: false`, mirroring `develop`), so the owner retains an
> emergency-merge path.
>
> **Required checks (#135):** `develop` and `main` require the same status
> checks, and a pull request must be up to date before merge (`strict`). They
> are all checks that the Test Isolation and Host tests workflows report, plus
> `GitGuardian Security Checks`. `README lint`
> (Documentation Audit) is not required: it runs only when its paths change,
> and a required check that never reports blocks the merge. Keep both
> protections in step with those two workflows. A new job is not enforced until
> its check is added, and a renamed or removed job blocks every merge until its
> old name is removed. Inspect the live rules with
> `gh api repos/kcenon/dcmtk-docker/branches/<branch>/protection` and compare
> `required_status_checks` with `gh pr checks` on a recent pull request.

## Verifying after a release

The Test Isolation workflow reports its existing check names on every pull
request to `develop` or `main`, including documentation and version-only
changes. A first job classifies the changed paths. Each matrix entry and other
test job still runs, but skips its Docker steps for documentation-only changes.
A failed path decision fails the dependent checks rather than approving a skip.
Unknown paths conservatively run the runtime tests; manual dispatch runs them
all, and so does a push whose previous commit is not in the fetched history,
such as a branch moved to a commit that does not descend from its old tip.
Runtime changes, including `pacs.sh`, `env.default`, `patches/`, and Compose
files, run the usual suites. The check names do not depend on the changed
paths, so all of them can be required without blocking release metadata PRs
(#108).

The classifier's host tests cover documentation, runtime, workflow and mixed
changes, renames, divergent PR bases, push bases missing from the fetched
history, and invalid commits. `actionlint` validates the workflow expressions.
These local checks do not substitute for inspecting the actual GitHub Actions
results on a pull request before merging.

```bash
git show main:VERSION          # the new X.Y.Z
git describe --tags            # vX.Y.Z
git show main:LICENSE | head   # present
git rev-parse origin/main origin/develop   # the same SHA after step 7
```
