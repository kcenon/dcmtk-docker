# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `LICENSE` file (MIT) matching the README license claim.
- `VERSION` stamp and this `CHANGELOG.md` so downstream consumers can pin a known release.
- Conformance / Capabilities table in the README documenting supported vs unsupported DICOM services (DICOMweb, MWL, MPPS, Storage Commitment, TLS, compressed transfer syntaxes).
- Per-service memory and CPU limits in `docker-compose.yml`.
- `scripts/fixture-manifest.sh` — a single source of truth for the synthetic fixture identity (OID root, study/series UIDs, instance counts, patient demographics). The data generator and every test script source it, so the suite can be retargeted at an external / non-DCMTK PACS by overriding `OID_ROOT` without editing any assertion. README documents the external-PACS procedure.
- Modality Worklist (MWL) support: a `worklist` role running `wlmscpfs`, a new `mwl-server` service (AE `DCMTK_WLM`, host port 11115), manifest-driven `.wl` worklist items (`scripts/generate-worklist.sh`) that share patient identity with the Q/R data, and `tests/test-worklist.sh` (`findscu -W`) wired into `test-all.sh` and the CI matrix. MPPS and Storage Commitment remain out of scope (DCMTK ships no such SCP).
- Ad-hoc C-MOVE destinations via `EXTRA_PEERS`: `scripts/inject-extra-peers.sh` injects `name=AE:host:port` peers into the rendered HostTable at startup (defined before the `all_peers` reference), so retrieval to an external listener no longer needs a template edit + rebuild. Added `./pacs.sh add-peer <name> <ae> <host> <port>` (sets `EXTRA_PEERS` and restarts the PACS) and `tests/test-adhoc-peers.sh`. End-to-end delivery to an injected destination is covered by `tests/test-adhoc-cmove.sh` and the `test-adhoc-cmove` CI job (C-MOVE to a destination registered only via `EXTRA_PEERS`, with receiver-side arrival verification).
- TLS profile for secure DICOM transport (opt-in, build-dependent): the `docker-compose.tls.yml` overlay switches the primary PACS to authenticated TLS (`dcmqrscp +tls`), with `scripts/gen-certs.sh` generating a self-signed CA + server + client certificates into a shared volume, and `tests/test-tls.sh` asserting a `+tls` C-ECHO succeeds while plaintext is refused. **Caveat:** the stock Debian apt `dcmtk` package is not linked against OpenSSL (observed during development when `+tls` failed with "Unknown option +tls"), so `+tls` is unavailable on the default image. On the default image the entrypoint refuses to start (exit 1) with a clear error when `TLS_ENABLED=true`, rather than deadlocking or silently downgrading to cleartext; `test-tls.sh` skips when TLS is unavailable. The profile is ready for a TLS-capable (source-built / OpenSSL-linked) dcmtk image. `docs/04_work_plan.md` and `docs/05_usage_guide.md` corrected accordingly. (There is intentionally no TLS-serving CI job; a `test-tls-skip` job asserts the skip path instead.)

### Changed
- Network-facing PACS and receiver services now run as a dedicated non-root user (`pacs`, uid 10001) instead of `root`. The test-client helper (no published ports) stays root so it can write synthetic data into the host-bind-mounted `./data`.
- Synced the README CLI command table and Project Structure tree with the actual `pacs.sh` subcommands and on-disk file layout.

### Fixed
- Aligned the remaining TLS documentation with the build-dependent reality: rewrote the `docs/05_usage_guide.md` TLS section (stock apt dcmtk is not OpenSSL-linked, so `+tls` is unavailable on the default image; it now cross-references `docker-compose.tls.yml` + `scripts/gen-certs.sh` and gates the `+tls` examples), corrected the CHANGELOG "verified in CI" wording (there is no standing TLS-serving CI job), and fixed the README Project Structure counts (5 services / 4 volumes). (#66)
- Standardized shell discipline: `set -euo pipefail` across `entrypoint.sh`, `generate-test-data.sh`, `generate-worklist.sh`, and `wait-for-pacs.sh` (the sourced `fixture-manifest.sh` / `pixel-data-profile.sh` intentionally keep no `set` directive so they do not alter the caller's shell). Renamed the shadowing `TMPDIR` in the data generator to `GEN_TMPDIR`, and stopped suppressing `dump2dcm` stderr so a malformed fixture surfaces a diagnostic. (#65)
- `tests/test-tls.sh` is now exercised in automation: a `test-tls-skip` CI job asserts it skips cleanly (exit 0) on the default cleartext stack, and it is wired into `test-all.sh`, so a regression in its skip guards can no longer go undetected. (#63)
- Ad-hoc C-MOVE delivery to an `EXTRA_PEERS`-injected destination now has a re-runnable in-repo gate: `tests/test-adhoc-cmove.sh` C-MOVEs to a destination registered only via `EXTRA_PEERS` (a fresh AE absent from the static HostTable) and verifies arrival on the receiver, wired into a `test-adhoc-cmove` CI job and into `test-all.sh` (skips when no ad-hoc destination is configured). Replaces the prior out-of-repo "host-verified" note. (#62)
- `scripts/inject-extra-peers.sh` now validates each `EXTRA_PEERS` entry (exactly `name=AE:host:port`, non-empty fields, numeric port) and skips malformed ones with a warning instead of corrupting the rendered config; it also matches an indented `all_peers` line (fixing a silent no-op against the production example) and falls back to `HostTable END` when there is no `all_peers` line. `./pacs.sh add-peer` mirrors the same field validation, and the docstring now describes the real `all_peers` anchor. (#61)
- `tests/test-all.sh` no longer reports "ALL TESTS PASSED" when a suite aborts at the process level (non-zero exit) without emitting `[FAIL]` markers. The aggregator now tracks per-suite exit codes (`SUITES_FAILED`) independently of the parsed `[PASS]`/`[FAIL]` counts, treats a missing suite script as a failure rather than a silent skip, and gates its final verdict on both signals. A new `test-aggregator` CI job runs the aggregator against a fresh stack so its own verdict logic is under test. (#60)
- TLS overlay no longer deadlocks the stack on a non-TLS-capable image. When `TLS_ENABLED=true` but the `dcmqrscp` build lacks `+tls`, the entrypoint now fails fast (`exit 1`) with an explicit error instead of falling through to cleartext while the overlay healthcheck hung on `echoscu +tls` — which previously left `pacs-server` permanently unhealthy and blocked `test-client` from starting (#59).

### Security
- Added `cap_drop: [ALL]` and `security_opt: [no-new-privileges:true]` to the four network-facing services (`pacs-server`, `pacs-server-2`, `storescp-receiver`, `mwl-server`) as defence-in-depth atop the non-root user; the high-port DICOM listeners need no Linux capabilities. A read-only root filesystem is deferred (documented in `docker-compose.yml`) because the entrypoint renders config to `/tmp` and DCMTK tools use temp files. (#64)
- Reduced privilege of the network-facing DICOM services (non-root) and bounded per-container resource usage, lowering blast radius when the stack is wired into a downstream test loop.

## [0.1.0] - 2026-05-30

Initial baseline: DCMTK `dcmqrscp` test PACS exposing C-ECHO / C-STORE / C-FIND / C-MOVE,
a two-PACS topology plus a `storescp` C-MOVE receiver and a test-client SCU container,
deterministic synthetic CT/MR/CR data, an opt-in AE-whitelist restricted profile, and a
scripted DIMSE test suite with receiver-side C-MOVE verification.
