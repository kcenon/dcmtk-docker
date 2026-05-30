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

### Changed
- Container now runs as a dedicated non-root user instead of `root`.
- Synced the README CLI command table and Project Structure tree with the actual `pacs.sh` subcommands and on-disk file layout.

### Security
- Reduced container privilege (non-root) and bounded resource usage, lowering blast radius when the stack is wired into a downstream test loop.

## [0.1.0] - 2026-05-30

Initial baseline: DCMTK `dcmqrscp` test PACS exposing C-ECHO / C-STORE / C-FIND / C-MOVE,
a two-PACS topology plus a `storescp` C-MOVE receiver and a test-client SCU container,
deterministic synthetic CT/MR/CR data, an opt-in AE-whitelist restricted profile, and a
scripted DIMSE test suite with receiver-side C-MOVE verification.
