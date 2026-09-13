# README Evidence Policy

The root [README](../../README.md) is the entry page: status, quick start,
requirements, architecture, services, capabilities, the CLI, and links to the
reference pages in [`docs/`](../). It must be nonempty and at most 300 physical
lines, including code, comments, and blank lines. When a README section grows
past one screen (about 50 lines), move it to a `docs/` page and link it. Do not
compress unrelated paragraphs or add filler to meet the limit.

## Local Check

Run from the repository root:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_readme_lint.py'
python3 scripts/readme_lint.py
```

The [standard-library linter](../../scripts/readme_lint.py) checks `README.md` by
default, resolves paths from its own checkout, and accepts explicit file paths
and `--root` for other checkouts or fixtures. Findings use
`path:line: rule: message`. Violations and unreadable files return a nonzero
status. It never uses the network.
[Documentation Audit](../../.github/workflows/doc-audit.yml) runs the tests and
the linter on pull requests that change the README, `VERSION`, `docs/`, the
linter, or a workflow file. `.dockerignore` keeps the linter and its tests out
of the Docker build context, so they never reach the image.

## Status and Release

After the title, and within the first 20 lines, show `Status: active`,
`Status: maintenance`, or `Status: experimental`, and link the release tag. The
status describes project activity, not quality. The linked tag must match
`VERSION`, so the release change that bumps `VERSION` also updates the link
(see [RELEASE.md](../../RELEASE.md)). The linter checks the format and the
`VERSION` match offline; a reviewer checks that the tag exists.

## Badges

Use badges only for workflows in this repository. The image URL and the click
URL must name the same `.yml` or `.yaml` file in `.github/workflows/`, and that
file must exist. Keep license and service links as prose.

## Claims and Density

Remove promotional qualifiers, including production-ready, enterprise-grade,
battle-tested, blazing, world-class, comprehensive, robust, seamless, 100%,
guaranteed, and zero-overhead, zero-warning, zero-leak, or zero-race wording. A
citation does not exempt a banned qualifier. Describe a capability by what the
repository shows, such as the option the entrypoint passes or the test that
exercises it.

The linter recognizes speedup multipliers, latency and throughput units,
percentages, test pass counts, and allocation counts in visible prose.
Measurement tables belong in a `docs/` page, even when sourced. Port numbers,
AE titles, UIDs, versions, dates, list numbers, link destinations, and fenced or
indented code are not measurements.

Density is `100 * distinct prose lines containing a qualifier or measurement /
total physical lines`. The maximum is 1.0 per 100 lines.

A headline figure may stay in the README only with an adjacent marker. The
marker links a `docs/` section that names the environment, date, command, and
raw result:

```markdown
Measured claim. <!-- source: docs/<page>.md#<anchor> (YYYY-MM-DD, <environment>) -->
```

The parser checks marker structure and local links, not whether the measurement
supports the claim. Reviewers check that.

## Provenance

`scripts/readme_lint.py` is a port of the kcenon/common_system README lint at
commit `c2f4037`, with the same rules. The port checks only `README.md` and adds
the `VERSION` check. It keeps the upstream Korean patterns, so later upstream
fixes stay easy to carry over.
