# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-11-17

### Added
- C-GET verification: `tests/test-get.sh` (`./pacs.sh test get`) retrieves the CT, MR and CR fixture studies with `getscu`, requires a final DICOM Success and the exact instance counts (5/6/2), and compares instance UIDs, metadata and full PixelData with the fixture manifests. A success response without delivered files fails. (#107)
- Opt-in lossless compressed transfer syntaxes: `DICOM_TRANSFER_SYNTAX` (`uncompressed`, `jpeg-lossless`, `jpeg-ls-lossless`, `rle-lossless`) sets the incoming preference, with the uncompressed syntaxes as fallback, and `DICOM_MOVE_TRANSFER_SYNTAX` sets the outgoing C-MOVE preference. Both default to `uncompressed`. DCMTK 3.6.9 does not transcode, so a C-MOVE works only when the stored encoding matches the outgoing preference. (#113)
- `tests/test-concurrent-store.sh` (`./pacs.sh test concurrent-store`) stores in parallel to both PACS servers and verifies the UID, metadata and PixelData of every instance. CI also checks the stored data after a restart, a recreation and an idle SIGKILL. (#115)
- `tests/test-tls-runtime.sh` checks authenticated TLS C-ECHO and C-STORE against a temporary TLS `storescp` in the test client, compares the stored instance and its PixelData, and requires plaintext to be refused. It needs no PACS overlay. (#114)
- `PACS_BIND_ADDR` sets the host interface of the published ports (default `0.0.0.0`, as before). (#87)
- Reference pages `docs/07_dicom_operations.md` to `docs/12_development.md`, and a README lint (`scripts/readme_lint.py`, Documentation Audit workflow) that checks the README against `docs/contributing/README_POLICY.md` and its release link against `VERSION`. (#100)
- Host tests workflow that runs the Python tests in `scripts/tests` on pull requests and pushes to `develop` and `main`. (#116)
- `tests/test-generator-reuse.sh` checks when the data generator reuses or rewrites its output. (#138)
- CI runs the restricted-mode suite, and `tests/test-all.sh` includes the transfer-syntax and load-smoke suites. (#84)

### Changed
- The image is built on `debian:trixie-slim` with DCMTK 3.6.9, pinned by digest (was `debian:bookworm-slim` with DCMTK 3.6.7). The `dcmtk` package accepts Debian `3.6.9-*` revisions by default, `--build-arg DCMTK_PACKAGE_VERSION=...` selects an exact one, and the installed version is written to `/usr/share/doc/dcmtk/package-version.txt`. (#90, #112)
- `dcmqrscp` is rebuilt from the matching Debian source package with `patches/atomic-store-filenames.patch`. The other DCMTK tools are the distribution binaries. (#115)
- The TLS overlay (`docker-compose.tls.yml`) now serves authenticated TLS on the primary PACS. With `TLS_ENABLED=true`, `tests/test-tls.sh` fails on missing TLS support or credentials instead of skipping. Outgoing C-MOVE from the PACS stays cleartext; `movescu` and `wlmscpfs` have no TLS options in this image. (#112)
- `DICOM_PORT` is the internal port of all four SCPs, their healthchecks, the peer templates, the worklist and the test client, in both overlays. The host ports stay separate. (#110)
- `tests/test-load-smoke.sh` requires every store and query to succeed and compares exact SOP Instance UIDs, metadata and PixelData manifests. Aggregate counts alone no longer pass. (#117)
- The README is a short entry page. Its reference sections moved to `docs/07` to `docs/12` with their text kept. (#100)
- The data generator checks only its own `ct/`, `mr/` and `cr/` output. It reuses that output when each folder holds the manifest count of files and the first instance of each modality matches the current settings (SOP Instance UID, PixelData present or absent, Rows and Columns); otherwise it rewrites the files. Other files under `data/` are kept. (#138)
- `pacs-server` has a healthcheck `start_period` of 180s, so the realistic PixelData profile can finish generating before failed checks count. (#138)
- The test client reports healthy only after its fixture generation finishes. (#115)
- Test Isolation reports every check on every pull request: a first job classifies the changed paths, and documentation-only changes skip the Docker steps (#108). A push whose previous commit is not in the fetched history runs every suite (#134). RELEASE.md records the `main` protection and the checks that `develop` and `main` require (#82, #135).

### Fixed
- Concurrent C-STORE associations could choose the same filename and overwrite another instance. Filenames are now reserved atomically. (#115)
- `./pacs.sh test` ignored the documented `LOAD_SMOKE_*` host settings. It now forwards them. (#116)
- `./pacs.sh up`, `reset` and `add-peer` recreated services from `docker-compose.yml` alone, so a TLS stack restarted in cleartext and a restricted stack lost its whitelist. They now keep the compose files the stack was started with. (#136)
- Generated CT files carried RescaleIntercept -1024 on top of stored Hounsfield values, so viewers showed every band 1024 HU too low. The intercept is now 0. Existing `data/ct` output from an earlier version is reused as it is; run `./pacs.sh clean-data` to have it regenerated. (#137)
- The C-FIND tests count matches from the DIMSE responses (#131) and filter by series `Modality`, because `dcmqrscp` ignores `ModalitiesInStudy` (#132). The transfer syntax tests check the negotiated syntax instead of the exit code (#133).
- Restricted mode: the test script no longer dies on an undefined `err`, the overlay healthchecks no longer depend on the AE whitelist, and the whitelisted containers' names match the HostTable. The transfer syntax test no longer uses the nonexistent `+xs` flag. (#84)
- `run_test_expect_fail` runs its command once instead of twice. (#88)
- `gen-certs.sh` regenerates a certificate whose key is missing, `inject-extra-peers.sh` skips out-of-range ports and duplicate names, the service status table aligns in a terminal, and `wait-for-pacs.sh` shows the last `echoscu` error. (#89)
- The README lint no longer reports image dimensions as unsourced speedup claims. (#109)
- Documentation: TLS fail-fast wording in `docs/04` and the entrypoint (#85); fixture table, MWL port 11115 and CLI tables (#86); README statements (#99); TLS and codec statements (#104); the worklist service and a free host port for an additional PACS in the usage guide (#105); `mwl-server` in `./pacs.sh help` (#106); configuration and CLI statements (#140); examples that now run as written (#138).

### Security
- `docs/10_security.md` states that restricted mode covers only the two `dcmqrscp` servers, while `storescp-receiver` and `mwl-server` accept any caller in every mode, and shows how to restrict the published bind address with `PACS_BIND_ADDR`. The production config example lists the self and sibling PACS. (#87)
- The `dcmtk` package follows Debian security revisions of 3.6.9 by default. Before the move to trixie, the bookworm pin was raised to `3.6.7-9~deb12u4` after Debian replaced the pinned revision. (#103, #112)

## [0.2.0] - 2026-05-31

### Added
- `LICENSE` file (MIT) matching the README license claim.
- `VERSION` stamp and this `CHANGELOG.md` so downstream consumers can pin a known release.
- Conformance / Capabilities table in the README documenting supported vs unsupported DICOM services (DICOMweb, MWL, MPPS, Storage Commitment, TLS, compressed transfer syntaxes).
- Per-service memory and CPU limits in `docker-compose.yml`.
- `scripts/fixture-manifest.sh` — a single source of truth for the synthetic fixture identity (OID root, study/series UIDs, instance counts, patient demographics). The data generator and every test script source it, so the suite can be retargeted at an external / non-DCMTK PACS by overriding `OID_ROOT` without editing any assertion. README documents the external-PACS procedure.
- Modality Worklist (MWL) support: a `worklist` role running `wlmscpfs`, a new `mwl-server` service (AE `DCMTK_WLM`, host port 11115), manifest-driven `.wl` worklist items (`scripts/generate-worklist.sh`) that share patient identity with the Q/R data, and `tests/test-worklist.sh` (`findscu -W`) wired into `test-all.sh` and the CI matrix. MPPS and Storage Commitment remain out of scope (DCMTK ships no such SCP).
- Ad-hoc C-MOVE destinations via `EXTRA_PEERS`: `scripts/inject-extra-peers.sh` injects `name=AE:host:port` peers into the rendered HostTable at startup (defined before the `all_peers` reference), so retrieval to an external listener no longer needs a template edit + rebuild. Added `./pacs.sh add-peer <name> <ae> <host> <port>` (sets `EXTRA_PEERS` and restarts the PACS) and `tests/test-adhoc-peers.sh`. End-to-end delivery to an injected destination is covered by `tests/test-adhoc-cmove.sh` and the `test-adhoc-cmove` CI job (C-MOVE to a destination registered only via `EXTRA_PEERS`, with receiver-side arrival verification).
- TLS profile for secure DICOM transport (opt-in, build-dependent): the `docker-compose.tls.yml` overlay switches the primary PACS to authenticated TLS (`dcmqrscp +tls`), with `scripts/gen-certs.sh` generating a self-signed CA + server + client certificates into a shared volume, and `tests/test-tls.sh` asserting a `+tls` C-ECHO succeeds while plaintext is refused. **Caveat:** the stock Debian apt `dcmtk` package is not linked against OpenSSL (observed during development when `+tls` failed with "Unknown option +tls"), so `+tls` is unavailable on the default image. On the default image the entrypoint refuses to start (exit 1) with a clear error when `TLS_ENABLED=true`, rather than deadlocking or silently downgrading to cleartext; `test-tls.sh` skips when TLS is unavailable. The profile is ready for a TLS-capable (source-built / OpenSSL-linked) dcmtk image. `docs/04_work_plan.md` and `docs/05_usage_guide.md` corrected accordingly. (There is intentionally no TLS-serving CI job; a `test-tls-skip` job asserts the skip path instead.)
- `RELEASE.md` documenting the release process (version bump, changelog roll, annotated tag, `develop`→`main` promotion) and the three-tier branch model, so the publish boundary cannot silently drift again. (#67)

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

[Unreleased]: https://github.com/kcenon/dcmtk-docker/compare/v0.3.0...develop
[0.3.0]: https://github.com/kcenon/dcmtk-docker/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kcenon/dcmtk-docker/releases/tag/v0.2.0
