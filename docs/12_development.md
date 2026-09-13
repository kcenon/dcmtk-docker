# Project Structure and Development

Part of the dcmtk-docker documentation; start from the [README](../README.md).

## Project Structure

```
dcmtk-docker/
├── pacs.sh                             # CLI wrapper (./pacs.sh help)
├── Dockerfile                          # Single image: debian:bookworm-slim + DCMTK (non-root)
├── docker-compose.yml                  # 5 services, 1 network, 4 volumes
├── docker-compose.restricted.yml       # Overlay: AE-whitelist (restricted) mode
├── docker-compose.tls.yml              # Overlay: secure DICOM (TLS) mode
├── env.default                         # Default environment values (copy to .env)
├── VERSION                             # Project version (single source of truth)
├── CHANGELOG.md                        # Release history (Keep a Changelog)
├── RELEASE.md                          # Release process (develop to main, tagging)
├── LICENSE                             # MIT license
├── .dockerignore                       # Build context exclusions
├── README.md                           # Entry page: status, quick start, docs links
├── config/
│   ├── dcmqrscp-primary.cfg.template              # Primary PACS config template
│   ├── dcmqrscp-secondary.cfg.template            # Secondary PACS config template
│   ├── dcmqrscp-primary-restricted.cfg.template   # Primary, AE-whitelist variant
│   ├── dcmqrscp-secondary-restricted.cfg.template # Secondary, AE-whitelist variant
│   └── dcmqrscp-production.cfg.example            # AE-whitelist reference config
├── scripts/
│   ├── entrypoint.sh                   # Role-based startup dispatcher
│   ├── fixture-manifest.sh             # Shared fixture identity (SSOT)
│   ├── gen-certs.sh                    # Self-signed TLS test certificates
│   ├── generate-test-data.sh           # Synthetic DICOM generation
│   ├── generate-worklist.sh            # Modality Worklist (.wl) generation
│   ├── inject-extra-peers.sh           # Ad-hoc C-MOVE HostTable injection
│   ├── pixel-data-profile.sh           # Shared PixelData profile defaults
│   ├── readme_lint.py                  # README policy lint (CI only, not in the image)
│   ├── wait-for-pacs.sh                # Readiness polling
│   └── tests/
│       └── test_readme_lint.py         # Behavior tests for readme_lint.py
├── data/
│   └── dicom-templates/                # dump2dcm reference templates
│       ├── ct-template.dump
│       ├── mr-template.dump
│       └── cr-template.dump
├── tests/
│   ├── test-echo.sh                    # C-ECHO tests
│   ├── test-store.sh                   # C-STORE tests
│   ├── test-find.sh                    # C-FIND tests
│   ├── test-move.sh                    # C-MOVE tests
│   ├── test-pixeldata.sh               # PixelData smoke tests
│   ├── test-transfer-syntax.sh         # Transfer-syntax compatibility tests
│   ├── test-load-smoke.sh              # Operational load smoke tests
│   ├── test-restricted-mode.sh         # AE-whitelist rejection tests
│   ├── test-worklist.sh                # Modality Worklist (findscu -W) tests
│   ├── test-adhoc-peers.sh             # Ad-hoc C-MOVE peer injection tests
│   ├── test-adhoc-cmove.sh             # Ad-hoc C-MOVE end-to-end delivery test
│   ├── test-tls.sh                     # TLS secure-transport tests
│   ├── test-helpers.sh                 # Shared test helpers
│   └── test-all.sh                     # Full test suite runner
└── docs/
    ├── 01_research_dcmtk_dicom.md
    ├── 02_research_docker_approaches.md
    ├── 03_architecture_design.md
    ├── 04_work_plan.md
    ├── 05_usage_guide.md
    ├── 06_dcmqridx_behavior.md
    ├── 07_dicom_operations.md
    ├── 08_test_suite.md
    ├── 09_configuration.md
    ├── 10_security.md
    ├── 11_troubleshooting.md
    ├── 12_development.md
    └── contributing/
        └── README_POLICY.md
```

## Development

### Rebuild after changes

```bash
# Rebuild image and restart all services
docker compose up -d --build

# Rebuild and restart a specific service
docker compose up -d --build pacs-server
```

### Custom entrypoint

Run any command using the `custom` role:

```bash
docker compose run --rm -e ROLE=custom test-client dcmdump /dicom/testdata/ct/ct_pat001_1.dcm
```

### Inspect DICOM files

```bash
# Dump file contents
docker compose exec test-client dcmdump /dicom/testdata/ct/ct_pat001_1.dcm

# Dump specific tags
docker compose exec test-client dcmdump +P PatientName +P StudyInstanceUID \
    /dicom/testdata/ct/ct_pat001_1.dcm
```
