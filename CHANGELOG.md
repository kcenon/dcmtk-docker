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
- Ad-hoc C-MOVE destinations via `EXTRA_PEERS`: `scripts/inject-extra-peers.sh` injects `name=AE:host:port` peers into the rendered HostTable at startup (defined before the `all_peers` reference), so retrieval to an external listener no longer needs a template edit + rebuild. Added `./pacs.sh add-peer <name> <ae> <host> <port>` (sets `EXTRA_PEERS` and restarts the PACS) and `tests/test-adhoc-peers.sh`. Host-verified end-to-end: a C-MOVE to an injected destination delivers all instances.
- TLS profile for secure DICOM transport (opt-in, build-dependent): the `docker-compose.tls.yml` overlay switches the primary PACS to authenticated TLS (`dcmqrscp +tls`), with `scripts/gen-certs.sh` generating a self-signed CA + server + client certificates into a shared volume, and `tests/test-tls.sh` asserting a `+tls` C-ECHO succeeds while plaintext is refused. **Caveat (verified in CI):** the stock Debian apt `dcmtk` package is not linked against OpenSSL, so `+tls` is unavailable on the default image. On the default image the entrypoint refuses to start (exit 1) with a clear error when `TLS_ENABLED=true`, rather than deadlocking or silently downgrading to cleartext; `test-tls.sh` skips when TLS is unavailable. The profile is ready for a TLS-capable (source-built / OpenSSL-linked) dcmtk image. `docs/04_work_plan.md` corrected accordingly.

### Changed
- Network-facing PACS and receiver services now run as a dedicated non-root user (`pacs`, uid 10001) instead of `root`. The test-client helper (no published ports) stays root so it can write synthetic data into the host-bind-mounted `./data`.
- Synced the README CLI command table and Project Structure tree with the actual `pacs.sh` subcommands and on-disk file layout.

### Fixed
- TLS overlay no longer deadlocks the stack on a non-TLS-capable image. When `TLS_ENABLED=true` but the `dcmqrscp` build lacks `+tls`, the entrypoint now fails fast (`exit 1`) with an explicit error instead of falling through to cleartext while the overlay healthcheck hung on `echoscu +tls` — which previously left `pacs-server` permanently unhealthy and blocked `test-client` from starting (#59).

### Security
- Reduced privilege of the network-facing DICOM services (non-root) and bounded per-container resource usage, lowering blast radius when the stack is wired into a downstream test loop.

## [0.1.0] - 2026-05-30

Initial baseline: DCMTK `dcmqrscp` test PACS exposing C-ECHO / C-STORE / C-FIND / C-MOVE,
a two-PACS topology plus a `storescp` C-MOVE receiver and a test-client SCU container,
deterministic synthetic CT/MR/CR data, an opt-in AE-whitelist restricted profile, and a
scripted DIMSE test suite with receiver-side C-MOVE verification.
